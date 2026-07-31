import AppIntents
import WidgetKit
#if !FATVPN_WIDGET_EXTENSION
import Flutter
import NetworkExtension
#endif

/// What the widget's power button runs on iOS 17 and up.
///
/// ⚠️ This file is compiled into **both** the widget extension and the app
/// (`ios/tool/add_widget_target.rb` adds it to the Runner target as well), and
/// the two copies are deliberately different — `FATVPN_WIDGET_EXTENSION` is
/// defined only for the widget target. The system prefers to run an intent in
/// the process of the binary that hosts it, and the `ForegroundContinuableIntent`
/// conformance below (app-only: the protocol is unavailable to extensions) tells
/// it to run this one **in the app's process, launched in the background** —
/// which is the entire feature:
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
struct FatVpnTogglePowerIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle the VPN"
    static var description = IntentDescription("Connects or disconnects FatVPN.")

    /// False in **both** copies, and that is load-bearing. The button lives in
    /// the widget, so the widget bundle's App Intents metadata is what the
    /// system reads at the press — and a first build shipped the widget copy
    /// with `true` as a "safe fallback", which the system took literally: it
    /// opened the app on every press instead of routing the intent to the
    /// app's background process (seen on a device 2026-08-01). The proven
    /// routing recipe keeps the type's metadata identical in both binaries and
    /// lets the app-only `ForegroundContinuableIntent` conformance make the
    /// difference; the only sanctioned way to reach the foreground is the
    /// `needsToContinueInForegroundError` below.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        #if FATVPN_WIDGET_EXTENSION
        // The quiet fallback, only reached if the system ever runs the widget's
        // copy despite the routing above. It cannot toggle anything and — with
        // openAppWhenRun false, see there — cannot open the app either; all it
        // can do is park the request ("toggle": the app resolves the direction)
        // for the app's next launch or resume within the action's TTL.
        FatVpnWidgetSnapshot.requestAction("toggle")
        // The snapshot has not changed, but the widget should not look frozen
        // at the instant of the press.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
        #else
        let needsApp = await FatVpnWidgetAppToggle.run()
        if needsApp {
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

/// The app-process half of the routing trick: `ForegroundContinuableIntent` is
/// unavailable to extensions, so this conformance exists only in the app's
/// binary — which is precisely what makes the system pick the app's copy to
/// run. Recipe per Apple's App Intents docs (and the same one audio apps use
/// via `AudioPlaybackIntent`).
@available(iOS 17.0, *)
@available(iOSApplicationExtension, unavailable)
extension FatVpnTogglePowerIntent: ForegroundContinuableIntent {}

#if !FATVPN_WIDGET_EXTENSION

/// Toggles the tunnel from inside the app's process while nothing is on
/// screen — the system launches the app in the background to perform the
/// widget's intent, and this is what that intent does there.
///
/// Returns `true` when the app must be brought to the foreground to finish the
/// job; the caller parks the action and throws the foreground-continuation
/// error, and the app then does what it always does.
@available(iOS 17.0, *)
@MainActor
enum FatVpnWidgetAppToggle {
    /// Coalesces a double-tap onto the run already in flight instead of
    /// starting a second engine over the first one's tunnel.
    private static var activeConnect: Task<Bool, Never>?

    /// How long to wait for `widgetConnectMain` to report before giving up on
    /// the *verdict* — not on the tunnel: by then `startVPNTunnel` has been
    /// issued and the NE extension carries on regardless; all a timeout costs
    /// is the runner's final snapshot publish.
    private static let verdictTimeout: UInt64 = 60 * 1_000_000_000

    static func run() async -> Bool {
        // Direction from the live tunnel, not from the snapshot the widget
        // drew — that one may be a redraw behind.
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let manager = managers.first else {
            // No saved configuration means the OS consent dialog has never been
            // accepted on this install, and that dialog needs a screen. Decided
            // here, before spending an engine on a connect that cannot finish.
            return true
        }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            // Stopping is not business logic, so no engine for it: the tunnel's
            // own stop handler patches the widget snapshot on the way down.
            manager.connection.stopVPNTunnel()
            return false
        default:
            if let running = activeConnect { return await running.value }
            let task = Task { await connectViaEngine() }
            activeConnect = task
            let needsApp = await task.value
            activeConnect = nil
            return needsApp
        }
    }

    /// Runs the app's own connect path — `widgetConnectMain`, the entrypoint
    /// Android's `WidgetConnectService` already uses — in a headless Flutter
    /// engine, and waits for its verdict on the `fatvpn/widget_connect`
    /// channel.
    private static func connectViaEngine() async -> Bool {
        let engine = FlutterEngine(
            name: "fatvpn-widget-connect",
            project: nil,
            allowHeadlessExecution: true
        )
        guard engine.run(withEntrypoint: "widgetConnectMain") else {
            // Could not even start the engine — the app can.
            return true
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
        return outcome == "handOverToApp"
    }
}

#endif
