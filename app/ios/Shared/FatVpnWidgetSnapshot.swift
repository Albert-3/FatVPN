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

    /// Where the widget's power button leaves what it wants done, for the app to
    /// pick up ([takePendingAction]).
    ///
    /// It has to be a mailbox rather than a deep link because of what the button
    /// is on iOS 17: an App Intent, which can ask the system to open the
    /// containing app but cannot hand it a URL. It is also the more robust of
    /// the two — `fatvpn://` reaching Dart on iOS has never been verified — so
    /// this is the path the button uses, and the deep link stays as the fallback
    /// for iOS 16 and below, where a widget tap can only be a link.
    static let pendingActionKey = "fatvpn.widget.pendingAction"
    static let pendingActionAtKey = "fatvpn.widget.pendingActionAt"

    /// How long a parked action stays worth acting on. The app is expected
    /// within a second or two — the same tap opens it — so anything older than
    /// this is a tap whose app launch never happened, and carrying it out at the
    /// user's *next* launch would toggle their VPN for no visible reason.
    static let pendingActionTTL: TimeInterval = 120

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

    /// Posted in-process the moment an action is parked, so the app can collect
    /// it there and then.
    ///
    /// Polling alone is not enough: with `openAppWhenRun` the system performs
    /// the intent **in the app's process**, and it does so *after* the app is
    /// already active — i.e. after both places that poll have run (startup and
    /// `AppLifecycleState.resumed`). The tap would then sit in the App Group
    /// until the user backgrounded and reopened the app, which is a button that
    /// does nothing as far as anyone pressing it is concerned. AppDelegate
    /// listens for this and pushes it down the `fatvpn/widget` channel.
    static let actionRequestedNotification = Notification.Name("fatvpn.widget.actionRequested")

    /// Parks what a widget tap asked for. Called from the power button's App
    /// Intent — in the app's process when the app can be opened, in the widget
    /// extension's otherwise. Either way the mailbox is the shared App Group, so
    /// the reader does not have to know which one it was.
    static func requestAction(_ action: String) {
        guard let defaults = defaults else { return }
        defaults.set(action, forKey: pendingActionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingActionAtKey)
        NotificationCenter.default.post(name: actionRequestedNotification, object: nil)
    }

    /// Takes the parked action, leaving nothing behind. Called by the app (see
    /// the `fatvpn/widget` channel in AppDelegate) on launch and on every
    /// resume, since the app is often already running when its widget is
    /// tapped.
    static func takePendingAction() -> String? {
        guard let defaults = defaults,
              let action = defaults.string(forKey: pendingActionKey) else {
            return nil
        }
        let at = defaults.double(forKey: pendingActionAtKey)
        defaults.removeObject(forKey: pendingActionKey)
        defaults.removeObject(forKey: pendingActionAtKey)
        // Cleared either way: an action too old to act on is also too old to
        // keep, or it would fire at some unrelated launch later on.
        guard at > 0, Date().timeIntervalSince1970 - at < pendingActionTTL else {
            return nil
        }
        return action
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
