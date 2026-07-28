import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the home-screen widget draws, and the only channel it has to the rest
/// of the app.
///
/// Compiled into three targets — Runner, PacketTunnel and FatVpnWidget — and
/// that is the point: a widget extension cannot ask the tunnel anything. Reading
/// `NEVPNStatus` needs the NetworkExtension entitlement, which the widget does
/// not have (and would need its own App ID capability for), so the two sides
/// that *do* know the state write it down here instead:
///
///  * the app, on every state change the UI sees (`HomeWidgetBridge` → the
///    `fatvpn/widget` channel in AppDelegate), together with everything only it
///    knows: the chosen location, the language, whether there is a subscription;
///  * the packet-tunnel extension, when the tunnel comes up or goes down
///    *without* the app — which is the normal case on iOS, where the OS starts
///    the extension on demand.
///
/// The store is the shared App Group container. Without that entitlement
/// `UserDefaults(suiteName:)` returns nil and the widget shows its "open the
/// app" fallback forever — see the entitlement check in codemagic.yaml, which
/// exists to catch exactly that before a build reaches TestFlight.
struct FatVpnWidgetSnapshot {
    static let appGroupID = "group.com.fatvpn.fatvpnApp"
    static let defaultsKey = "fatvpn.widget.snapshot"

    /// Bumped when the shape changes, so a widget left behind by an older
    /// install renders its fallback instead of misreading fields. Mirrors
    /// `HomeWidgetSnapshot.version` on the Dart side.
    static let currentVersion = 1

    var version: Int = 0
    var state: String = "disconnected"
    /// The language picked *in the app*, not the phone's. They differ often
    /// enough that following the system locale would contradict the app.
    var language: String?
    var signedIn: Bool = false
    var locationLabel: String?
    var flagEmoji: String?
    var connectedAt: Date?
    var expiresAt: Date?

    /// Green on the widget means exactly this and nothing looser: a tunnel that
    /// is connecting is not carrying anything yet.
    var isConnected: Bool { state == "connected" }

    /// What a widget shows when nothing has ever been published: an install that
    /// has not been opened, or an App Group that is not actually shared.
    static let unknown = FatVpnWidgetSnapshot()

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func read() -> FatVpnWidgetSnapshot {
        guard let stored = defaults?.dictionary(forKey: defaultsKey) else {
            return .unknown
        }
        var snapshot = FatVpnWidgetSnapshot()
        snapshot.version = stored["v"] as? Int ?? 0
        snapshot.state = stored["state"] as? String ?? "disconnected"
        snapshot.language = stored["lang"] as? String
        snapshot.signedIn = stored["signedIn"] as? Bool ?? false
        snapshot.locationLabel = stored["locationLabel"] as? String
        snapshot.flagEmoji = stored["flagEmoji"] as? String
        snapshot.connectedAt = date(from: stored["connectedAtMillis"])
        snapshot.expiresAt = date(from: stored["expiresAtMillis"])
        // A record written by a future (or corrupted) build is not worth
        // guessing at: everything below the current version renders as "no data
        // yet", which the widget already knows how to draw.
        guard snapshot.version == currentVersion else { return .unknown }
        return snapshot
    }

    /// Stores the dictionary the app published, verbatim. Called from the
    /// `fatvpn/widget` platform channel, whose payload is already this shape.
    static func write(_ dictionary: [String: Any]) {
        defaults?.set(dictionary, forKey: defaultsKey)
        reloadWidgets()
    }

    /// Overwrites the tunnel half of the snapshot, leaving what only the app
    /// knows (location, language, subscription) untouched.
    ///
    /// This is what the packet-tunnel extension calls. It runs when the app is
    /// not there — an on-demand start, a stop from Settings → VPN — so a full
    /// rewrite here would blank the location and the language for as long as it
    /// takes the user to open the app again.
    static func patchTunnelState(_ state: String, connectedAt: Date?) {
        guard let defaults = defaults else { return }
        var stored = defaults.dictionary(forKey: defaultsKey) ?? [:]
        // A record the app has never written has no version; stamping it keeps
        // read() from discarding what the extension just observed.
        stored["v"] = currentVersion
        stored["state"] = state
        if let connectedAt = connectedAt {
            stored["connectedAtMillis"] = Int(connectedAt.timeIntervalSince1970 * 1000)
        } else {
            stored.removeValue(forKey: "connectedAtMillis")
        }
        defaults.set(stored, forKey: defaultsKey)
        reloadWidgets()
    }

    /// Logging out does not need a method of its own: the app publishes a
    /// snapshot with no location, no session and `signedIn: false`
    /// (`HomeWidgetBridge.clearSession`), and [write] replaces the whole record
    /// — so nothing about the finished session survives it.
    static func reloadWidgets() {
        #if canImport(WidgetKit)
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    private static func date(from value: Any?) -> Date? {
        guard let millis = (value as? NSNumber)?.doubleValue, millis > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
