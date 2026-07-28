import Foundation

/// What a health probe concluded about the live tunnel.
///
/// `unknown` is deliberately distinct from `dead`: the probe could not be
/// carried out at all, and an unprovable claim must never become a reason to
/// tear a working tunnel down.
enum TunnelHealthVerdict {
    case healthy
    case dead
    case unknown
}

/// Cumulative byte counters the core reports for the live tunnel.
struct TunnelTraffic {
    let uplinkBytes: Int64
    let downlinkBytes: Int64
}

/// Watches a live tunnel from inside the packet-tunnel extension and rebuilds
/// sing-box when it stops carrying traffic.
///
/// The failure this exists for: after hours of uptime — a network switch, a NAT
/// timeout, the device coming out of a long sleep — sing-box keeps the tunnel
/// *up* while nothing gets through it. `NEVPNStatus` stays `.connected`, so
/// neither iOS nor the app notices, and the only cure the user has is toggling
/// the VPN off and on. This does that for them, at the core level.
///
/// It has to live in the extension rather than in the container app: iOS
/// suspends the app the moment it leaves the foreground, taking every timer in
/// it with it, while this process keeps running for as long as the tunnel does.
/// That is also why the cadence is deliberately slow — this is the one process
/// on the device iOS never puts to sleep, so every round it takes is spent on
/// the user's battery and, on cellular, their data.
final class TunnelHealthWatchdog {
    /// Two independent captive-portal endpoints, both empty 204s served from
    /// everywhere. A `dead` verdict requires *both* to fail: one blocked host
    /// would otherwise be enough to make the watchdog rebuild a perfectly
    /// healthy tunnel in a loop.
    private static let probeURLs = [
        "https://www.gstatic.com/generate_204",
        "http://cp.cloudflare.com/generate_204",
    ]

    private static let probeTimeout: TimeInterval = 8
    private static let controlAPITimeout: TimeInterval = 5

    /// How often a live tunnel is asked whether it still works, on an ordinary
    /// unmetered network.
    ///
    /// Three minutes rather than one: the periodic tick is the *backstop*, not
    /// the detector. Everything that actually breaks a tunnel — a network
    /// switch, an AP re-association, coming out of sleep — already schedules an
    /// out-of-band [checkSoon] within seconds of happening, so shortening this
    /// buys almost no detection speed while tripling what the watchdog costs
    /// overnight.
    private static let baseInterval: TimeInterval = 180

    /// Cadence on a metered underlay or in Low Power Mode, where each round
    /// costs the user data or battery they have explicitly said they are short
    /// of.
    private static let meteredInterval: TimeInterval = 300

    /// Cadence between a failed check and the one that confirms it.
    ///
    /// This is what keeps the slow [baseInterval] from becoming slow *detection*.
    /// A tunnel needs [failuresBeforeRecovery] failures in a row before it is
    /// rebuilt, so with one interval for both "is it still fine?" and "was that
    /// blip real?" the two settings multiply: 20 s to the first verdict plus
    /// 180 s to the second is 200 s of a dead tunnel showing `connected` — worse
    /// than the 105 s the audit already called too slow. Asking again quickly
    /// costs one extra round only when something is actually wrong.
    private static let recheckInterval: TimeInterval = 20

    /// Slower cadence once repeated recoveries haven't helped, so a genuinely
    /// unreachable server can't turn into a battery drain.
    private static let backoffInterval: TimeInterval = 600
    private static let recoveriesBeforeBackoff = 4

    /// A freshly started tunnel needs a moment before its first verdict means
    /// anything — the first handshake may not have completed. One TLS handshake
    /// is enough to know, so this is short: together with [recheckInterval] and
    /// [failuresBeforeRecovery] it sets the floor on how long a tunnel that
    /// never worked keeps claiming it does — 20 s + 20 s, against the 105 s the
    /// audit measured.
    private static let firstCheckDelay: TimeInterval = 20

    /// Delay before an out-of-band check, long enough for whatever just changed
    /// (device wake, network switch) to settle.
    private static let expeditedCheckDelay: TimeInterval = 8

    /// One failed probe is a blip; two in a row is a broken tunnel.
    private static let failuresBeforeRecovery = 2

    /// Floor on how often the tunnel may be rebuilt. Recovery is disruptive
    /// enough that doing it back-to-back would be worse than the symptom.
    private static let minRecoveryInterval: TimeInterval = 90

    /// Outbound types that are not the server we want to test.
    private static let nonProxyOutboundTypes: Set<String> = [
        "direct", "block", "reject", "dns", "selector", "urltest", "compatible", "fallback",
    ]

    /// The only hosts this process will talk to over the control API. See
    /// [normalizeController].
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]

    /// The config the tunnel is running, read fresh each time so a reload with
    /// a different server is probed against the right control API.
    private let readConfigContent: () -> String?

    /// Whether the device has any network for the tunnel to ride on. See
    /// [runProbe] for why a probe without one proves nothing.
    private let hasUpstreamNetwork: () -> Bool

    /// Whether sing-box is paused (the device is asleep). A paused core answers
    /// nothing, and that is not the tunnel's fault.
    private let isCorePaused: () -> Bool

    /// Whether the underlay is metered — see [meteredInterval].
    private let isNetworkExpensive: () -> Bool
    private let recover: () -> Void
    private let log: (String) -> Void

    /// Every piece of state below is touched only on this queue, which is also
    /// where the timer fires — so none of it needs a lock.
    private let queue = DispatchQueue(label: "fatvpn.packet-tunnel.health")
    private var timer: DispatchSourceTimer?
    private var probeInFlight = false
    private var consecutiveFailures = 0

    /// The repeat interval the timer is currently armed with, so
    /// [applyInterval] can leave it alone when nothing has changed.
    private var scheduledInterval: TimeInterval = 0

    /// Bumped by every [checkSoon]; a scheduled expedited probe only runs if it
    /// is still the latest one.
    private var expeditedGeneration = 0

    /// Not reset when the tunnel is rebuilt: a recovery restarts the core, and
    /// forgetting here would let a server that is simply down be rebuilt every
    /// 90 seconds forever. Only a healthy probe clears it.
    private var recoveryAttempts = 0
    private var lastRecoveryAt: Date?

    /// Built eagerly rather than lazily: `get` is called both from [queue] and
    /// from URLSession's own completion thread, and a lazy property initialised
    /// from two threads is a data race.
    ///
    /// Cacheless and cookieless on purpose. `.ephemeral` still allocates an
    /// in-memory URL cache of several megabytes, inside a process whose whole
    /// budget is ~50 MB — and none of it could ever be reused, since every
    /// request here is a liveness probe that must not be answered from a cache.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TunnelHealthWatchdog.probeTimeout + 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    init(
        readConfigContent: @escaping () -> String?,
        hasUpstreamNetwork: @escaping () -> Bool,
        isCorePaused: @escaping () -> Bool,
        isNetworkExpensive: @escaping () -> Bool,
        recover: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        self.readConfigContent = readConfigContent
        self.hasUpstreamNetwork = hasUpstreamNetwork
        self.isCorePaused = isCorePaused
        self.isNetworkExpensive = isNetworkExpensive
        self.recover = recover
        self.log = log
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.consecutiveFailures = 0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            self.scheduledInterval = self.desiredInterval()
            timer.schedule(
                deadline: .now() + Self.firstCheckDelay,
                repeating: self.scheduledInterval
            )
            timer.setEventHandler { [weak self] in self?.runProbe() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Requests an out-of-band check shortly from now — used when the device
    /// wakes or the underlay changes, the moments a tunnel is most likely to
    /// have survived as an interface while quietly losing its path to the
    /// server.
    ///
    /// Debounced: path updates arrive in bursts (an AP re-association alone can
    /// produce several), and each one queueing its own probe would hammer the
    /// control API for no extra information. Only the last request in a burst
    /// runs — the periodic tick keeps its own cadence regardless.
    func checkSoon() {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.expeditedGeneration += 1
            let generation = self.expeditedGeneration
            self.queue.asyncAfter(deadline: .now() + Self.expeditedCheckDelay) { [weak self] in
                guard let self, self.timer != nil, self.expeditedGeneration == generation else {
                    return
                }
                self.runProbe()
            }
        }
    }

    /// Cumulative traffic counters from the core's control API, or nil when it
    /// can't be reached. The container app has no way to ask that API itself —
    /// it listens on the extension's loopback — so this is how the traffic the
    /// UI shows gets out of this process.
    ///
    /// `/connections` rather than `/traffic` despite carrying the whole
    /// connection list with it: `/traffic` is a *stream* (the core keeps the
    /// response open and pushes a per-second rate), so a plain request against
    /// it would hang until this session's timeout, and a rate is not what the
    /// UI shows anyway. `/connections` is the only endpoint with cumulative
    /// totals, and it is the one the Android probe already uses. The cost is
    /// bounded by the caller: the poll runs only while the app is in the
    /// foreground with the stats channel listening.
    func fetchTraffic(_ completion: @escaping (TunnelTraffic?) -> Void) {
        queue.async { [weak self] in
            guard let self, let controller = self.resolveController() else {
                completion(nil)
                return
            }
            self.get(
                "http://\(controller.address)/connections",
                secret: controller.secret,
                timeout: Self.controlAPITimeout
            ) { status, body in
                guard status == 200, let body,
                    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                else {
                    completion(nil)
                    return
                }
                completion(
                    TunnelTraffic(
                        uplinkBytes: (json["uploadTotal"] as? NSNumber)?.int64Value ?? 0,
                        downlinkBytes: (json["downloadTotal"] as? NSNumber)?.int64Value ?? 0))
            }
        }
    }

    // MARK: - Probing

    private func runProbe() {
        guard !probeInFlight else { return }
        // A phone in a lift or on a plane has nothing for the tunnel to carry.
        // Blaming the tunnel for that — and rebuilding it — would be wrong, and
        // the failures counted meanwhile would make the first real check after
        // reconnecting fire a recovery it hadn't earned.
        guard hasUpstreamNetwork() else {
            consecutiveFailures = 0
            return
        }
        // Same reasoning for a core the system asked us to pause: it is not
        // answering because it was told not to. Counting those rounds used to
        // turn an ordinary screen-off into a full rebuild of the core on the
        // next two ticks.
        guard !isCorePaused() else {
            consecutiveFailures = 0
            return
        }
        guard let controller = resolveController() else { return }
        probeInFlight = true
        activeOutboundTag(controller) { [weak self] tag in
            guard let self else { return }
            guard let tag else {
                // The control API itself didn't answer — nothing is established
                // about the outbound either way.
                self.finish(.unknown)
                return
            }
            self.delayTest(controller, tag, Self.probeURLs) { reachable in
                self.finish(reachable ? .healthy : .dead)
            }
        }
    }

    private func finish(_ verdict: TunnelHealthVerdict) {
        queue.async { [weak self] in
            guard let self else { return }
            self.probeInFlight = false
            guard self.timer != nil else { return }
            switch verdict {
            case .healthy:
                if self.consecutiveFailures > 0 || self.recoveryAttempts > 0 {
                    self.log("(packet-tunnel) tunnel health restored")
                }
                self.consecutiveFailures = 0
                // A tunnel that works again has earned the normal cadence back;
                // without this the widened interval would outlive the trouble
                // that caused it, for the rest of the session.
                self.recoveryAttempts = 0
            case .unknown:
                // Leave the counters alone: an inconclusive round neither
                // accuses the tunnel nor absolves it.
                break
            case .dead:
                self.consecutiveFailures += 1
                self.log(
                    "(packet-tunnel) tunnel is up but passes no traffic "
                        + "(\(self.consecutiveFailures) in a row)")
                if self.consecutiveFailures >= Self.failuresBeforeRecovery {
                    self.attemptRecovery()
                }
            }
            self.applyInterval()
        }
    }

    private func attemptRecovery() {
        let now = Date()
        if let last = lastRecoveryAt, now.timeIntervalSince(last) < Self.minRecoveryInterval {
            return
        }
        lastRecoveryAt = now
        recoveryAttempts += 1
        consecutiveFailures = 0
        log("(packet-tunnel) rebuilding sing-box to recover the tunnel (attempt \(recoveryAttempts))")
        recover()
    }

    /// The cadence this tunnel currently deserves: tightened the moment a check
    /// fails, stretched while repeated recoveries are not helping, and stretched
    /// again on a network the user pays for by the megabyte or a device that has
    /// asked to be left alone.
    private func desiredInterval() -> TimeInterval {
        if recoveryAttempts >= Self.recoveriesBeforeBackoff {
            return Self.backoffInterval
        }
        // A failure in hand outranks both of the economies below: the tunnel is
        // already suspected, and the only thing standing between the user and a
        // repair is the confirming check.
        if consecutiveFailures > 0 {
            return Self.recheckInterval
        }
        if isNetworkExpensive() || ProcessInfo.processInfo.isLowPowerModeEnabled {
            return Self.meteredInterval
        }
        return Self.baseInterval
    }

    /// Re-arms the timer when the deserved cadence has changed, and only then —
    /// rescheduling on every round would push the next tick a full interval out
    /// each time and starve the periodic check entirely.
    private func applyInterval() {
        let interval = desiredInterval()
        guard interval != scheduledInterval, let timer else { return }
        scheduledInterval = interval
        timer.schedule(deadline: .now() + interval, repeating: interval)
    }

    /// Tag of the proxy outbound currently in use, read back from the core
    /// rather than assumed: the tag is the config link's own fragment, which
    /// need not match anything the app knows the node by.
    private func activeOutboundTag(_ controller: ControlAPI, _ completion: @escaping (String?) -> Void) {
        get("http://\(controller.address)/proxies", secret: controller.secret, timeout: Self.controlAPITimeout) {
            status, body in
            guard status == 200, let body,
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let proxies = json["proxies"] as? [String: Any]
            else {
                completion(nil)
                return
            }
            // Spelled out rather than `Self.`: this closure deliberately does
            // not capture self, and a bare `Self` there would drag it back in.
            let excluded = TunnelHealthWatchdog.nonProxyOutboundTypes
            let tag = proxies.first { _, value in
                guard let entry = value as? [String: Any],
                    let type = (entry["type"] as? String)?.lowercased(), !type.isEmpty
                else { return false }
                return !excluded.contains(type)
            }?.key
            completion(tag)
        }
    }

    /// Walks [remaining] probe URLs, answering true as soon as one gets through
    /// the outbound and false only once every one of them has failed.
    private func delayTest(
        _ controller: ControlAPI,
        _ tag: String,
        _ remaining: [String],
        _ completion: @escaping (Bool) -> Void
    ) {
        guard let probeURL = remaining.first else {
            completion(false)
            return
        }
        let allowed = CharacterSet.alphanumerics
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: allowed) ?? tag
        let encodedURL = probeURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? probeURL
        let url =
            "http://\(controller.address)/proxies/\(encodedTag)/delay"
            + "?url=\(encodedURL)&timeout=\(Int(Self.probeTimeout * 1000))"
        // A dead outbound makes this request hang rather than fail: sing-box
        // accepts the connection and then never answers, ignoring the `timeout`
        // parameter. The session's own timeout is therefore the verdict, so it
        // has to outlast the one we asked for.
        get(url, secret: controller.secret, timeout: Self.probeTimeout + 4) { [weak self] status, _ in
            guard let self else { return }
            if status == 200 {
                completion(true)
                return
            }
            self.delayTest(controller, tag, Array(remaining.dropFirst()), completion)
        }
    }

    /// Plain GET against the loopback control API. `nil` status means the
    /// request couldn't be carried out at all.
    private func get(
        _ url: String, secret: String?, timeout: TimeInterval,
        _ completion: @escaping (Int?, Data?) -> Void
    ) {
        guard let requestURL = URL(string: url) else {
            completion(nil, nil)
            return
        }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout
        if let secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: request) { data, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode, data)
        }.resume()
    }

    // MARK: - Control API address

    /// Where the core's control API listens and the bearer token it demands.
    /// The secret is nil only for a config written before it became mandatory.
    private struct ControlAPI {
        let address: String
        let secret: String?
    }

    /// The control API of the running config, or nil when the config doesn't
    /// enable one, or names an address this process refuses to dial.
    private func resolveController() -> ControlAPI? {
        guard let content = readConfigContent(), let data = content.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let experimental = json["experimental"] as? [String: Any],
            let clashAPI = experimental["clash_api"] as? [String: Any],
            let external = clashAPI["external_controller"] as? String, !external.isEmpty
        else {
            return nil
        }
        guard let address = Self.normalizeController(external) else {
            log("(packet-tunnel) refusing non-loopback control API: \(external)")
            return nil
        }
        let secret = (clashAPI["secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ControlAPI(address: address, secret: secret)
    }

    /// Turns a listen address into one we can dial, or nil when it isn't ours to
    /// dial at all.
    ///
    /// A core listening on a wildcard is reachable on loopback, the only
    /// interface this probe may use. Anything else is refused outright: the
    /// address comes out of a config assembled from a subscription link and
    /// overridable through `rawConfigPatch`, so `attacker.example:80` would have
    /// this network extension beaconing out every few minutes — from inside the
    /// tunnel process, carrying the active outbound's tag — and would have
    /// sing-box publish control of the core onto the local network besides.
    private static func normalizeController(_ external: String) -> String? {
        guard let separator = external.lastIndex(of: ":") else { return nil }
        let port = String(external[external.index(after: separator)...])
        guard Int(port) != nil else { return nil }
        let host = String(external[..<separator])
        switch host {
        case "", "0.0.0.0", "::", "[::]", "*":
            return "127.0.0.1:\(port)"
        default:
            let normalized = host.lowercased()
            guard loopbackHosts.contains(normalized) else { return nil }
            // A bare IPv6 literal has to be bracketed before it can go into a
            // URL. Unbracketed, `http://::1:16756/proxies` is not a URL at all:
            // `URL(string:)` returns nil, every probe answers "unknown", and the
            // watchdog stops recovering anything — silently, because the only
            // log line on this path is the one for a refused host.
            if normalized == "::1" {
                return "[::1]:\(port)"
            }
            return "\(host):\(port)"
        }
    }
}
