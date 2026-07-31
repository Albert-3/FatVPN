import AppIntents
import WidgetKit

/// What the widget's power button runs on iOS 17 and up.
///
/// It exists to make the button a *button*: on a small widget SwiftUI ignores
/// `Link`, so the whole tile used to be one tap target and there was no way to
/// tap "the widget" without also toggling the VPN. An interactive `Button`
/// coexists with the tile's `widgetURL`, which is exactly the split the user
/// gets: the disc toggles, everything around it opens the app.
///
/// What it deliberately does not do is touch the tunnel. Every route to
/// `NETunnelProviderManager` needs the NetworkExtension entitlement, and a
/// widget extension is a separate App ID that has none — so this intent parks
/// the request where the app will find it and asks the system to bring the app
/// forward (`openAppWhenRun`). The app then does what it always does: check the
/// entitlement live, fetch a fresh config, and connect — to the best server
/// when no country has been chosen, which is every first press.
///
/// ⚠️ This file is compiled into **both** the widget extension and the app
/// (`ios/tool/add_widget_target.rb` adds it to the Runner target as well).
/// `openAppWhenRun` means the system performs the intent *in the app's process*,
/// and an app whose binary does not contain the intent type cannot perform it —
/// the press then does nothing at all, with no error anywhere. That is exactly
/// what a device showed: widgets rendered, button dead. Hence the availability
/// below names `iOS` too, so the type is gated in the app (whose deployment
/// target is 13.0) and not only in the extension.
@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct FatVpnTogglePowerIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle the VPN"
    static var description = IntentDescription("Connects or disconnects FatVPN.")

    /// The whole point: the tunnel can only be raised or lowered by the app.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // "toggle", not "connect": the widget draws from a snapshot that may be
        // a moment behind the tunnel, so the app decides which direction this
        // was — see HomeWidgetAction.toggle on the Dart side.
        FatVpnWidgetSnapshot.requestAction("toggle")
        // The snapshot has not changed yet (the app has not connected), but the
        // widget should stop looking untouched the instant it is pressed.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
