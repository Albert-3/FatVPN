import AppIntents
import WidgetKit

/// What the power button runs, in the two shapes iOS gives us.
///
/// ⚠️ This file is compiled into **both** the widget extension and the app
/// (`ios/tool/add_widget_target.rb` adds it to Runner as well), and the two
/// copies are deliberately different — `FATVPN_WIDGET_EXTENSION` is defined only
/// for the widget target. Both must be present: the system reads the *widget's*
/// App Intents metadata to decide where a press is routed, and the *app* must
/// carry the type to be able to perform it.
///
/// ## Why there are two intents rather than one
///
/// Apple documents exactly one list of levers ([Adding interactivity to widgets
/// and Live Activities]): the system runs an app intent in the widget
/// extension's process unless `openAppWhenRun` is true, or the intent conforms
/// to `AudioPlaybackIntent`, `ForegroundContinuableIntent`, `LiveActivityIntent`
/// or `PushToTalkTransmissionIntent` — in which case it runs in the **app's**
/// process. That matters because the widget's process can never toggle a
/// tunnel: `NETunnelProviderManager` belongs to the app's bundle and the
/// NetworkExtension entitlement is not issued to a widget's App ID.
///
/// Running in the app's process is not the same as running in the *background*,
/// and that is where the two versions part company:
///
///  * **iOS 18 and up** — a background launch for a widget intent is confirmed
///    behaviour (Apple DTS answered a thread about its *latency*, i.e. the app
///    does get launched). So the press is served by
///    [FatVpnTogglePowerIntent] and nothing appears on screen.
///  * **iOS 17.x** — no confirmed case of the system launching a terminated app
///    in the background for a widget intent exists, and a force-quit app is
///    barred from background launch until the user opens it by hand — which is
///    the main scenario for a VPN widget. Three build cycles were spent proving
///    this on an iPhone 11 / iOS 17.6.1 under every marker in the list. What
///    *was* observed to work there is `openAppWhenRun: true`: it opened the app
///    on every press, reliably. So on 17 the press is served by
///    [FatVpnOpenAppAndTogglePowerIntent], which is that behaviour on purpose
///    rather than as a failure — the app opens, and the toggle happens the
///    instant it does.
///
/// The choice is made in the widget's view (`powerControl`), by the OS version
/// of the device drawing the tile. Neither type is marked `@available(iOS 18)`:
/// the metadata processor silently drops types it cannot make sense of, and a
/// dropped type is a dead button with no diagnostic anywhere, so nothing
/// unusual goes into these declarations.
///
/// [Adding interactivity to widgets and Live Activities]:
/// https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities

// MARK: - iOS 18+: toggle in the background

/// The press on iOS 18 and up: performed in the app's process with nothing on
/// screen.
///
/// `AudioPlaybackIntent` is the marker that routes it there. Semantically it is
/// a lie — nothing here plays audio — but it is the marker production widgets
/// ship for exactly this job, and the two honest alternatives were both tried on
/// a device and failed: `ForegroundContinuableIntent` is unavailable to
/// extensions, and `LiveActivityIntent` produced a button whose `perform()` ran
/// in neither process.
@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FatVpnTogglePowerIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Toggle the VPN"
    static var description = IntentDescription("Connects or disconnects FatVPN.")

    /// False, and load-bearing. The button lives in the widget, so the widget
    /// bundle's metadata is what the system reads at the press — and a build
    /// that shipped the widget's copy with `true` as a "safe fallback" had the
    /// system take it literally, opening the app on every press instead of
    /// working in the background. Background execution comes from the
    /// `AudioPlaybackIntent` conformance above; the one sanctioned way to reach
    /// the foreground from here is `needsToContinueInForegroundError`.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        #if FATVPN_WIDGET_EXTENSION
        try await FatVpnWidgetPress.handle(mayOpenApp: false)
        #else
        do {
            try await FatVpnWidgetPress.handle(mayOpenApp: false)
        } catch FatVpnWidgetPressHandOver.needed {
            // The only place this error is turned into Apple's own: the
            // continuation method exists on `ForegroundContinuableIntent`,
            // which the shared press body deliberately knows nothing about and
            // the widget's copy of this file must never mention.
            throw needsToContinueInForegroundError()
        }
        #endif
        return .result()
    }
}

// MARK: - iOS 17.x: open the app, then toggle

/// The press on iOS 17.x: the system opens the app and performs this in the
/// app's process, and the toggle rides the app's own connect path from there.
///
/// This is not a degraded copy of the intent above with the work removed — it is
/// the only thing that works on 17, and it works by *design* here: the press is
/// parked in the App Group before the app comes up, and the app collects it on
/// launch and on every resume (`AuthController.pollWidgetAction`). So the user
/// sees the app open and the tunnel change state, rather than the app open and
/// nothing happen, which is what every 17.x build did before.
@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FatVpnOpenAppAndTogglePowerIntent: AppIntent {
    static var title: LocalizedStringResource = "Open FatVPN and toggle the VPN"
    static var description = IntentDescription("Opens FatVPN and connects or disconnects it.")

    /// True on purpose, and only on this type. It is what makes the app appear
    /// — the single behaviour an iPhone on 17.6.1 was ever observed to produce
    /// from this button.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await FatVpnWidgetPress.handle(mayOpenApp: true)
        return .result()
    }
}

// MARK: - The press itself

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
enum FatVpnWidgetPress {
    /// - Parameter mayOpenApp: whether the intent that called this has
    ///   `openAppWhenRun` set, i.e. whether an app is on its way to the screen.
    ///   It decides two things, and they are the whole difference between the
    ///   two versions of this button: whether the toggle is performed here or
    ///   left for the app to collect, and which side owns the haptic.
    static func handle(mayOpenApp: Bool) async throws {
        // The direction the tile is showing. It may be a redraw behind the
        // tunnel, which is why every path that performs the toggle for real
        // resolves the direction again from the live connection — this one is
        // only for the overlay and the haptic.
        let goingUp = !FatVpnWidgetStore.read().isConnected
        // Redraws the tile as it writes: the press has to be answered now, not
        // when the tunnel gets round to it.
        FatVpnWidgetStore.markPressed(goingUp ? "connecting" : "disconnecting")

        #if FATVPN_WIDGET_EXTENSION
        // The widget's copy. It reaches here only if the system declined to
        // route the press into the app after all; it can toggle nothing, so all
        // it does is leave the request where the app will find it.
        FatVpnWidgetStore.trace("press → widget copy (mayOpenApp: \(mayOpenApp))")
        FatVpnWidgetStore.park(.toggle)
        #else
        FatVpnWidgetStore.trace("press → app copy (mayOpenApp: \(mayOpenApp))")

        if mayOpenApp {
            // iOS 17. The app is coming to the front anyway, so the toggle is
            // left to it: `pollWidgetAction` picks this up on the very launch or
            // resume this press caused, and runs the app's own connect — a live
            // 402 entitlement check and a fresh config, not whatever the last
            // session left on disk. `.toggle` rather than a direction, because
            // by the time the app looks, the tunnel is the authority.
            //
            // No haptic on this path, deliberately. The app buzzes for itself
            // the moment it picks the action up
            // (`HomeWidgetBridge.takePendingAction`), in the foreground, where a
            // real `UIImpactFeedbackGenerator` works — and where this process
            // is not yet. Buzzing from here as well would either double it or,
            // if the system ran the widget's copy of this file instead of the
            // app's, be the buzz that never happens. One owner per path.
            FatVpnWidgetStore.park(.toggle)
            FatVpnWidgetStore.trace("parked for the app that is opening")
            return
        }

        // iOS 18. Nothing is going to appear on screen, so both the buzz and the
        // work happen here. Fired before the work, not after: a button that
        // buzzes once the tunnel is up has already spent the seconds in which
        // the user was wondering whether it registered the tap at all.
        FatVpnWidgetHaptics.play(goingUp ? .connecting : .disconnecting)

        if let reason = await FatVpnWidgetToggle.run() {
            // Surfacing the app is the exception, and it now always says why:
            // this runs with no UI and no console reachable from the device, so
            // "it opened the app instead of connecting" was, until this line, a
            // report nobody could act on.
            FatVpnWidgetStore.trace("hand-over (\(reason)) → foreground")
            // Clearing redraws: nothing is connecting any more, and the tile
            // must stop claiming otherwise while the user reads a screen.
            FatVpnWidgetStore.clearPress()
            FatVpnWidgetStore.park(.toggle)
            throw FatVpnWidgetPressHandOver.needed(reason)
        }
        FatVpnWidgetStore.trace("press handled in the background")
        #endif
    }
}

#if !FATVPN_WIDGET_EXTENSION

/// App-side only, and **not** what routes the press here — `AudioPlaybackIntent`
/// on the declaration does that. This exists solely to make
/// `needsToContinueInForegroundError()` throwable, the one sanctioned way for a
/// background run to bring the app up when a screen is unavoidable.
///
/// Inside the `#if`, not merely behind an availability gate: a shipped build
/// showed the metadata extractor records conformances regardless of
/// `@available(iOSApplicationExtension, unavailable)`, so the widget bundle's
/// metadata was claiming a protocol Apple forbids to extensions. The `#if` is
/// what actually keeps it out of the .appex.
@available(iOS 17.0, *)
@available(iOSApplicationExtension, unavailable)
extension FatVpnTogglePowerIntent: ForegroundContinuableIntent {}

/// Thrown by [FatVpnWidgetPress] when the background run cannot finish the job
/// alone, and converted into the real continuation error by the intent that can
/// throw one.
///
/// A plain `Error` rather than `needsToContinueInForegroundError()` called
/// directly, because that method lives on `ForegroundContinuableIntent` — a
/// protocol the shared press body deliberately knows nothing about.
enum FatVpnWidgetPressHandOver: Error {
    case needed(String)
}

#endif
