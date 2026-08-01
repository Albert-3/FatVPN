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
/// **What routes the press into the app's process is the `LiveActivityIntent`
/// conformance** on the declaration below — the marker the system honours by
/// launching the app in the background (even from cold) and performing the
/// intent there. It has to be `LiveActivityIntent` (or `AudioPlaybackIntent`)
/// and it has to be on the copy the *widget* compiles: the system decides where
/// to run at the press, from the widget bundle's own App Intents metadata.
/// `ForegroundContinuableIntent` cannot do this job — the protocol is
/// unavailable to extensions, so its conformance is invisible in exactly the
/// metadata that is consulted, and a build that relied on it alone was routed
/// to the widget's copy: the press parked the action and nothing connected
/// until the app was next opened (device, 2026-08-01). That conformance is
/// kept, app-side only, purely for `needsToContinueInForegroundError()`.
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
struct FatVpnTogglePowerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle the VPN"
    static var description = IntentDescription("Connects or disconnects FatVPN.")

    /// False in **both** copies, and that is load-bearing. The button lives in
    /// the widget, so the widget bundle's App Intents metadata is what the
    /// system reads at the press — and a first build shipped the widget copy
    /// with `true` as a "safe fallback", which the system took literally: it
    /// opened the app on every press instead of running the intent in the
    /// app's background process (seen on a device 2026-08-01). Background
    /// execution comes from the `LiveActivityIntent` conformance on the
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
        fatVpnWidgetPressFeedback()
        if let reason = await FatVpnWidgetAppToggle.run() {
            // Surfacing the app is the exception, and every time it happens it
            // now says why — see FatVpnWidgetSnapshot.handOverReasonKey.
            FatVpnWidgetSnapshot.recordHandOverReason(reason)
            // "connect", not "toggle": the toggle has already been resolved —
            // the tunnel is down and only the app can finish bringing it up.
            // Parked for the app to collect on resume, exactly as the fallback
            // path parks its action.
            FatVpnWidgetSnapshot.requestAction("connect")
            WidgetCenter.shared.reloadAllTimelines()
            throw needsToContinueInForegroundError()
        }
        return .result()
        #endif
    }
}

/// App-side only (the protocol is unavailable to extensions), and **not** what
/// routes the intent here — `LiveActivityIntent` on the declaration does that;
/// this conformance was once believed to and demonstrably did not (device,
/// 2026-08-01: the press ran the widget's copy). It exists solely to make
/// `needsToContinueInForegroundError()` throwable, the one sanctioned way for
/// the background run to surface the app when a screen is unavoidable.
@available(iOS 17.0, *)
@available(iOSApplicationExtension, unavailable)
extension FatVpnTogglePowerIntent: ForegroundContinuableIntent {}

#if !FATVPN_WIDGET_EXTENSION

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
            return "no-vpn-configuration"
        }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            // Stopping is not business logic, so no engine for it: the tunnel's
            // own stop handler patches the widget snapshot on the way down. The
            // marker covers the gap until it does — a teardown is quick, but not
            // so quick that the tile should sit on "Connected" through it.
            FatVpnWidgetSnapshot.markToggleRequested("disconnecting")
            manager.connection.stopVPNTunnel()
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

    /// Runs the app's own connect path — `widgetConnectMain`, the entrypoint
    /// Android's `WidgetConnectService` already uses — in a headless Flutter
    /// engine, and waits for its verdict on the `fatvpn/widget_connect`
    /// channel.
    private static func connectViaEngine() async -> String? {
        let engine = FlutterEngine(
            name: "fatvpn-widget-connect",
            project: nil,
            allowHeadlessExecution: true
        )
        guard engine.run(withEntrypoint: "widgetConnectMain") else {
            // Could not even start the engine — the app can. A Dart entrypoint
            // that is not in the release snapshot looks exactly like this, which
            // is why the reason names the engine rather than the tunnel.
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
