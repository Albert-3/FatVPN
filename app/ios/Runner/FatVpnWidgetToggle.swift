import Flutter
import Foundation
import NetworkExtension

/// Toggles the tunnel from inside the app's process while nothing is on screen
/// — the iOS 18 path, where the system launches the app in the background to
/// perform the widget's intent and this is what that intent does there.
///
/// Runner only: it is referenced from the app's copy of `FatVpnWidgetIntents`,
/// behind `#if !FATVPN_WIDGET_EXTENSION`, and there is nothing here a widget
/// extension could run even if it were compiled in.
///
/// Returns `nil` when the press was carried out here and nothing further is
/// needed, or a short machine-readable **reason** when the app has to be brought
/// to the foreground to finish. The caller records the reason, parks the action
/// and throws the foreground-continuation error.
///
/// The reason is not decoration. This runs with no UI and no console reachable
/// from the device, and there are exactly three ways out to the foreground, so
/// "it opens the app instead of connecting" is otherwise a report nobody can act
/// on.
@available(iOS 17.0, *)
@MainActor
enum FatVpnWidgetToggle {
    /// Coalesces a double-tap onto the run already in flight rather than
    /// starting a second engine over the first one's tunnel.
    private static var activeConnect: Task<String?, Never>?

    /// How long to wait for the Dart side to report. Not how long the tunnel
    /// has: by the time this expires `startVPNTunnel` has been issued and the
    /// network extension carries on regardless — all a timeout costs is the
    /// runner's closing snapshot.
    private static let verdictTimeout: UInt64 = 60 * 1_000_000_000

    static func run() async -> String? {
        var managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        if managers.isEmpty {
            // Asked twice before concluding this install has no VPN
            // configuration. The first read happens in a process the system has
            // only just launched, and concluding "the user never consented"
            // from one empty answer there costs them the whole feature — the app
            // is opened on a device where connecting in the background was
            // perfectly possible.
            managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            if !managers.isEmpty {
                FatVpnWidgetStore.trace("vpn configuration found only on the second read")
            }
        }
        guard let manager = managers.first else {
            // No saved configuration means the system's VPN consent dialog has
            // never been accepted on this install, and that dialog needs a
            // screen.
            FatVpnWidgetStore.trace("run: no vpn configuration (asked twice)")
            return "no-vpn-configuration"
        }
        FatVpnWidgetStore.trace(
            "run: configs=\(managers.count) status=\(name(of: manager.connection.status))"
        )

        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            // Stopping is not business logic, so it gets no engine: the tunnel's
            // own stop path patches the widget snapshot on the way down, and the
            // press overlay covers the gap until it does.
            FatVpnWidgetStore.markPressed("disconnecting")
            await clearOnDemand(on: manager)
            manager.connection.stopVPNTunnel()
            FatVpnWidgetStore.trace("run: stopped the tunnel natively")
            return nil
        default:
            // A second press while the first is still working joins it rather
            // than re-marking: the tile already says "Connecting…".
            if let running = activeConnect { return await running.value }
            FatVpnWidgetStore.markPressed("connecting")
            let task = Task { await connect() }
            activeConnect = task
            let reason = await task.value
            activeConnect = nil
            // Whatever the verdict, this attempt is over: either the tunnel is
            // up and speaks for itself, or nothing is connecting any more and
            // the tile must stop claiming otherwise.
            FatVpnWidgetStore.clearPress()
            return reason
        }
    }

    /// Takes the on-demand rule off the profile before a stop — set the flag,
    /// save, *then* stop — exactly as `SingboxMmPlugin.stopTunnel` does.
    ///
    /// Without it a widget-initiated disconnect is undone by the system within
    /// seconds: an on-demand rule is our kill switch and exists precisely to
    /// raise the tunnel whenever it is down, and it does not care who stopped
    /// it. The user watches the tile go to "Disconnected" and back on its own,
    /// which reads as the button having done nothing.
    ///
    /// Nothing re-arms the rule here, deliberately: every connect goes through
    /// Dart → `SingboxMmPlugin.configure`, which writes `isOnDemandEnabled`
    /// afresh from the current settings. Restoring it on this path would only
    /// race that write.
    private static func clearOnDemand(on manager: NETunnelProviderManager) async {
        guard manager.isOnDemandEnabled else { return }
        manager.isOnDemandEnabled = false
        do {
            try await manager.saveToPreferences()
            FatVpnWidgetStore.trace("run: cleared the on-demand rule")
        } catch {
            // Stopping anyway — a stop the system may undo still beats no stop
            // — but the trail has to say so, or the tunnel coming back a moment
            // later looks spontaneous with nothing on the device to explain it.
            FatVpnWidgetStore.trace(
                "run: could not clear on-demand (\(error.localizedDescription)); "
                    + "the system may raise the tunnel again"
            )
        }
    }

    // MARK: - Connecting through the app's own code

    /// Runs the app's connect path and waits for its verdict.
    ///
    /// Preferably on the **main** Flutter engine, over
    /// `fatvpn/widget_connect_host`: the system performs this intent by
    /// launching the whole app, so by the time a connect is wanted that engine
    /// is already booting in this very process — and a second AOT engine racing
    /// it is the kind of silent failure a background process can least afford
    /// (two `AuthController`s rotating one refresh-token family, for a start).
    /// The headless engine stays as the fallback for a main engine that never
    /// registers its handler.
    ///
    /// Why Dart at all, rather than `startVPNTunnel` from right here: connecting
    /// means a live 402 entitlement check, a fresh config and a ranked pick of
    /// the best node. Starting from whatever the last session left on disk would
    /// raise a tunnel on a subscription the panel may have already ended.
    private static func connect() async -> String? {
        switch await runOnMainEngine() {
        case .verdict(let outcome):
            FatVpnWidgetStore.trace("main engine verdict: \(outcome)")
            return outcome == "handOverToApp" ? "runner-handed-over" : nil
        case .timedOut:
            // No verdict is not a reason to raise the app: the tunnel is either
            // on its way up — and the extension's own snapshot write will say so
            // — or the next press tries again.
            FatVpnWidgetStore.trace("main engine: no verdict in time")
            return nil
        case .unreachable:
            FatVpnWidgetStore.trace("main engine unreachable → headless engine")
            return await runOnHeadlessEngine()
        }
    }

    private enum HostedRun {
        case verdict(String)
        case timedOut
        case unreachable
    }

    /// Marker the timeout resumes with, so it can never be mistaken for a reply.
    private final class TimedOutMarker {}

    /// Asks the app engine's Dart side to run the connect, retrying while
    /// Flutter boots — this intent regularly starts before `main()` has
    /// registered the handler.
    private static func runOnMainEngine() async -> HostedRun {
        for _ in 0..<20 {
            guard let channel = AppDelegate.widgetConnectHost else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let reply: Any? = await withCheckedContinuation { continuation in
                var resumed = false
                let resumeOnce: (Any?) -> Void = { value in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: value)
                }
                channel.invokeMethod("run", arguments: nil) { resumeOnce($0) }
                Task {
                    try? await Task.sleep(nanoseconds: verdictTimeout)
                    resumeOnce(TimedOutMarker())
                }
            }
            if reply is TimedOutMarker { return .timedOut }
            if let outcome = reply as? String { return .verdict(outcome) }
            // FlutterMethodNotImplemented, a FlutterError, or an engine still
            // wiring itself up: wait for the handler and ask again.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .unreachable
    }

    /// The fallback: `widgetConnectMain` — the Dart entrypoint Android's
    /// `WidgetConnectService` already uses — in a headless engine, with the
    /// verdict arriving on `fatvpn/widget_connect`.
    private static func runOnHeadlessEngine() async -> String? {
        let engine = FlutterEngine(
            name: "fatvpn-widget-connect",
            project: nil,
            allowHeadlessExecution: true
        )
        guard engine.run(withEntrypoint: "widgetConnectMain") else {
            // Could not even start the engine, which the app itself can. A Dart
            // entrypoint missing from the release snapshot looks exactly like
            // this — hence a reason that names the engine, not the tunnel.
            FatVpnWidgetStore.trace("headless engine did not start")
            return "engine-did-not-start"
        }
        GeneratedPluginRegistrant.register(with: engine)
        // The runner publishes widget snapshots over `fatvpn/widget`; this
        // engine needs the same native half the UI engine has, or every publish
        // is a MissingPluginException.
        let widgetChannel = AppDelegate.attachWidgetChannel(to: engine.binaryMessenger)

        let outcome: String? = await withCheckedContinuation { continuation in
            var resumed = false
            let resumeOnce: (String?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            // Held alive by its own handler closure: a channel nothing
            // references stops delivering.
            let connectChannel = FlutterMethodChannel(
                name: "fatvpn/widget_connect",
                binaryMessenger: engine.binaryMessenger
            )
            connectChannel.setMethodCallHandler { call, result in
                guard call.method == "finished" else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                result(nil)
                withExtendedLifetime(connectChannel) {
                    resumeOnce(call.arguments as? String)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: verdictTimeout)
                resumeOnce(nil)
            }
        }

        withExtendedLifetime(widgetChannel) {}
        engine.destroyContext()
        FatVpnWidgetStore.trace("headless engine verdict: \(outcome ?? "none in time")")
        guard outcome == "handOverToApp" else { return nil }
        // The runner's three reasons — no session, a lapsed subscription, or the
        // tunnel asking for a permission dialog — all arrive as this one
        // verdict. Which it was is one line above in the app's own log, and the
        // runner is where to widen the verdict if that stops being enough.
        return "runner-handed-over"
    }

    private static func name(of status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
