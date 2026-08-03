import Foundation
import NetworkExtension

/// Starts and stops the tunnel natively — the sing-box architecture, adopted
/// 2026-08-04 after the app-process intent failed on its third device
/// (see FatVpnWidgetIntents.swift for that story).
///
/// Compiled into **both** the widget extension and the app. In the widget it
/// is the whole point: the power button's intent performs in the widget's own
/// process and drives `NETunnelProviderManager` right here, exactly as
/// sing-box VT ships it (WidgetExtension/WidgetTunnelControl.swift in
/// SagerNet/sing-box-for-apple — an App Store app). In the app it exists
/// because Apple's interactivity doc says a widget button's intent must be in
/// both targets, and the same code is correct in either process.
///
/// ⚠️ **No NetworkExtension entitlement on the widget, on purpose.** The
/// widget's `.entitlements` carries only the App Group — sing-box's widget
/// ships the same way. `NETunnelProviderManager` authorizes by "configurations
/// created by the calling app", and an appex inside the app's bundle
/// qualifies. The old belief that a widget can never touch the tunnel (which
/// justified routing the press into the app's process, the scheme that never
/// worked) is disproven by that shipping code.
///
/// What this path deliberately does NOT do: the live 402 entitlement check
/// and the fresh config a Dart-driven connect performs. There is no Flutter
/// in a widget process (hard memory limit — sing-box decoupled even their own
/// Library framework from theirs). A native start rides the same persisted
/// snapshot an on-demand start uses: `PacketTunnelProvider` falls back to
/// `start_options.plist` (versioned, refused after 7 days), and logout/402
/// wipes both that snapshot and the VPN profile (`stopAndForgetStandalone`),
/// so a dead session has nothing here to start from — and no session means
/// the tile does not draw a button at all.
enum FatVpnWidgetTunnel {
    /// Marker parked in `providerConfiguration` when a widget stop takes the
    /// on-demand rule off, so a widget start can put it back. In-app connects
    /// overwrite the whole protocol configuration from current settings, so a
    /// stale marker cannot outlive the next real connect. Same trick, same
    /// job, as sing-box's key of the same name.
    private static let wasOnDemandKey = "wasOnDemandEnabled"

    static func isStarted() async -> Bool {
        guard let manager = await loadManager() else { return false }
        return started(manager.connection.status)
    }

    /// The power button: resolve the direction against the live connection —
    /// the tile may be a redraw behind the tunnel — and go.
    static func toggle() async throws {
        guard let manager = await loadManager() else {
            // No saved configuration: the system VPN consent dialog has never
            // been accepted on this install. That needs a screen, and a plain
            // widget-process intent has no way to raise one — the first
            // connect has to happen in the app. The trace is the only witness.
            FatVpnWidgetStore.trace("native toggle: no vpn configuration")
            throw FatVpnWidgetTunnelError.noConfiguration
        }
        if started(manager.connection.status) {
            try await stop(manager)
        } else {
            try await start(manager)
        }
    }

    /// The Control Center toggle: the system says which way the switch went.
    static func setStarted(_ wanted: Bool) async throws {
        guard let manager = await loadManager() else {
            FatVpnWidgetStore.trace("native set(\(wanted)): no vpn configuration")
            throw FatVpnWidgetTunnelError.noConfiguration
        }
        if wanted {
            guard !started(manager.connection.status) else { return }
            try await start(manager)
        } else {
            guard started(manager.connection.status) else { return }
            try await stop(manager)
        }
    }

    // MARK: - The two directions

    private static func start(_ manager: NETunnelProviderManager) async throws {
        // Answer the press on the tile before the tunnel has moved — the
        // overlay is ignored the moment the real state changes.
        FatVpnWidgetStore.markPressed("connecting")
        var needsSave = false
        if !manager.isEnabled {
            // Another VPN app was used since: iOS flips our profile off when a
            // different one connects. Re-enabling is what makes the start work
            // on the first press instead of the second (the Tailscale
            // double-tap bug is exactly this, left unhandled).
            manager.isEnabled = true
            needsSave = true
        }
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
           var config = proto.providerConfiguration,
           config[wasOnDemandKey] as? Bool == true {
            // A widget stop parked the on-demand rule here; give it back so
            // the kill-switch recovery the user configured survives a widget
            // round trip.
            config.removeValue(forKey: wasOnDemandKey)
            proto.providerConfiguration = config
            manager.isOnDemandEnabled = true
            needsSave = true
        }
        do {
            if needsSave {
                try await manager.saveToPreferences()
                // Apple quirk, learned in the app's own connect path: a manager
                // must be re-loaded after a save before its connection can be
                // started, or startVPNTunnel throws configurationInvalid.
                try await manager.loadFromPreferences()
            }
            // No options: the extension falls back to its persisted snapshot,
            // the same path an on-demand start takes — including the staleness
            // check that refuses a snapshot older than its session.
            try manager.connection.startVPNTunnel()
            FatVpnWidgetStore.trace("native start issued")
        } catch {
            FatVpnWidgetStore.clearPress()
            FatVpnWidgetStore.trace("native start failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func stop(_ manager: NETunnelProviderManager) async throws {
        FatVpnWidgetStore.markPressed("disconnecting")
        // The on-demand rule is our kill switch and exists precisely to raise
        // the tunnel whenever it is down — it does not care who stopped it. It
        // has to come off before the stop, or the user watches the tile go to
        // "Disconnected" and straight back.
        if manager.isOnDemandEnabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                config[wasOnDemandKey] = true
                proto.providerConfiguration = config
            }
            manager.isOnDemandEnabled = false
            do {
                try await manager.saveToPreferences()
                FatVpnWidgetStore.trace("native stop: cleared the on-demand rule")
            } catch {
                // Stopping anyway — a stop the system may undo still beats no
                // stop — but the trail has to say so, or the tunnel coming back
                // a moment later looks spontaneous.
                FatVpnWidgetStore.trace(
                    "native stop: could not clear on-demand (\(error.localizedDescription))")
            }
        }
        manager.connection.stopVPNTunnel()
        FatVpnWidgetStore.trace("native stop issued")
        // No clearPress: the extension's own teardown patches the snapshot to
        // "disconnected" within seconds, which supersedes the overlay; the
        // stop overlay's own window is short (stopOptimism) either way.
    }

    // MARK: - Plumbing

    private static func loadManager() async -> NETunnelProviderManager? {
        // Asked twice before concluding there is no configuration: the first
        // read may happen in a process the system only just launched, and one
        // empty answer there would cost the press entirely.
        if let manager = try? await NETunnelProviderManager.loadAllFromPreferences().first {
            return manager
        }
        return try? await NETunnelProviderManager.loadAllFromPreferences().first
    }

    private static func started(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting:
            return true
        default:
            return false
        }
    }
}

enum FatVpnWidgetTunnelError: Error {
    case noConfiguration
}
