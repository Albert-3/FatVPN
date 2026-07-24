import Foundation
import Libbox
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

        writeMessage("(packet-tunnel) starting sing-box")
        try await startService(configContent: configContent)
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
        try await startService(configContent: configContent)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        stopService()
        commandServer?.close()
        commandServer = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        Task {
            do {
                let options = try StartOptionsCodec.decode(messageData)
                tunnelOptions = options
                try? persistStartOptions(options)
                try await reloadService()
                completionHandler?(nil)
            } catch {
                completionHandler?(error.localizedDescription.data(using: .utf8))
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        commandServer?.pause()
        completionHandler()
    }

    override func wake() {
        commandServer?.wake()
    }
}
