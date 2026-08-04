import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the home-screen widget draws, and the only channel it has to the rest
/// of the app.
///
/// Compiled into three targets — Runner, PacketTunnel and FatVpnWidget — because
/// a widget extension cannot ask the tunnel anything: reading `NEVPNStatus`
/// needs the NetworkExtension entitlement, which is never issued to a widget's
/// App ID. So the two sides that do know the state write it down here instead:
///
///  * the app, on every state change its UI sees (`HomeWidgetBridge` → the
///    `fatvpn/widget` channel), together with what only it knows — the chosen
///    location, the language, whether there is a session at all;
///  * the packet-tunnel extension, when the tunnel comes up or goes down
///    *without* the app, which on iOS is the normal case (on-demand start, a
///    stop from Settings → VPN).
///
/// The store is the shared App Group container. Without that entitlement
/// `UserDefaults(suiteName:)` returns nil and every read below falls back to
/// `.empty`, i.e. the widget's "open the app" state — which is why codemagic.yaml
/// verifies the entitlement survived re-signing rather than trusting the
/// .entitlements file.
struct FatVpnWidgetSnapshot: Equatable {
    /// Bumped when the stored shape changes, so a tile left behind by an older
    /// install renders its fallback instead of misreading fields. Mirrors
    /// `HomeWidgetSnapshot.version` on the Dart side.
    static let currentVersion = 1

    var version = 0
    var state = "disconnected"
    /// The language chosen *in the app*, not the phone's — they disagree often
    /// enough that following the system locale would contradict the app.
    var language: String?
    var signedIn = false
    var locationLabel: String?
    var flagEmoji: String?
    var connectedAt: Date?

    /// Green means this and nothing looser. A tunnel that is still connecting
    /// carries no traffic yet, and "green" beside a status line is read as
    /// "my traffic is protected".
    var isConnected: Bool { state == "connected" }

    /// A tunnel moving in either direction. The press overlay produces these
    /// two as well, so the tile can answer a tap before the tunnel does.
    var isBusy: Bool {
        state == "connecting" || state == "preparing" || state == "disconnecting"
    }

    /// What a widget shows when nothing has ever been published: an install
    /// nobody has opened, or an App Group that is not actually shared.
    static let empty = FatVpnWidgetSnapshot()
}

/// The tunnel state as the OS reports it *right now*, read by the widget's own
/// process — see `FatVpnWidgetTunnel.liveState()`.
///
/// The stored snapshot is a message from another process, and a message only
/// arrives if somebody delivers it. This is the state nobody has to deliver.
struct FatVpnLiveTunnelState {
    let state: String
    /// When the OS says the current connection came up, where it knows. Not the
    /// same thing as the *session* start the app keeps — see [FatVpnWidgetStore.read].
    let connectedAt: Date?
}

/// What a press asked for, parked in the App Group for the app to collect.
///
/// It has to be a mailbox rather than a URL because of what the button is on
/// iOS 17+: an App Intent, which may ask the system to open its app but cannot
/// hand that app a link.
enum FatVpnWidgetAction: String {
    case connect
    case disconnect
    /// The direction is resolved by whoever performs it, against the live
    /// tunnel rather than the snapshot the tile happened to be drawing.
    case toggle
}

enum FatVpnWidgetStore {
    static let appGroupID = "group.com.fatvpn.fatvpnApp"

    private static let snapshotKey = "fatvpn.widget.snapshot"
    private static let actionKey = "fatvpn.widget.action"
    private static let actionAtKey = "fatvpn.widget.actionAt"
    private static let pressKey = "fatvpn.widget.press"
    private static let pressAtKey = "fatvpn.widget.pressAt"
    private static let trailKey = "fatvpn.widget.trail"
    private static let nativeSessionKey = "fatvpn.widget.nativeSessionAt"

    /// How long a parked action stays worth acting on. The app is expected
    /// within a second or two — on iOS 17 the same press opens it — so anything
    /// older is a press whose launch never happened, and carrying it out at the
    /// user's *next* launch would toggle their VPN for no visible reason.
    static let actionTTL: TimeInterval = 120

    /// How long the press overlay may claim a direction on nothing but its own
    /// say-so. Generous for a connect, whose work is two network round trips
    /// and a ping of every candidate node before the extension is so much as
    /// asked to start; short for a stop, which is one message to an extension
    /// that is already running. Both are only a backstop — the overlay is
    /// ignored the moment the real state moves.
    static let connectOptimism: TimeInterval = 100
    static let stopOptimism: TimeInterval = 8

    static let trailLimit = 60

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    // MARK: - Snapshot

    /// Reads what the tile should draw.
    ///
    /// [live] is the tunnel state the widget process just asked the OS for, and
    /// when it is there it **wins** over the stored one. That is not belt and
    /// braces, it is the fix for a tile that stayed on "Подключение…" over a
    /// live tunnel until the user opened the app (reported from an iPhone 15 /
    /// iOS 26.5.2, 2026-08-04, with the video to prove it): the record on disk
    /// was right — the packet-tunnel extension patches it the moment the tunnel
    /// comes up — but the `reloadAllTimelines()` next to that patch never
    /// reached WidgetKit, so nothing ever re-rendered the tile. A snapshot the
    /// widget reads for itself needs no delivery.
    ///
    /// Everything the OS cannot know — the location, the language, whether
    /// there is a session at all — still comes from the stored record.
    static func read(live: FatVpnLiveTunnelState? = nil) -> FatVpnWidgetSnapshot {
        guard let stored = defaults?.dictionary(forKey: snapshotKey) else {
            // Nothing has ever been published: there is no session to draw a
            // button for, whatever the tunnel is doing.
            return .empty
        }
        var snapshot = FatVpnWidgetSnapshot()
        snapshot.version = stored["v"] as? Int ?? 0
        snapshot.state = stored["state"] as? String ?? "disconnected"
        snapshot.language = stored["lang"] as? String
        snapshot.signedIn = stored["signedIn"] as? Bool ?? false
        snapshot.locationLabel = stored["locationLabel"] as? String
        snapshot.flagEmoji = stored["flagEmoji"] as? String
        snapshot.connectedAt = date(from: stored["connectedAtMillis"])
        // A record written by a future (or corrupted) build is not worth
        // guessing at: anything but the current version renders as "no data
        // yet", which the tile already knows how to draw.
        guard snapshot.version == FatVpnWidgetSnapshot.currentVersion else { return .empty }
        if let live {
            snapshot = merge(live, into: snapshot)
        }
        return applyPress(to: snapshot)
    }

    /// Puts the OS's answer over the stored one — for the *state*, and for the
    /// state only. The clock keeps the stored start.
    ///
    /// The session start is deliberately not `connection.connectedDate`. A
    /// session survives a reconnect (a server switch, a network change) and the
    /// OS's date restarts with every re-establish, so the two disagree by
    /// design — and the app's screen counts from the stored one. Preferring
    /// anything else here puts a different number on the tile than in the app,
    /// which is what the owner reported on 2026-08-05: "таймер не совпадает".
    /// The OS's date is a seed for a record that has none, nothing more.
    private static func merge(
        _ live: FatVpnLiveTunnelState,
        into snapshot: FatVpnWidgetSnapshot
    ) -> FatVpnWidgetSnapshot {
        var merged = snapshot
        merged.state = live.state
        guard live.state == "connected" else {
            merged.connectedAt = nil
            return merged
        }
        merged.connectedAt = snapshot.connectedAt ?? live.connectedAt
        return merged
    }

    /// Stores what the app published.
    ///
    /// ⚠️ Not verbatim, and that is the whole point of [plistSafe]: the payload
    /// crossing `fatvpn/widget` carries Dart `null` for every field the session
    /// does not have yet — no location picked, no clock running, no expiry
    /// known — and Flutter's codec renders those as `NSNull`. `UserDefaults`
    /// takes property lists only, and `NSNull` is not one: it raises
    /// `NSInvalidArgumentException`, which in Swift is an ObjC exception nobody
    /// can catch, i.e. `SIGABRT`.
    ///
    /// That is not a hypothetical. Build 205 died exactly here on an iPhone 11
    /// (crash 2026-08-01, `FatVpnWidgetStore.write` ← `attachWidgetChannel`),
    /// on the app's very first publish, before any screen appeared — and the
    /// same line, unfiltered, was in the implementation this one replaced. It
    /// was only ever dormant because the removal of the widget took the channel
    /// with it, so nothing on iOS called this at all.
    static func write(_ dictionary: [String: Any]) {
        defaults?.set(plistSafe(dictionary), forKey: snapshotKey)
        reloadWidgets()
    }

    /// Drops what `UserDefaults` would abort over, rather than translating it.
    ///
    /// A dropped key and a key holding null mean the same thing to every reader
    /// here — `stored["locationLabel"] as? String` is nil either way, and
    /// [write] replaces the whole record, so a field that has gone away really
    /// does go away. Nested containers are walked too: the payload is flat
    /// today, and a future field that is not would otherwise reintroduce this
    /// crash somewhere no one is looking.
    private static func plistSafe(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.compactMapValues { element in
                element is NSNull ? nil : plistSafe(element)
            }
        }
        if let array = value as? [Any] {
            return array.filter { !($0 is NSNull) }.map(plistSafe)
        }
        return value
    }

    /// Overwrites the tunnel half of the snapshot, leaving what only the app
    /// knows — location, language, session — untouched.
    ///
    /// This is what the packet-tunnel extension calls. It runs when the app is
    /// not there, so a full rewrite here would blank the location and the
    /// language for as long as it takes the user to open the app again.
    static func patchTunnelState(_ state: String, connectedAt: Date?) {
        guard let defaults else { return }
        var stored = defaults.dictionary(forKey: snapshotKey) ?? [:]
        // A record the app has never written carries no version; stamping it
        // keeps `read()` from discarding what the extension just observed.
        stored["v"] = FatVpnWidgetSnapshot.currentVersion
        let sessionWasUnderWay = (stored["state"] as? String) == "connected"
            && stored["connectedAtMillis"] != nil
        stored["state"] = state
        if let connectedAt {
            // A start is written once per session, not once per tunnel. Every
            // caller here has its own idea of "now" — the extension's is the
            // moment sing-box came up, the widget press's is the OS's
            // `connectedDate`, the app's is where its own connect finished —
            // and they sit seconds apart, which is exactly the drift between
            // the tile's clock and the app's that was reported on 2026-08-05.
            // Whoever got there first for this session wins; a tunnel that
            // merely re-established (on-demand, a jetsam restart) keeps
            // counting, which is also what the app's session clock does.
            if !sessionWasUnderWay {
                stored["connectedAtMillis"] = Int(connectedAt.timeIntervalSince1970 * 1000)
            }
        } else {
            stored.removeValue(forKey: "connectedAtMillis")
        }
        defaults.set(stored, forKey: snapshotKey)
        reloadWidgets()
    }

    // MARK: - The press overlay

    /// Records the direction the power button was pressed in and redraws every
    /// tile, so the press is answered in the same instant rather than several
    /// seconds later.
    ///
    /// Without this the widget answers a press by redrawing exactly what it
    /// drew before, which is indistinguishable from a button that does nothing
    /// — and is what a user with a working button reported as one.
    static func markPressed(_ direction: String) {
        guard let defaults else { return }
        defaults.set(direction, forKey: pressKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pressAtKey)
        reloadWidgets()
    }

    /// Drops the overlay the moment the attempt behind it ends. Without it the
    /// tile would go on saying "Connecting…" for the rest of the window over a
    /// connect that is no longer happening.
    static func clearPress() {
        guard let defaults, defaults.object(forKey: pressKey) != nil else { return }
        defaults.removeObject(forKey: pressKey)
        defaults.removeObject(forKey: pressAtKey)
        reloadWidgets()
    }

    /// Lays the press overlay over a stored snapshot, on two conditions: it is
    /// still fresh, and the stored state has not moved on by itself.
    ///
    /// Nothing has to clear the marker for this to stay honest — one whose
    /// tunnel has since spoken is ignored from the next read on, and one whose
    /// press led nowhere expires. The worst a lost clear can do is age out; it
    /// can never leave the tile claiming a connection that is not there.
    private static func applyPress(to snapshot: FatVpnWidgetSnapshot) -> FatVpnWidgetSnapshot {
        guard let defaults, let direction = defaults.string(forKey: pressKey) else {
            return snapshot
        }
        let at = defaults.double(forKey: pressAtKey)
        guard at > 0 else { return snapshot }
        let age = Date().timeIntervalSince1970 - at

        var overlaid = snapshot
        switch direction {
        case "connecting":
            // `error` is deliberately not on this list: it belongs to the
            // *previous* session, and a connect still on its way up must not be
            // drawn from it.
            let tunnelSpeaksForItself = ["connected", "connecting", "preparing", "disconnecting"]
                .contains(snapshot.state)
            guard age < connectOptimism, !tunnelSpeaksForItself else { return snapshot }
            overlaid.state = "connecting"
        case "disconnecting":
            guard age < stopOptimism, snapshot.state != "disconnected" else { return snapshot }
            overlaid.state = "disconnecting"
        default:
            return snapshot
        }
        // Neither direction has a running session to count, and the stored
        // start belongs to one that is on its way out or has not begun.
        overlaid.connectedAt = nil
        return overlaid
    }

    // MARK: - A session the app was never told about

    /// Records that a *widget* press is what raised this tunnel, and when.
    ///
    /// The app anchors a session in its own connect path, and a widget start
    /// never goes near it: no Flutter runs in a widget process. Without this
    /// the app inherits the start of whatever session it last saw — which is
    /// how a tunnel seven seconds old was shown as `00:00:46` on the reporter's
    /// own screen recording (2026-08-04). Written by the press, read once by
    /// the app the next time it reconciles with a live tunnel.
    static func markNativeSessionStart(_ date: Date) {
        defaults?.set(date.timeIntervalSince1970, forKey: nativeSessionKey)
    }

    /// Forgets a marked session start. A stop ends the session it belonged to.
    static func clearNativeSessionStart() {
        defaults?.removeObject(forKey: nativeSessionKey)
    }

    /// Reads the marked start and clears it, so one press anchors one session.
    ///
    /// The marker says *that* a widget press started this session; the instant
    /// handed back is the one the tile is actually counting from, read out of
    /// the snapshot. Two copies of "about now" — the press, and whatever the
    /// tunnel reported a moment later — are what made the app's clock and the
    /// tile's disagree by a few seconds (2026-08-05). One session, one instant,
    /// and it is the one already on screen.
    static func takeNativeSessionStart() -> Date? {
        guard let defaults else { return nil }
        let seconds = defaults.double(forKey: nativeSessionKey)
        guard seconds > 0 else { return nil }
        defaults.removeObject(forKey: nativeSessionKey)
        if let stored = defaults.dictionary(forKey: snapshotKey),
           stored["state"] as? String == "connected",
           let millis = (stored["connectedAtMillis"] as? NSNumber)?.doubleValue,
           millis > 0 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        // Nothing on the tile to agree with — the press is the best anchor
        // there is.
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - The parked action

    /// Posted in-process the moment an action is parked, so an app that is
    /// already running collects it there and then.
    ///
    /// Polling alone is not enough. The system performs the intent **in the
    /// app's process**, and on the open-the-app path it does so *after* the app
    /// is already active — i.e. after both places that poll have run (startup
    /// and `AppLifecycleState.resumed`). The press would then sit here until the
    /// user backgrounded and reopened the app, which is a button that does
    /// nothing as far as anyone pressing it is concerned.
    static let actionPosted = Notification.Name("fatvpn.widget.actionPosted")

    static func park(_ action: FatVpnWidgetAction) {
        guard let defaults else { return }
        defaults.set(action.rawValue, forKey: actionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: actionAtKey)
        NotificationCenter.default.post(name: actionPosted, object: nil)
    }

    /// Takes the parked action, leaving nothing behind.
    static func takeParkedAction() -> FatVpnWidgetAction? {
        guard let defaults, let raw = defaults.string(forKey: actionKey) else { return nil }
        let at = defaults.double(forKey: actionAtKey)
        defaults.removeObject(forKey: actionKey)
        defaults.removeObject(forKey: actionAtKey)
        // Cleared either way: an action too old to act on is also too old to
        // keep, or it fires at some unrelated launch later on.
        guard at > 0, Date().timeIntervalSince1970 - at < actionTTL else { return nil }
        return FatVpnWidgetAction(rawValue: raw)
    }

    // MARK: - The press trail

    /// A step-by-step trace of the press, written natively the moment each step
    /// happens and drained into the Dart log on the app's next launch or resume.
    ///
    /// This exists because the question that killed three build cycles —
    /// *did the intent run at all, and in which process?* — had no answer on the
    /// device: the intent runs with no UI and no console, the Dart log starts
    /// only once an engine does, and a process that is never launched writes
    /// nothing anywhere. Each entry costs one `UserDefaults` write and survives
    /// the writing process dying immediately afterwards.
    static func trace(_ text: String) {
        guard let defaults else { return }
        var trail = defaults.stringArray(forKey: trailKey) ?? []
        trail.append("\(stamp()) \(text)")
        if trail.count > trailLimit {
            trail.removeFirst(trail.count - trailLimit)
        }
        defaults.set(trail, forKey: trailKey)
    }

    /// Read once and cleared, so a trace is reported against exactly one launch.
    static func takeTrail() -> [String] {
        guard let defaults,
              let trail = defaults.stringArray(forKey: trailKey),
              !trail.isEmpty else { return [] }
        defaults.removeObject(forKey: trailKey)
        return trail
    }

    // MARK: - Plumbing

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func stamp() -> String { stampFormatter.string(from: Date()) }

    private static func date(from value: Any?) -> Date? {
        guard let millis = (value as? NSNumber)?.doubleValue, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
