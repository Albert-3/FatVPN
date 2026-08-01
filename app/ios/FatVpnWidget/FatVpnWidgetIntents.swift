import AppIntents
import WidgetKit
#if !FATVPN_WIDGET_EXTENSION
import AudioToolbox
import Flutter
import NetworkExtension
#endif

/// What the widget's power button runs on iOS 17 and up.
///
/// ⚠️ This file is compiled into **both** the widget extension and the app
/// (`ios/tool/add_widget_target.rb` adds it to the Runner target as well), and
/// the two copies are deliberately different — `FATVPN_WIDGET_EXTENSION` is
/// defined only for the widget target.
///
/// **What routes the press into the app's process is the `AudioPlaybackIntent`
/// conformance** on the declaration below — the marker the system honours by
/// launching the app in the background (even from cold) and performing the
/// intent there. It has to be on the copy the *widget* compiles: the system
/// decides where to run at the press, from the widget bundle's own App Intents
/// metadata. Semantically it is a lie — nothing here plays audio — but it is
/// the marker production widgets actually ship for exactly this job, and both
/// honest alternatives failed **on a device**:
///
///  * `ForegroundContinuableIntent` is unavailable to extensions, and a build
///    relying on it alone ran the widget's copy — parked the action, connected
///    only when the app was next opened (device, 2026-08-01). It is kept,
///    app-side only, purely for `needsToContinueInForegroundError()`.
///  * `LiveActivityIntent` (build 197, iPhone 11 / iOS 17.6.1, 2026-08-01)
///    produced a **dead button**: the intent ran in neither process — no park,
///    no background launch — and the tap fell through to the tile's
///    `widgetURL`, i.e. "opens the app, connects nothing". Not a packaging
///    defect: the unzipped .ipa had the intent in both bundles'
///    `Metadata.appintents` (`SessionStarting` marker, `openAppWhenRun` false)
///    and `NSSupportsLiveActivities` in the app's Info.plist, so the recipe as
///    documented was in the build and the system still declined it.
///
/// Running in the app's process, in the background, is the entire feature:
///
///  * **App copy** (the one that runs): toggles the tunnel right there, with no
///    UI anywhere. The app process owns the VPN configuration, so it may stop
///    the tunnel natively and start it through the same background Flutter
///    engine Android uses (`widgetConnectMain` → `WidgetConnectRunner`) — live
///    402 entitlement check, fresh config, best node, no second implementation.
///    It surfaces the app only when a screen is unavoidable (no session, lapsed
///    subscription, the first-ever VPN consent dialog), by parking the action in
///    the App Group and throwing `needsToContinueInForegroundError`.
///  * **Widget copy** (the fallback, if the system ever runs it anyway): parks
///    the action for the app to collect (`pollWidgetAction`) on its next launch
///    or resume. Deliberately *not* `openAppWhenRun: true` — see the property.
///
/// What neither copy does is touch the tunnel *from the widget's process*: that
/// needs the NetworkExtension entitlement the widget's App ID does not have,
/// and the VPN configuration belongs to the app's bundle besides.
@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FatVpnTogglePowerIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Toggle the VPN"
    static var description = IntentDescription("Connects or disconnects FatVPN.")

    /// False in **both** copies, and that is load-bearing. The button lives in
    /// the widget, so the widget bundle's App Intents metadata is what the
    /// system reads at the press — and a first build shipped the widget copy
    /// with `true` as a "safe fallback", which the system took literally: it
    /// opened the app on every press instead of running the intent in the
    /// app's background process (seen on a device 2026-08-01). Background
    /// execution comes from the `AudioPlaybackIntent` conformance on the
    /// declaration (see the type comment); the only sanctioned way to reach
    /// the foreground is the `needsToContinueInForegroundError` below.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        #if FATVPN_WIDGET_EXTENSION
        // The quiet fallback, only reached if the system ever runs the widget's
        // copy despite the routing above. It cannot toggle anything and — with
        // openAppWhenRun false, see there — cannot open the app either; all it
        // can do is park the request ("toggle": the app resolves the direction)
        // for the app's next launch or resume within the action's TTL.
        FatVpnWidgetSnapshot.dropBreadcrumb("press → widget copy (fallback)")
        FatVpnWidgetSnapshot.requestAction("toggle")
        // Nothing has actually changed yet — the app collects this on its next
        // launch — but the tile must not redraw to exactly what it showed
        // before, which is what a dead button looks like. The direction is
        // resolved from the snapshot this widget is drawing; the app resolves it
        // again, from the live tunnel, when it performs the action for real.
        FatVpnWidgetSnapshot.markToggleRequested(
            FatVpnWidgetSnapshot.read().isConnected ? "disconnecting" : "connecting"
        )
        return .result()
        #else
        FatVpnWidgetSnapshot.dropBreadcrumb("press → app copy")
        fatVpnWidgetPressFeedback()
        if let reason = await FatVpnWidgetAppToggle.run() {
            // Surfacing the app is the exception, and every time it happens it
            // now says why — see FatVpnWidgetSnapshot.handOverReasonKey.
            FatVpnWidgetSnapshot.dropBreadcrumb("hand-over (\(reason)) → foreground")
            FatVpnWidgetSnapshot.recordHandOverReason(reason)
            // "connect", not "toggle": the toggle has already been resolved —
            // the tunnel is down and only the app can finish bringing it up.
            // Parked for the app to collect on resume, exactly as the fallback
            // path parks its action.
            FatVpnWidgetSnapshot.requestAction("connect")
            WidgetCenter.shared.reloadAllTimelines()
            throw needsToContinueInForegroundError()
        }
        FatVpnWidgetSnapshot.dropBreadcrumb("press handled in the background")
        return .result()
        #endif
    }
}

#if !FATVPN_WIDGET_EXTENSION

/// App-side only, and **not** what routes the intent here —
/// `AudioPlaybackIntent` on the declaration does that; this conformance was
/// once believed to and demonstrably did not (device, 2026-08-01: the press
/// ran the widget's copy). It exists solely to make
/// `needsToContinueInForegroundError()` throwable, the one sanctioned way for
/// the background run to surface the app when a screen is unavoidable.
///
/// Inside the `#if`, not just behind the availability gate: the build-197 .ipa
/// showed the metadata extractor records conformances regardless of
/// `@available(iOSApplicationExtension, unavailable)`, so the widget bundle's
/// metadata was claiming a protocol Apple forbids to extensions. The `#if` is
/// what actually keeps it out of the appex.
@available(iOS 17.0, *)
@available(iOSApplicationExtension, unavailable)
extension FatVpnTogglePowerIntent: ForegroundContinuableIntent {}

/// The tick under the power button, as far as iOS permits one.
///
/// ⚠️ Expect nothing from it on most presses, and do not spend a build cycle
/// chasing it. The widget's own process has no haptics whatsoever, and this
/// intent runs in the app's process **in the background**, where iOS hands the
/// vibromotor to nobody: `UIFeedbackGenerator` and CoreHaptics are documented
/// foreground-only, and this older system-sound route is merely the one call
/// that is not outright unavailable there. It is one line, it cannot fail
/// loudly, and it does fire on the press that ends in the foreground (the
/// hand-over) — so it stays. Android is where a widget press actually buzzes;
/// see `WidgetHaptics.kt` for the equivalent, and why even there the usage had
/// to be `HARDWARE_FEEDBACK`.
@available(iOS 17.0, *)
private func fatVpnWidgetPressFeedback() {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
}

/// Toggles the tunnel from inside the app's process while nothing is on
/// screen — the system launches the app in the background to perform the
/// widget's intent, and this is what that intent does there.
///
/// Returns `nil` when the press was carried out here and nothing else is
/// needed, or a short machine-readable **reason** when the app must be brought
/// to the foreground to finish the job. The caller records the reason, parks the
/// action and throws the foreground-continuation error.
///
/// The reason is not decoration. This runs with no UI and no console reachable
/// from the device, and there are exactly three ways out to the foreground — so
/// "it opens the app instead of connecting" was, until now, a report no one
/// could act on.
@available(iOS 17.0, *)
@MainActor
enum FatVpnWidgetAppToggle {
    /// Coalesces a double-tap onto the run already in flight instead of
    /// starting a second engine over the first one's tunnel.
    private static var activeConnect: Task<String?, Never>?

    /// How long to wait for `widgetConnectMain` to report before giving up on
    /// the *verdict* — not on the tunnel: by then `startVPNTunnel` has been
    /// issued and the NE extension carries on regardless; all a timeout costs
    /// is the runner's final snapshot publish.
    private static let verdictTimeout: UInt64 = 60 * 1_000_000_000

    static func run() async -> String? {
        // Direction from the live tunnel, not from the snapshot the widget
        // drew — that one may be a redraw behind.
        var managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        if managers.isEmpty {
            // Asked twice before concluding this install has no VPN
            // configuration. The first read happens in a process the system has
            // just launched into the background, and concluding "the user has
            // never consented" from one empty answer there costs the user the
            // whole feature — the app is opened on a device where connecting in
            // the background was perfectly possible. The retry is cheap; the
            // reason below records which read answered.
            managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            if !managers.isEmpty {
                FatVpnWidgetSnapshot.recordHandOverReason("vpn-config-found-on-retry")
            }
        }
        guard let manager = managers.first else {
            // No saved configuration means the OS consent dialog has never been
            // accepted on this install, and that dialog needs a screen.
            FatVpnWidgetSnapshot.dropBreadcrumb("run: no vpn configuration (asked twice)")
            return "no-vpn-configuration"
        }
        FatVpnWidgetSnapshot.dropBreadcrumb(
            "run: configs=\(managers.count) status=\(statusName(manager.connection.status))"
        )
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            // Stopping is not business logic, so no engine for it: the tunnel's
            // own stop handler patches the widget snapshot on the way down. The
            // marker covers the gap until it does — a teardown is quick, but not
            // so quick that the tile should sit on "Connected" through it.
            FatVpnWidgetSnapshot.markToggleRequested("disconnecting")
            await clearOnDemandBeforeStopping(manager)
            manager.connection.stopVPNTunnel()
            FatVpnWidgetSnapshot.dropBreadcrumb("run: stopped the tunnel natively")
            return nil
        default:
            // A second press while the first is still working joins it rather
            // than re-marking: the tile already says "Connecting…".
            if let running = activeConnect { return await running.value }
            FatVpnWidgetSnapshot.markToggleRequested("connecting")
            let task = Task { await connectViaEngine() }
            activeConnect = task
            let reason = await task.value
            activeConnect = nil
            // Whatever the verdict, this attempt is over: either the tunnel is
            // up and speaks for itself, or nothing is connecting any more and
            // the tile must stop claiming otherwise.
            FatVpnWidgetSnapshot.clearToggleMarker()
            return reason
        }
    }

    /// Takes the on-demand rule off the profile before a stop, exactly as
    /// `SingboxMmPlugin.stopTunnel` does — set the flag, save, *then* stop.
    ///
    /// Without it a widget-initiated disconnect is undone by the system within
    /// seconds: an on-demand rule (our kill-switch) exists precisely to raise
    /// the tunnel again whenever it is down, and it does not care who stopped
    /// it. The user sees the tile go to "Disconnected" and back to
    /// "Connected" on its own, which reads as the button having done nothing.
    ///
    /// Nothing restores the rule here, and that is deliberate: every connect
    /// goes through Dart → `SingboxMmPlugin.configure`, which writes
    /// `isOnDemandEnabled` afresh from the current settings. Re-arming it on
    /// this path would only race that write.
    private static func clearOnDemandBeforeStopping(_ manager: NETunnelProviderManager) async {
        guard manager.isOnDemandEnabled else { return }
        manager.isOnDemandEnabled = false
        do {
            try await manager.saveToPreferences()
            FatVpnWidgetSnapshot.dropBreadcrumb("run: cleared the on-demand rule")
        } catch {
            // Stopping anyway — a stop that the system may undo still beats no
            // stop at all — but the breadcrumb has to say so, or the tunnel
            // coming back up a moment later looks spontaneous and there is
            // nothing on the device to read.
            FatVpnWidgetSnapshot.dropBreadcrumb(
                "run: could not clear on-demand (\(error.localizedDescription)) — "
                    + "the system may raise the tunnel again"
            )
        }
    }

    /// Runs the app's own connect path and waits for its verdict.
    ///
    /// Preferably on the **main** Flutter engine, over
    /// `fatvpn/widget_connect_host` (registered in `main()`): the system
    /// performs this intent by launching the full app, so by the time a
    /// connect is wanted the app's own engine is already booting in this very
    /// process — and a second AOT engine racing it is exactly the kind of
    /// silent failure a background process can least afford. The headless
    /// engine stays as the fallback for a main engine that never registers
    /// its handler.
    private static func connectViaEngine() async -> String? {
        switch await runOnMainEngine() {
        case .verdict(let outcome):
            FatVpnWidgetSnapshot.dropBreadcrumb("main engine verdict: \(outcome)")
            return outcome == "handOverToApp" ? "runner-handed-over" : nil
        case .timedOut:
            // Same terms as the headless timeout below: no verdict is not a
            // reason to raise the app — the tunnel is either on its way up or
            // the next tap tries again.
            FatVpnWidgetSnapshot.dropBreadcrumb("main engine: no verdict in time")
            return nil
        case .unreachable:
            FatVpnWidgetSnapshot.dropBreadcrumb("main engine unreachable → headless engine")
            return await runOnHeadlessEngine()
        }
    }

    private enum HostedRun {
        case verdict(String)
        case timedOut
        case unreachable
    }

    /// Marker the per-attempt timeout resumes the continuation with, so it can
    /// never be mistaken for a reply.
    private final class HostedRunTimeout {}

    /// Asks the app engine's Dart side to run the connect, retrying while
    /// Flutter boots — the intent regularly starts before `main()` has
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
                    resumeOnce(HostedRunTimeout())
                }
            }
            if let unwrapped = reply, unwrapped is HostedRunTimeout { return .timedOut }
            if let outcome = reply as? String { return .verdict(outcome) }
            // FlutterMethodNotImplemented, a FlutterError, or an engine still
            // wiring up: wait for the handler and ask again.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .unreachable
    }

    private static func statusName(_ status: NEVPNStatus) -> String {
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

    /// The fallback: `widgetConnectMain` — the entrypoint Android's
    /// `WidgetConnectService` already uses — in a headless Flutter engine,
    /// with the verdict arriving on the `fatvpn/widget_connect` channel.
    private static func runOnHeadlessEngine() async -> String? {
        let engine = FlutterEngine(
            name: "fatvpn-widget-connect",
            project: nil,
            allowHeadlessExecution: true
        )
        guard engine.run(withEntrypoint: "widgetConnectMain") else {
            // Could not even start the engine — the app can. A Dart entrypoint
            // that is not in the release snapshot looks exactly like this, which
            // is why the reason names the engine rather than the tunnel.
            FatVpnWidgetSnapshot.dropBreadcrumb("headless engine did not start")
            return "engine-did-not-start"
        }
        GeneratedPluginRegistrant.register(with: engine)
        // The runner publishes widget snapshots over fatvpn/widget; this engine
        // needs the same native half the UI engine has, or every publish is a
        // MissingPluginException.
        let widgetChannel = AppDelegate.attachWidgetChannel(to: engine.binaryMessenger)

        let outcome: String? = await withCheckedContinuation { continuation in
            var resumed = false
            let resumeOnce: (String?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            // Held by its handler closure until the verdict arrives; a channel
            // nothing references stops delivering.
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
        FatVpnWidgetSnapshot.dropBreadcrumb(
            "headless engine verdict: \(outcome ?? "none in time")"
        )
        // A verdict that never came is not a reason to raise the app: the
        // tunnel is either on its way up (and the widget follows it via
        // patchTunnelState) or the next tap tries again.
        guard outcome == "handOverToApp" else { return nil }
        // The runner's own three reasons — no session, a lapsed subscription,
        // or the tunnel asking for a permission dialog — all arrive as this one
        // verdict. Which of them it was is in the app's log, one line above
        // ("Widget connect: …"), and the runner is where to widen the verdict if
        // that ever stops being enough.
        return "runner-handed-over"
    }
}

#endif
