import AppIntents
import Foundation

/// The widget press on iOS 18+ — third architecture, and the first one copied
/// from code that demonstrably ships: sing-box VT's widget toggle.
///
/// ## Why these intents are deliberately plain
///
/// Apple documents one routing rule for a widget button's intent: it performs
/// **in the widget extension's process**, unless `openAppWhenRun` is true or
/// the intent conforms to `AudioPlaybackIntent` / `ForegroundContinuableIntent`
/// / `LiveActivityIntent` / `PushToTalkTransmissionIntent` — those reroute it
/// into the app's process.
///
/// This project shipped that rerouted scheme twice, and it never ran on any
/// device: builds 207 and 233, and the owner's own iOS 18+ phone on
/// 2026-08-04, all with one signature — the press opens the app, toggles
/// nothing, no haptic, the App-Group press trail empty. Web research
/// (2026-08-04) showed the route itself is broken ecosystem-wide: iOS 17
/// fails with the app alive in the background (Apple forums 732771, 735159),
/// iOS 18 fails outright (758784) — and sing-box had to **remove** the
/// app-process conformance from their toggle to make it work (commit
/// dac24338 "Fix control widget" in SagerNet/sing-box-for-apple).
///
/// So: no conformances, no `openAppWhenRun`, no `UIBackgroundModes`. The
/// intent performs where the button lives, and the tunnel work is native —
/// see FatVpnWidgetTunnel.swift, and its header for why a widget process is
/// allowed to do that at all.
///
/// ## The two build defects that likely also killed the old button
///
/// Even the widget-process copies of the old intents never ran on iOS 17,
/// which no routing bug explains. Research turned up two build-level causes
/// with our exact signature, both fixed in `add_widget_target.rb`:
///
///  * Xcode 15.3+ "deployment-aware processing" of App Intents metadata is
///    **acknowledged broken by Apple** for targets with a minimum deployment
///    target of iOS 15 or earlier (Runner deploys to 13): the extracted
///    metadata carries an empty `mangledTypeName`, the system cannot resolve
///    the type at the press, and the tap falls through to "open the app"
///    (forums 751229, FB13664020). Workaround, per Apple:
///    `ENABLE_APPINTENTS_DEPLOYMENT_AWARE_PROCESSING = NO` on every target
///    that compiles intents.
///  * A raw `-weak_framework AppIntents` in `OTHER_LDFLAGS` is invisible to
///    `appintentsmetadataprocessor`, which keys off the target's framework
///    dependencies ("Metadata extraction skipped" when it finds none). The
///    weak link Runner needs for iOS 13–15 now comes from a Frameworks build
///    phase entry with the Weak attribute instead.
///
/// CI verifies both: the intents must be present in both bundles' metadata
/// **with a non-empty mangledTypeName** (codemagic.yaml).
///
/// This file is compiled into the widget extension **and** the app — Apple's
/// interactivity doc requires a widget button's intent in both targets — and
/// the two copies are byte-identical on purpose: differing conformance lists
/// between the copies produce differing metadata descriptors for one type
/// name, which is exactly the ambiguity nobody can debug from a device.
/// `FatVpnWidgetControl.swift` (widget-only) is what puts the set intent on a
/// Control Center toggle.

/// The home-screen power button, iOS 18+ only (the version gate lives in the
/// view; iOS 16–17 press stays the `fatvpn://widget/toggle` link, confirmed
/// on devices — builds 207 and 234).
@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FatVpnTunnelToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle the VPN"
    static var description = IntentDescription("Connects or disconnects FatVPN.")

    func perform() async throws -> some IntentResult {
        // First line, before anything that can fail: the trail is how a device
        // proves perform() ran at all — the question that killed three build
        // cycles of the previous architecture.
        FatVpnWidgetStore.trace("press → native toggle (widget process)")
        try await FatVpnWidgetTunnel.toggle()
        return .result()
    }
}

/// The Control Center switch (iOS 18+): the system hands over the direction
/// the user flipped it in. Same native tunnel path as the button.
@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FatVpnTunnelSetIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set the VPN"
    static var description = IntentDescription("Turns FatVPN on or off.")

    @Parameter(title: "Running")
    var value: Bool

    func perform() async throws -> some IntentResult {
        FatVpnWidgetStore.trace("control → native set(\(value)) (widget process)")
        try await FatVpnWidgetTunnel.setStarted(value)
        return .result()
    }
}
