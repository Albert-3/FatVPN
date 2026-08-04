import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center toggle (iOS 18+) — the one surface where a background
/// VPN toggle is *proven* in the field: sing-box VT, Tailscale and
/// Shadowrocket all ship theirs exactly here, as a `ControlWidgetToggle`
/// whose intent performs in the widget extension's process and drives
/// `NETunnelProviderManager` natively. This file mirrors sing-box's
/// ServiceToggleControl.swift shape deliberately — it is the only publicly
/// readable implementation known to work.
///
/// Widget-extension target only: `ControlWidget` does not exist in an app
/// target's world, and nothing here is needed by the app.
///
/// The label is intentionally static English ("FatVPN" / On–Off imagery):
/// controls are rendered by the system in contexts (Control Center grid,
/// lock screen, Action button) where our app-language store may not have
/// been read yet, and a wrong-language word is worse than a neutral icon.
@available(iOS 18.0, iOSApplicationExtension 18.0, *)
struct FatVpnWidgetControl: ControlWidget {
    static let kind = "FatVpnToggleControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle(
                "FatVPN",
                isOn: isOn,
                action: FatVpnTunnelSetIntent()
            ) { on in
                Label("FatVPN", systemImage: on ? "lock.shield.fill" : "lock.open")
            }
            .tint(Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255))
        }
        .displayName("FatVPN")
        .description("Turns FatVPN on or off.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        /// Live from the connection, not from the snapshot: Control Center
        /// asks at render time, and the tunnel may have moved without the app
        /// (an on-demand start, a stop from Settings) since the last publish.
        func currentValue() async throws -> Bool {
            await FatVpnWidgetTunnel.isStarted()
        }
    }
}
