import AppIntents
import WidgetKit

/// What the power button runs — on iOS 18 and up, and only there.
///
/// ⚠️ This file is compiled into **both** the widget extension and the app
/// (`ios/tool/add_widget_target.rb` adds it to Runner as well), and the two
/// copies are deliberately different — `FATVPN_WIDGET_EXTENSION` is defined only
/// for the widget target. Both must be present: the system reads the *widget's*
/// App Intents metadata to decide where a press is routed, and the *app* must
/// carry the type to be able to perform it.
///
/// ## Why iOS 17 is not served from here
///
/// Apple documents exactly one list of levers ([Adding interactivity to widgets
/// and Live Activities]): the system runs an app intent in the widget
/// extension's process unless `openAppWhenRun` is true, or the intent conforms
/// to `AudioPlaybackIntent`, `ForegroundContinuableIntent`, `LiveActivityIntent`
/// or `PushToTalkTransmissionIntent` — in which case it runs in the **app's**
/// process. That distinction matters because the widget's process can never
/// toggle a tunnel: `NETunnelProviderManager` belongs to the app's bundle and
/// the NetworkExtension entitlement is not issued to a widget's App ID.
///
/// On an iPhone 11 / iOS 17.6.1, none of it happens. Every marker in that list
/// was shipped and tried, and then `openAppWhenRun: true` on top, with the tile
/// carrying no `widgetURL` that could swallow the press (build 206). The native
/// press trail — written to the App Group on the first line of `perform()`,
/// before anything can fail — came back **empty every time**. `perform()` runs
/// in neither process. The app opens, because that is what the system does with
/// a widget tap by default, and nothing else happens.
///
/// So on 17 the tile does not use an intent at all: the power control is a link
/// to `fatvpn://widget/toggle`, which reaches Dart through the engine's own
/// deep-link channel — the one path this app has carried end-to-end on a device.
/// See `powerControl` in FatVpnWidget.swift. Six builds went into establishing
/// that; do not "restore" the intent on 17 without new evidence from a device.
///
/// [Adding interactivity to widgets and Live Activities]:
/// https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities

/// The press on iOS 18 and up: performed in the app's process with nothing on
/// screen.
///
/// `AudioPlaybackIntent` is the marker that routes it there. Semantically it is
/// a lie — nothing here plays audio — but it is the marker production widgets
/// ship for exactly this job, and the two honest alternatives were both tried on
/// a device and failed: `ForegroundContinuableIntent` is unavailable to
/// extensions, and `LiveActivityIntent` produced a button whose `perform()` ran
/// in neither process.
///
/// ⚠️ **Never yet seen working on a device.** Build 233 — with the `audio`
/// background mode aboard since 208 — still produced a press that toggled
/// nothing on a user's iOS 18 phone, and the one "it works" report (the
/// 2026-08-03 run) was retracted by the tester the same day. The intent was
/// deleted over that, then re-added on the owner's later call (2026-08-03):
/// the failure has never been diagnosed, because no press trail has ever been
/// read off an iOS 18 phone. Acceptance is therefore a **traced** run on
/// iOS 18 — the support bundle carries the trail — not another verbal report.
///
/// Not marked `@available(iOS 18)` even though nothing below 18 attaches it: the
/// metadata processor silently drops types it cannot make sense of, and a
/// dropped type is a dead button with no diagnostic anywhere, so nothing unusual
/// goes into this declaration. The version gate lives in the view.
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
        try await FatVpnWidgetPress.handle()
        #else
        do {
            try await FatVpnWidgetPress.handle()
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

// MARK: - The press itself

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
enum FatVpnWidgetPress {
    static func handle() async throws {
        // The direction the tile is showing. It may be a redraw behind the
        // tunnel, which is why the path that performs the toggle for real
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
        FatVpnWidgetStore.trace("press → widget copy")
        FatVpnWidgetStore.park(.toggle)
        #else
        FatVpnWidgetStore.trace("press → app copy")
        // Nothing is going to appear on screen, so both the buzz and the work
        // happen here. Fired before the work, not after: a button that buzzes
        // once the tunnel is up has already spent the seconds in which the user
        // was wondering whether it registered the tap at all.
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
