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

    /// What the OS says about the tunnel right now, for the tile to draw from.
    ///
    /// The widget's timeline used to draw the record another process had
    /// written, which is only ever as fresh as the reload that was supposed to
    /// follow it — and the reload the packet-tunnel extension asks for does not
    /// arrive (2026-08-04: the tile sat on "Подключение…" for five seconds over
    /// a connected tunnel, then over a disconnected one, until the app was
    /// opened). Asking here costs one preferences load and cannot be lost in
    /// the post.
    ///
    /// Quiet on purpose: this runs on WidgetKit's schedule, and a trail entry
    /// per refresh would push the press trail — 60 lines, the only witness a
    /// press has — out of the App Group before anyone read it.
    static func liveState() async -> FatVpnLiveTunnelState? {
        guard let manager = await loadManager(quiet: true) else { return nil }
        return liveState(of: manager)
    }

    private static func liveState(of manager: NETunnelProviderManager) -> FatVpnLiveTunnelState? {
        switch manager.connection.status {
        case .connected:
            return FatVpnLiveTunnelState(
                state: "connected", connectedAt: manager.connection.connectedDate)
        case .connecting, .reasserting:
            return FatVpnLiveTunnelState(state: "connecting", connectedAt: nil)
        case .disconnecting:
            return FatVpnLiveTunnelState(state: "disconnecting", connectedAt: nil)
        case .disconnected:
            return FatVpnLiveTunnelState(state: "disconnected", connectedAt: nil)
        case .invalid:
            // No usable configuration — the stored record is a better guess
            // than "disconnected", which would blank a tile mid-session.
            return nil
        @unknown default:
            return nil
        }
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
        // The status is the decision: a stale .connecting here is why a press
        // meant as "connect" can issue a stop. One line makes that visible
        // from a support bundle instead of deniable.
        let status = manager.connection.status
        FatVpnWidgetStore.trace(
            "native toggle: status=\(status.rawValue) → \(started(status) ? "stop" : "start")")
        if started(status) {
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
            guard !started(manager.connection.status) else {
                // Traced, not silent: "flipped the switch and nothing
                // happened" must be tellable apart from "perform() never ran".
                FatVpnWidgetStore.trace("native set(true): already started, nothing to do")
                return
            }
            try await start(manager)
        } else {
            guard started(manager.connection.status) else {
                FatVpnWidgetStore.trace("native set(false): already stopped, nothing to do")
                return
            }
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
            // The session begins with the press. Refined to the OS's own
            // connect date below if we are still alive when the tunnel lands;
            // written here first so a press whose intent the system cuts short
            // still leaves the app an anchor that is not last week's.
            FatVpnWidgetStore.markNativeSessionStart(Date())
            await publishWhenSettled(wantStarted: true)
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
        // The session ends here, whoever starts the next one.
        FatVpnWidgetStore.clearNativeSessionStart()
        // No clearPress: the overlay is superseded the moment the state moves,
        // and its own window is short (stopOptimism) either way. What the tile
        // does need is somebody to notice the tunnel actually went down.
        await publishWhenSettled(wantStarted: false)
    }

    /// Follows the tunnel to where the press was aiming, then writes that into
    /// the snapshot the tile draws from — from the widget's own process, where
    /// a `reloadAllTimelines()` demonstrably lands.
    ///
    /// The tile is redrawn by WidgetKit, not by us, and only when somebody asks
    /// for a reload. The packet-tunnel extension asks (`patchTunnelState` on
    /// every start and stop) and it does not work: on 2026-08-04 an iPhone 15
    /// showed "Подключение…" over a tunnel that had been up for five seconds,
    /// and "Отключение…" over one that was already down, both until the app
    /// came to the front and published from *its* process. So the press waits
    /// for its own outcome instead of trusting a message to be delivered.
    ///
    /// Bounded, and short: an App Intent that runs too long is killed, and the
    /// timeline asks for a refresh of its own while the tile is busy, so an
    /// answer that misses this window is late rather than lost.
    private static func publishWhenSettled(wantStarted: Bool) async {
        let deadline = Date().addingTimeInterval(wantStarted ? 6 : 4)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Re-loaded rather than re-read: a connection object is only as
            // live as the process's subscription to it, and this process was
            // launched for one press.
            guard let manager = await loadManager(quiet: true),
                  let live = liveState(of: manager) else { continue }
            if wantStarted, live.state == "connected" {
                let startedAt = live.connectedAt ?? Date()
                FatVpnWidgetStore.markNativeSessionStart(startedAt)
                FatVpnWidgetStore.patchTunnelState("connected", connectedAt: startedAt)
                FatVpnWidgetStore.trace("native start settled: connected")
                return
            }
            if !wantStarted, live.state == "disconnected" {
                FatVpnWidgetStore.patchTunnelState("disconnected", connectedAt: nil)
                FatVpnWidgetStore.trace("native stop settled: disconnected")
                return
            }
        }
        FatVpnWidgetStore.trace(
            "native \(wantStarted ? "start" : "stop"): still moving after the wait")
        // Redraw anyway: the timeline reads the live status for itself now, so
        // even an unsettled tile shows what the OS is actually doing.
        FatVpnWidgetStore.reloadWidgets()
    }

    // MARK: - Plumbing

    /// [quiet] is for the callers that run on a schedule rather than on a press
    /// — one attempt, nothing written to the trail (see [liveState]).
    private static func loadManager(quiet: Bool = false) async -> NETunnelProviderManager? {
        if quiet {
            let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
            return managers?.first
        }
        return await loadManagerTraced()
    }

    private static func loadManagerTraced() async -> NETunnelProviderManager? {
        // Asked twice before concluding there is no configuration: the first
        // read may happen in a process the system only just launched, and one
        // empty answer there would cost the press entirely.
        //
        // do/catch rather than `try?` (2026-08-04): "no configuration exists"
        // and "the load was DENIED" are opposite diagnoses — the first means
        // consent was never given, the second would mean the entitlement-free
        // widget assumption does not hold on this OS — and `try?` folded both
        // into one silent nil. The NEVPNError in the trail is what tells a
        // phone with a visible FatVPN profile in Settings apart from one
        // without.
        for attempt in 1...2 {
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                if let manager = managers.first { return manager }
                FatVpnWidgetStore.trace("native load #\(attempt): 0 configurations")
            } catch {
                FatVpnWidgetStore.trace(
                    "native load #\(attempt) failed: \((error as NSError).domain)"
                    + " \((error as NSError).code) \(error.localizedDescription)")
            }
        }
        return nil
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
