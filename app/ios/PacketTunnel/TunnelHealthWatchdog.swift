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

    /// How often a live tunnel is asked whether it still works.
    private static let checkInterval: TimeInterval = 60

    /// Slower cadence once repeated recoveries haven't helped, so a genuinely
    /// unreachable server can't turn into a battery drain.
    private static let backoffInterval: TimeInterval = 300
    private static let recoveriesBeforeBackoff = 4

    /// A freshly started tunnel needs a moment before its first verdict means
    /// anything — the first handshake may not have completed.
    private static let firstCheckDelay: TimeInterval = 45

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

    /// The config the tunnel is running, read fresh each time so a reload with
    /// a different server is probed against the right control API.
    private let readConfigContent: () -> String?

    /// Whether the device has any network for the tunnel to ride on. See
    /// [runProbe] for why a probe without one proves nothing.
    private let hasUpstreamNetwork: () -> Bool
    private let recover: () -> Void
    private let log: (String) -> Void

    /// Every piece of state below is touched only on this queue, which is also
    /// where the timer fires — so none of it needs a lock.
    private let queue = DispatchQueue(label: "fatvpn.packet-tunnel.health")
    private var timer: DispatchSourceTimer?
    private var probeInFlight = false
    private var consecutiveFailures = 0

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
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TunnelHealthWatchdog.probeTimeout + 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(
        readConfigContent: @escaping () -> String?,
        hasUpstreamNetwork: @escaping () -> Bool,
        recover: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        self.readConfigContent = readConfigContent
        self.hasUpstreamNetwork = hasUpstreamNetwork
        self.recover = recover
        self.log = log
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.consecutiveFailures = 0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + Self.firstCheckDelay,
                repeating: Self.checkInterval
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

    /// Re-arms the watchdog for a tunnel that has just been rebuilt with a
    /// different config, so the new core gets its own settle window before its
    /// first verdict counts. The escalation counters survive on purpose (see
    /// [recoveryAttempts]).
    func restart() {
        stop()
        start()
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
                let wasBackingOff = self.recoveryAttempts >= Self.recoveriesBeforeBackoff
                self.recoveryAttempts = 0
                // A tunnel that works again has earned the normal cadence back;
                // without this the widened interval would outlive the trouble
                // that caused it, for the rest of the session.
                if wasBackingOff {
                    self.timer?.schedule(
                        deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
                }
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
        // Recovery churns the core; stretch the cadence once repeated attempts
        // have failed so a dead server can't be retried every minute forever.
        if recoveryAttempts == Self.recoveriesBeforeBackoff {
            timer?.schedule(deadline: .now() + Self.backoffInterval, repeating: Self.backoffInterval)
        }
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
    /// enable one (nothing can be probed then).
    private func resolveController() -> ControlAPI? {
        guard let content = readConfigContent(), let data = content.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let experimental = json["experimental"] as? [String: Any],
            let clashAPI = experimental["clash_api"] as? [String: Any],
            let external = clashAPI["external_controller"] as? String, !external.isEmpty
        else {
            return nil
        }
        let secret = (clashAPI["secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ControlAPI(address: Self.normalizeController(external), secret: secret)
    }

    /// Turns a listen address into one we can dial. A core listening on a
    /// wildcard is reachable on loopback, the only interface this probe may use.
    private static func normalizeController(_ external: String) -> String {
        guard let separator = external.lastIndex(of: ":") else { return external }
        let port = String(external[external.index(after: separator)...])
        guard Int(port) != nil else { return external }
        let host = String(external[..<separator])
        switch host {
        case "", "0.0.0.0", "::", "[::]", "*":
            return "127.0.0.1:\(port)"
        default:
            return "\(host):\(port)"
        }
    }
}
