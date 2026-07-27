import Foundation
import Libbox
import Network
import NetworkExtension

// Shared with Runner via the App Group entitlement (PacketTunnel.entitlements) —
// the extension itself owns this container; Runner does not need App Group
// access since it only ever passes configContent through
// NETunnelProviderSession start options (see docs/ios-vpn-tunnel-spec.md
// Фаза 4 for the app-side NETunnelProviderManager wiring).
private let appGroupID = "group.com.fatvpn.fatvpnApp"
private let startOptionsFileName = "start_options.plist"

struct TunnelStartupError: LocalizedError, CustomNSError {
    let message: String
    init(message: String) { self.message = message }
    var errorDescription: String? { message }
    static var errorDomain: String { "PacketTunnelProvider" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
}

enum StartOptionsCodec {
    static func encode(_ options: [String: NSObject]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: options, format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> [String: NSObject] {
        guard let options = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: NSObject] else {
            throw TunnelStartupError(message: "Invalid start options payload")
        }
        return options
    }
}

/// Bridges a completion-handler-based async call into a synchronous return,
/// for the handful of spots where sing-box's Go runtime calls into Swift
/// synchronously (e.g. LibboxPlatformInterfaceProtocol.openTun) but the
/// underlying NetworkExtension API (targeting iOS 13) is completion-handler
/// based rather than `async`.
func runBlocking<T>(_ body: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error>!
    body { result in
        outcome = result
        semaphore.signal()
    }
    semaphore.wait()
    return try outcome.get()
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    private var tunnelOptions: [String: NSObject]?
    private var startOptionsURL: URL?

    /// Rebuilds sing-box when the tunnel stops carrying traffic without ever
    /// leaving `.connected` — the failure the user can otherwise only clear by
    /// toggling the VPN by hand. See [TunnelHealthWatchdog] for why it lives in
    /// this process rather than in the app.
    ///
    /// Repairs go through `reloadService`, which is `startOrReloadService` — the
    /// very call `startTunnel` uses, on the very config content it was given, so
    /// a recovery rebuilds exactly the tunnel that was started. (Tearing the
    /// whole extension down and back up, the app-side equivalent, isn't an
    /// option from in here: `cancelTunnelWithError` would leave the user with no
    /// VPN at all, which is worse than the symptom being repaired.)
    private lazy var healthWatchdog = TunnelHealthWatchdog(
        readConfigContent: { [weak self] in self?.tunnelOptions?["configContent"] as? String },
        hasUpstreamNetwork: { [weak self] in self?.platformInterface.hasUsableUpstream ?? true },
        recover: { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.reloadService()
                } catch {
                    Self.writeDiagnostics("HEALTH RECOVERY FAILED: \(error.localizedDescription)")
                }
            }
        },
        log: { [weak self] message in self?.writeMessage(message) }
    )

    private static var sharedDirectory: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            // App Group misconfiguration is a build/provisioning bug, not a
            // runtime condition callers can recover from.
            fatalError("App Group container unavailable: \(appGroupID)")
        }
        return url
    }

    private static let workingDirectory = sharedDirectory.appendingPathComponent("Working", isDirectory: true)
    private static let cacheDirectory = sharedDirectory.appendingPathComponent("Caches", isDirectory: true)

    override func startTunnel(options startOptions: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                try await startTunnel0(options: startOptions)
                Self.writeDiagnostics("OK: tunnel started")
                completionHandler(nil)
            } catch {
                // The container app can't see this process's logs, so persist the
                // failure reason (plus the tail of sing-box's stderr) into the App
                // Group container. The app reads it back via getLastError and folds
                // it into the shareable support bundle (see docs/ios-vpn-tunnel-spec.md
                // Фаза 4 diagnostics).
                Self.writeDiagnostics("START FAILED: \(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    /// Persists a one-line status plus the tail of sing-box's redirected stderr
    /// to `diagnostics.txt` in the shared App Group container, so the container
    /// app (which shares the group) can surface it. Best-effort: silently no-ops
    /// if the container is unavailable.
    static func writeDiagnostics(_ message: String) {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        var text = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let stderrURL = base.appendingPathComponent("Caches/stderr.log")
        if let data = try? Data(contentsOf: stderrURL),
            let tail = String(data: data.suffix(6000), encoding: .utf8), !tail.isEmpty
        {
            text += "\n--- sing-box stderr (tail) ---\n" + tail + "\n"
        }
        try? text.write(to: base.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
    }

    private func startTunnel0(options startOptions: [String: NSObject]?) async throws {
        try? FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        startOptionsURL = Self.sharedDirectory.appendingPathComponent(startOptionsFileName)

        let effectiveOptions = try resolveStartOptions(startOptions)
        guard let configContent = effectiveOptions["configContent"] as? String, !configContent.isEmpty else {
            throw TunnelStartupError(message: "Missing configContent in tunnel start options")
        }
        try? persistStartOptions(effectiveOptions)
        tunnelOptions = effectiveOptions

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = Self.sharedDirectory.path
        setupOptions.workingPath = Self.workingDirectory.path
        setupOptions.tempPath = Self.cacheDirectory.path
        setupOptions.logMaxLines = 3000

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError {
            throw TunnelStartupError(message: "Libbox setup failed: \(setupError.localizedDescription)")
        }

        var stderrError: NSError?
        LibboxRedirectStderr(Self.cacheDirectory.appendingPathComponent("stderr.log").path, &stderrError)
        LibboxSetMemoryLimit(true)

        var serverError: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &serverError)
        if let serverError {
            throw TunnelStartupError(message: "Failed to create command server: \(serverError.localizedDescription)")
        }
        do {
            try commandServer!.start()
        } catch {
            throw TunnelStartupError(message: "Failed to start command server: \(error.localizedDescription)")
        }

        // Before sing-box, not after: the config it is about to load names the
        // SOCKS server this core provides, and sing-box dials it as soon as the
        // first packet arrives.
        try startXrayIfNeeded(effectiveOptions["xrayConfigContent"] as? String)

        writeMessage("(packet-tunnel) starting sing-box")
        try await startService(configContent: configContent)
        // Only now is there a tunnel worth watching.
        healthWatchdog.start()
    }

    /// Brings the bundled Xray core up for nodes on a transport sing-box has no
    /// implementation for, or makes sure it is down for every other node.
    ///
    /// Nothing here protects the core's sockets, and nothing needs to: a packet
    /// tunnel provider's own traffic already bypasses the tunnel it provides.
    /// On Android that exclusion has to be arranged by hand, with
    /// `VpnService.protect` on every socket the core opens.
    private func startXrayIfNeeded(_ xrayConfigContent: String?) throws {
        guard let xrayConfigContent, !xrayConfigContent.isEmpty else {
            stopXray()
            return
        }
        // This process is reused across reconnects, so a core from the previous
        // session may still be up; starting on top of it is refused by the core.
        stopXray()
        // gomobile binds a package-level Go function returning `error` as a C
        // function with an NSError out-parameter — not as a throwing method, so
        // there is nothing here for `try` to catch. Same shape as
        // LibboxNewCommandServer above.
        var startError: NSError?
        if !FatxrayStart(xrayConfigContent, &startError) {
            throw TunnelStartupError(
                message: "Failed to start Xray core: "
                    + (startError?.localizedDescription ?? "unknown error"))
        }
        writeMessage("(packet-tunnel) Xray core started (\(FatxrayVersion()))")
    }

    private func stopXray() {
        // Runs on every start and on teardown, so "it was not running" is the
        // normal case rather than a failure worth reporting — the error
        // out-parameter is deliberately dropped.
        _ = FatxrayStop(nil)
    }

    private func startService(configContent: String) async throws {
        let overrideOptions = LibboxOverrideOptions()
        do {
            try commandServer?.startOrReloadService(configContent, options: overrideOptions)
        } catch {
            throw TunnelStartupError(message: "Failed to start sing-box service: \(error.localizedDescription)")
        }
    }

    private func persistStartOptions(_ options: [String: NSObject]) throws {
        guard let startOptionsURL else { return }
        try StartOptionsCodec.encode(options).write(to: startOptionsURL, options: .atomic)
    }

    private func loadPersistedStartOptions() throws -> [String: NSObject]? {
        guard let startOptionsURL, FileManager.default.fileExists(atPath: startOptionsURL.path) else {
            return nil
        }
        return try StartOptionsCodec.decode(Data(contentsOf: startOptionsURL))
    }

    private func resolveStartOptions(_ startOptions: [String: NSObject]?) throws -> [String: NSObject] {
        if let startOptions, startOptions["configContent"] is String {
            return startOptions
        }
        if let persisted = try loadPersistedStartOptions() {
            guard let startOptions else { return persisted }
            return persisted.merging(startOptions) { _, new in new }
        }
        throw TunnelStartupError(message: "Missing start options: no configContent provided and no persisted snapshot found")
    }

    func writeMessage(_ message: String) {
        commandServer?.writeMessage(2, message: message)
    }

    func stopService() {
        try? commandServer?.closeService()
        platformInterface.reset()
    }

    func reloadService() async throws {
        guard let configContent = tunnelOptions?["configContent"] as? String else {
            throw TunnelStartupError(message: "Missing configContent for reload")
        }
        reasserting = true
        defer { reasserting = false }
        // A reload is also how the health watchdog recovers a stalled tunnel,
        // and a node carried by Xray is only as alive as that core — so bring
        // it back if it is gone rather than reloading sing-box onto a dead
        // SOCKS port.
        if let xrayConfigContent = tunnelOptions?["xrayConfigContent"] as? String,
            !FatxrayIsRunning()
        {
            try startXrayIfNeeded(xrayConfigContent)
        }
        try await startService(configContent: configContent)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        healthWatchdog.stop()
        stopService()
        commandServer?.close()
        commandServer = nil
        // After sing-box, mirroring the start order: while sing-box winds down
        // it can still push traffic at the SOCKS port.
        stopXray()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Two message shapes share this channel. A JSON envelope carrying a
        // "command" is a request for this process to *do* something on the
        // app's behalf; anything else is the original payload — a start-options
        // plist meaning "reload the service with this config".
        if let envelope = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
            let command = envelope["command"] as? String
        {
            handleCommand(command, envelope, completionHandler: completionHandler)
            return
        }
        Task {
            do {
                let options = try StartOptionsCodec.decode(messageData)
                tunnelOptions = options
                try? persistStartOptions(options)
                try await reloadService()
                // A different server (or different settings) is a different
                // tunnel: give the watchdog a fresh settle window rather than
                // letting the old one's schedule judge this one.
                healthWatchdog.restart()
                completionHandler?(nil)
            } catch {
                completionHandler?(error.localizedDescription.data(using: .utf8))
            }
        }
    }

    private func handleCommand(
        _ command: String,
        _ envelope: [String: Any],
        completionHandler: ((Data?) -> Void)?
    ) {
        switch command {
        case "measureLatency":
            measureLatency(envelope, completionHandler: completionHandler)
        default:
            completionHandler?(Self.encode(["ok": false, "error": "Unknown command: \(command)"]))
        }
    }

    /// Times a TCP handshake to a host **from this process**, which is the whole
    /// reason the container app asks us to do it.
    ///
    /// The app's own sockets are carried by the tunnel this extension provides,
    /// so when it measures a candidate server the number it gets is really
    /// "device → current server → candidate": every alternative is inflated by
    /// the live tunnel's round-trip, and the moment that tunnel stops passing
    /// traffic every measurement fails at once — precisely when the app is
    /// trying to find a server to escape to. This process is not subject to
    /// that: a packet tunnel provider's own traffic bypasses the tunnel it
    /// provides (which is how sing-box reaches the VPN server in the first
    /// place), so a connect from here travels the real underlay.
    ///
    /// Answers on the same JSON shape the in-app ping returns, so the Dart side
    /// parses one format regardless of who measured.
    private func measureLatency(_ envelope: [String: Any], completionHandler: ((Data?) -> Void)?) {
        guard let host = envelope["host"] as? String, !host.isEmpty,
            let port = envelope["port"] as? Int, port > 0, port <= 65535,
            let nwPort = Network.NWEndpoint.Port(rawValue: UInt16(port))
        else {
            completionHandler?(Self.encode(["ok": false, "error": "Invalid host or port"]))
            return
        }
        let timeoutMs = max((envelope["timeoutMs"] as? Int) ?? 3000, 1)

        Self.tcpLatencyMs(host: host, port: nwPort, timeoutMs: timeoutMs) { latencyMs, error in
            guard let latencyMs else {
                completionHandler?(Self.encode(["ok": false, "error": error ?? "Ping failed"]))
                return
            }
            completionHandler?(Self.encode(["ok": true, "latencyMs": latencyMs]))
        }
    }

    /// Round-trip of a TCP connect to [host]:[port], or nil with a reason.
    ///
    /// Everything runs on one serial queue — NWConnection delivers its state
    /// updates there and the timeout is scheduled on it — so `settled` needs no
    /// lock, and the completion fires exactly once no matter which of "ready",
    /// "failed" and "timed out" arrives first.
    private static func tcpLatencyMs(
        host: String,
        // `Network.` qualified throughout: NetworkExtension exports its own
        // (deprecated) NWEndpoint class, so the bare name is ambiguous here.
        port: Network.NWEndpoint.Port,
        timeoutMs: Int,
        completion: @escaping (Int?, String?) -> Void
    ) {
        let queue = DispatchQueue(label: "fatvpn.packet-tunnel.latency")
        // This process's traffic already bypasses the tunnel it provides — that
        // is how sing-box reaches the VPN server at all. Prohibiting the
        // tunnel interface type states that requirement outright instead of
        // resting on it: if the assumption were ever wrong the measurement
        // would be a fiction, and a fiction is worse than a failure here.
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.other]
        let connection = NWConnection(
            host: Network.NWEndpoint.Host(host), port: port, using: parameters)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var settled = false

        func settle(_ latencyMs: Int?, _ error: String?) {
            guard !settled else { return }
            settled = true
            connection.cancel()
            completion(latencyMs, error)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                settle(Int(elapsed / 1_000_000), nil)
            case .failed(let error):
                settle(nil, error.localizedDescription)
            case .cancelled:
                settle(nil, "Ping cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
            settle(nil, "Ping timed out")
        }
    }

    private static func encode(_ payload: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: payload)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        commandServer?.pause()
        completionHandler()
    }

    /// The underlay this tunnel rides on changed — reported by
    /// [ExtensionPlatformInterface]'s path monitor, which sees it first.
    func underlayDidChange() {
        healthWatchdog.checkSoon()
    }

    override func wake() {
        commandServer?.wake()
        // Coming out of device sleep is a prime moment for a tunnel to still be
        // an interface while no longer having a path to the server.
        healthWatchdog.checkSoon()
    }
}
