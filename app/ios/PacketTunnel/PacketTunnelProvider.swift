import Foundation
import Libbox
import Network
import NetworkExtension

// Shared with Runner via the App Group entitlement — the extension owns this
// container, and the container app (which carries the same entitlement, see
// Runner/Runner.entitlements) reads the diagnostics back out of it and clears
// the persisted artifacts on logout. See docs/ios-vpn-tunnel-spec.md Фаза 4
// for the app-side NETunnelProviderManager wiring.
private let appGroupID = "group.com.fatvpn.fatvpnApp"
private let startOptionsFileName = "start_options.plist"
private let diagnosticsFileName = "diagnostics.txt"

// Stamped into the persisted start-options snapshot so a stale one can be
// recognised and refused rather than silently reconnecting a logged-out user to
// last month's server. See PacketTunnelProvider.resolveStartOptions.
private let snapshotVersionKey = "fatvpnSnapshotVersion"
private let snapshotSavedAtKey = "fatvpnSnapshotSavedAt"
private let snapshotVersion = 1
private let snapshotMaxAge: TimeInterval = 7 * 24 * 60 * 60

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

/// Holds the result of an asynchronous call for the thread that is blocked
/// waiting on it. Separate from `runBlocking`'s local state because the two
/// sides genuinely run on different threads: without the lock, a callback that
/// arrives *after* the wait timed out writes the variable the waiter is reading.
private final class ResultBox<T> {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Calls a completion handler exactly once, whichever of the racing paths
/// (success, failure, startup deadline) reaches it first. Handing
/// NEPacketTunnelProvider's completionHandler two answers is undefined.
private final class OnceCompletion {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    /// True when this call was the one that answered.
    @discardableResult
    func call(_ error: Error?) -> Bool {
        lock.lock()
        let pending = handler
        handler = nil
        lock.unlock()
        guard let pending else { return false }
        pending(error)
        return true
    }
}

/// Bridges a completion-handler-based async call into a synchronous return,
/// for the handful of spots where sing-box's Go runtime calls into Swift
/// synchronously (e.g. LibboxPlatformInterfaceProtocol.openTun) but the
/// underlying NetworkExtension API (targeting iOS 13) is completion-handler
/// based rather than `async`.
///
/// Bounded on purpose. `openTun` runs on a Go thread, so a
/// `setTunnelNetworkSettings` whose callback never arrives — a conflicting NE
/// profile, a revoked one, a race with `clearDNSCache` — used to block that
/// thread forever: `startTunnel`'s completion handler was then never called and
/// the framework killed the extension on its own deadline, with the user
/// watching "Connecting" the whole time. A timeout turns that into an ordinary
/// error the caller can report.
func runBlocking<T>(
    timeout: TimeInterval = 15,
    _ body: (@escaping (Result<T, Error>) -> Void) -> Void
) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    body { result in
        box.set(result)
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        throw TunnelStartupError(
            message: "Timed out after \(Int(timeout))s waiting for the system to answer")
    }
    guard let outcome = box.get() else {
        throw TunnelStartupError(message: "Completed without a result")
    }
    return try outcome.get()
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)

    /// Guards every piece of cross-thread state below. `tunnelOptions` alone is
    /// written from `startTunnel0` and `handleAppMessage` (two different Tasks)
    /// and read from the watchdog's queue and from `serviceReload()` on a Go
    /// thread — a Swift dictionary torn between those is memory corruption, and
    /// a crashed extension is a VPN that silently stops existing.
    private let stateQueue = DispatchQueue(label: "fatvpn.packet-tunnel.state")
    private var _tunnelOptions: [String: NSObject]?
    private var _corePaused = false

    private var tunnelOptions: [String: NSObject]? {
        get { stateQueue.sync { _tunnelOptions } }
        set { stateQueue.sync { _tunnelOptions = newValue } }
    }

    /// True between `sleep()` and `wake()`. sing-box is paused then, so a probe
    /// through it proves nothing — see [TunnelHealthWatchdog].
    private var corePaused: Bool {
        get { stateQueue.sync { _corePaused } }
        set { stateQueue.sync { _corePaused = newValue } }
    }

    /// Whether the session asked for the kill switch. Read back by
    /// [ExtensionPlatformInterface.includeAllNetworks].
    var includeAllNetworksRequested: Bool {
        (tunnelOptions?["includeAllNetworks"] as? NSNumber)?.boolValue ?? false
    }

    /// How long the whole of `startTunnel` may take before we answer the
    /// framework ourselves. Anything past this is a hang, not a slow server, and
    /// an explicit error at least leaves the user a retriable state instead of
    /// an extension killed with no reason recorded.
    private static let startupDeadline: TimeInterval = 40

    /// Bytes of sing-box stderr folded into a diagnostics report, and the size
    /// past which the log is discarded at startup. The file has no rotation of
    /// its own, and it is read on the error path — inside a process with a
    /// ~50 MB jetsam limit — so an unbounded read would kill the extension
    /// exactly when it is trying to record why it could not start.
    private static let stderrTailBytes = 6000
    private static let stderrMaxBytes: UInt64 = 256 * 1024

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
        isCorePaused: { [weak self] in self?.corePaused ?? false },
        isNetworkExpensive: { [weak self] in self?.platformInterface.isUpstreamExpensive ?? false },
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

    /// Where this process keeps its working state.
    ///
    /// The App Group container when it is reachable, a private temporary
    /// directory when it is not. A missing container used to be a `fatalError`
    /// on the grounds that it can only be a build-time mistake, but provisioning
    /// drift, a re-issued profile and a damaged container all produce it at
    /// runtime — and a crashing network extension is the worst possible outcome:
    /// iOS backs off exponentially on extensions that crash and eventually stops
    /// launching them at all, so the user is left with a VPN that never comes up
    /// and no diagnostics anywhere (the writer of those lives in the same
    /// container). Degrading instead means the tunnel still works; only the
    /// app's view of its diagnostics is lost.
    /// Resolved once, and the flag is resolved *with* it deliberately.
    ///
    /// Asking the container question a second time, later, can answer "yes"
    /// while every file this process wrote went to the temporary fallback —
    /// `sharedDirectory` is a `let` and never moves back. The diagnostics would
    /// then omit the APP_GROUP_UNAVAILABLE marker while the app looked for
    /// those files in the App Group and found nothing: the silent-loss case
    /// that removing `fatalError` from here was supposed to make loud.
    private static let sharedContainer: (url: URL, isAppGroup: Bool) = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return (url, true)
        }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("fatvpn-no-app-group", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return (fallback, false)
    }()

    private static var sharedDirectory: URL { sharedContainer.url }

    private static var appGroupAvailable: Bool { sharedContainer.isAppGroup }

    private static let workingDirectory = sharedDirectory.appendingPathComponent("Working", isDirectory: true)
    private static let cacheDirectory = sharedDirectory.appendingPathComponent("Caches", isDirectory: true)
    private static var startOptionsURL: URL {
        sharedDirectory.appendingPathComponent(startOptionsFileName)
    }

    override func startTunnel(options startOptions: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let answer = OnceCompletion(completionHandler)
        // A start that never finishes is indistinguishable, from out here, from
        // one that is merely slow — but the framework's own deadline expires
        // either way and takes the extension with it. Answering ourselves keeps
        // the reason recorded.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.startupDeadline) {
            let error = TunnelStartupError(
                message: "Tunnel start timed out after \(Int(Self.startupDeadline))s")
            if answer.call(error) {
                Self.writeDiagnostics("START FAILED: \(error.message)")
            }
        }
        Task {
            do {
                try await startTunnel0(options: startOptions)
                if answer.call(nil) {
                    Self.writeDiagnostics("OK: tunnel started")
                }
                // The app is very often not running when this happens — iOS
                // starts this extension on demand — so the home-screen widget
                // would otherwise keep showing "disconnected" over a live
                // tunnel until the user opened the app.
                FatVpnWidgetSnapshot.patchTunnelState("connected", connectedAt: Date())
            } catch {
                // The container app can't see this process's logs, so persist the
                // failure reason (plus the tail of sing-box's stderr) into the App
                // Group container. The app reads it back via getLastError and folds
                // it into the shareable support bundle (see docs/ios-vpn-tunnel-spec.md
                // Фаза 4 diagnostics).
                if answer.call(error) {
                    Self.writeDiagnostics("START FAILED: \(error.localizedDescription)")
                }
                FatVpnWidgetSnapshot.patchTunnelState("disconnected", connectedAt: nil)
            }
        }
    }

    /// Persists a one-line status plus the tail of sing-box's redirected stderr
    /// to `diagnostics.txt` in the shared App Group container, so the container
    /// app (which shares the group) can surface it.
    ///
    /// Written with file protection and kept out of device backups, and run
    /// through [redactSecrets] first: sing-box quotes the outbound it was
    /// dialling when a config fails to load, and this text reaches the user's
    /// screen and their shareable support bundle.
    static func writeDiagnostics(_ message: String) {
        var text = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if !appGroupAvailable {
            text += "APP_GROUP_UNAVAILABLE: \(appGroupID) (diagnostics are local to this process)\n"
        }
        if let tail = tailOfFile(at: cacheDirectory.appendingPathComponent("stderr.log"),
                                 maxBytes: stderrTailBytes),
            !tail.isEmpty
        {
            text += "\n--- sing-box stderr (tail) ---\n" + tail + "\n"
        }
        guard let data = redactSecrets(text).data(using: .utf8) else { return }
        let url = sharedDirectory.appendingPathComponent(diagnosticsFileName)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        harden(url)
    }

    /// Last [maxBytes] of a file, without reading the rest of it into memory.
    ///
    /// `Data(contentsOf:)` used to be used here, which loads the whole file —
    /// on the error path, in a process capped at ~50 MB, against a log that
    /// grows for the lifetime of the install. The more often the tunnel failed,
    /// the larger the log, and the more certain the diagnostics write was to be
    /// jetsam-killed instead of recording anything.
    static func tailOfFile(at url: URL, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        let wanted = UInt64(max(maxBytes, 0))
        handle.seek(toFileOffset: size > wanted ? size - wanted : 0)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Marks a file as protected-at-rest and keeps it out of iCloud/Finder
    /// backups. Everything this process persists — the start-options snapshot,
    /// the diagnostics report, sing-box's stderr — quotes node addresses and
    /// subscription credentials, and a backup is the one place they leave the
    /// device in the clear.
    static func harden(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    /// Replaces credentials and endpoints in free-form diagnostic text.
    ///
    /// Deliberately blunt, and mirrored on the Dart side (app/lib/utils/
    /// sanitize.dart): over-redacting costs a support engineer some context,
    /// under-redacting hands whoever reads a shared log a working copy of the
    /// user's subscription.
    static func redactSecrets(_ text: String) -> String {
        var output = text
        for (pattern, template) in redactionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: NSRange(output.startIndex..., in: output),
                withTemplate: template)
        }
        return output
    }

    /// Field names that carry a credential. One list, used by both notations
    /// below, so a key can't be added to one shape and forgotten in the other.
    /// Kept in step with app/lib/utils/sanitize.dart and SingboxMmPlugin.
    private static let secretKeys =
        "uuid|password|pbk|sid|short_id|obfs[-_]?password"
        + "|auth|auth_str|secret|private_key|pre_shared_key|public_key"

    private static let redactionPatterns: [(String, String)] = [
        // The vless/vmess user id.
        (
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            "<redacted-uuid>"
        ),
        // URI form — how a config *link* spells its credentials.
        (
            "(?i)\\b(\(PacketTunnelProvider.secretKeys))=[^\\s&\"']+",
            "$1=<redacted>"
        ),
        // JSON form — how sing-box spells them, and the shape this file
        // actually handles: the core quotes the fragment of the config it could
        // not load, and that config is JSON. `{"password":"…"}` matches none of
        // the URI patterns, so without this the whole outbound reached
        // diagnostics.txt, the user's screen and their support bundle.
        (
            "(?i)\"(\(PacketTunnelProvider.secretKeys))\"\\s*:\\s*"
                + "(\"(?:[^\"\\\\]|\\\\.)*\"|[^,}\\s\\]]+)",
            "\"$1\": \"<redacted>\""
        ),
        // `scheme://<credential>@host` — everything before the `@` is a secret
        // in every link scheme the app parses.
        ("//[^\\s/@]{4,}@", "//<redacted>@"),
        // Bare `host:port`, so a shared log isn't a map of the panel.
        ("\\b(?:\\d{1,3}\\.){3}\\d{1,3}:\\d{2,5}\\b", "<redacted-endpoint>"),
    ]

    private func startTunnel0(options startOptions: [String: NSObject]?) async throws {
        // The extension process outlives a single session: iOS reuses it for the
        // next connect. A session that ended while the core was paused would
        // leave this set, and the watchdog reads it as "paused, so report
        // unknown" — meaning the new tunnel's health checks would be answered
        // with a shrug until some network event happened to clear the flag.
        corePaused = false
        try? FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        // Not just the three files we write ourselves: these directories are
        // handed to libbox as basePath/workingPath, and everything the core puts
        // there — the DNS and fake-ip cache among it — would otherwise land in
        // an unencrypted Finder or iCloud backup.
        Self.harden(Self.workingDirectory)
        Self.harden(Self.cacheDirectory)

        let effectiveOptions = try resolveStartOptions(startOptions)
        guard let configContent = effectiveOptions["configContent"] as? String, !configContent.isEmpty else {
            throw TunnelStartupError(message: "Missing configContent in tunnel start options")
        }
        tunnelOptions = effectiveOptions

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = Self.sharedDirectory.path
        setupOptions.workingPath = Self.workingDirectory.path
        setupOptions.tempPath = Self.cacheDirectory.path
        // 300 rather than 3000: libbox keeps this many log lines resident, and
        // the ceiling this process runs under is ~50 MB in total.
        setupOptions.logMaxLines = 300

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError {
            throw TunnelStartupError(message: "Libbox setup failed: \(setupError.localizedDescription)")
        }

        let stderrURL = Self.cacheDirectory.appendingPathComponent("stderr.log")
        Self.trimStderrIfOversized(at: stderrURL)
        var stderrError: NSError?
        LibboxRedirectStderr(stderrURL.path, &stderrError)
        Self.harden(stderrURL)
        LibboxSetMemoryLimit(true)

        var serverError: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &serverError)
        if let serverError {
            throw TunnelStartupError(message: "Failed to create command server: \(serverError.localizedDescription)")
        }
        // A gomobile constructor may hand back nil without setting the error
        // out-param. Force-unwrapping it here would be a crash inside a network
        // extension — the exact crash-loop-with-backoff outcome that removing
        // `fatalError` from this file was meant to rule out.
        guard let commandServer else {
            throw TunnelStartupError(message: "Command server was not created")
        }
        do {
            try commandServer.start()
        } catch {
            throw TunnelStartupError(message: "Failed to start command server: \(error.localizedDescription)")
        }

        // Before sing-box, not after: the config it is about to load names the
        // SOCKS server this core provides, and sing-box dials it as soon as the
        // first packet arrives.
        try startXrayIfNeeded(effectiveOptions["xrayConfigContent"] as? String)

        writeMessage("(packet-tunnel) starting sing-box")
        try await startService(configContent: configContent)
        // Only after a start that worked: this snapshot is what iOS reconnects
        // from when it launches the extension with no options, so a config that
        // failed has no business in it.
        persistStartOptions(effectiveOptions)
        // Only now is there a tunnel worth watching.
        healthWatchdog.start()
    }

    /// Discards sing-box's stderr when it has grown past what a diagnostics
    /// report could ever want. Nothing rotates this file — `LibboxRedirectStderr`
    /// appends for the lifetime of the install.
    private static func trimStderrIfOversized(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            size > stderrMaxBytes
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
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

    /// Writes the snapshot iOS falls back to when it launches this extension
    /// without options (an on-demand connect, a restart after a jetsam kill).
    ///
    /// Stamped with a version and a timestamp so [resolveStartOptions] can tell
    /// a usable snapshot from one that has outlived the session it belongs to,
    /// and hardened because it holds the config verbatim — node addresses, VLESS
    /// UUIDs, Trojan/Hysteria2 passwords, WireGuard keys.
    ///
    /// A failure is reported rather than swallowed: a snapshot that silently
    /// stayed on the previous config is worse than none at all.
    private func persistStartOptions(_ options: [String: NSObject]) {
        var stamped = options
        stamped[snapshotVersionKey] = NSNumber(value: snapshotVersion)
        stamped[snapshotSavedAtKey] = NSDate(timeIntervalSince1970: Date().timeIntervalSince1970)
        let url = Self.startOptionsURL
        do {
            try StartOptionsCodec.encode(stamped)
                .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            Self.harden(url)
        } catch {
            writeMessage("(packet-tunnel) could not persist start options: \(error.localizedDescription)")
        }
    }

    /// Removes the persisted snapshot, so nothing can bring this tunnel back up
    /// on a config the user has walked away from.
    static func clearPersistedStartOptions() {
        try? FileManager.default.removeItem(at: startOptionsURL)
    }

    private func loadPersistedStartOptions() throws -> [String: NSObject]? {
        let url = Self.startOptionsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let options: [String: NSObject]
        do {
            options = try StartOptionsCodec.decode(Data(contentsOf: url))
        } catch {
            // A truncated or otherwise unreadable snapshot must not be fatal.
            // Rethrown, it fails the start — and with on-demand enabled iOS
            // relaunches the extension, which fails on the same file again, for
            // as long as the rule stands. Treat it like a missing snapshot: drop
            // it and let the caller ask the app for fresh options.
            writeMessage("(packet-tunnel) discarding unreadable start options snapshot: \(error.localizedDescription)")
            Self.clearPersistedStartOptions()
            return nil
        }
        let version = (options[snapshotVersionKey] as? NSNumber)?.intValue ?? 0
        guard version == snapshotVersion else {
            writeMessage("(packet-tunnel) discarding start options snapshot v\(version)")
            Self.clearPersistedStartOptions()
            return nil
        }
        guard let savedAt = options[snapshotSavedAtKey] as? NSDate,
            Date().timeIntervalSince(savedAt as Date) < snapshotMaxAge
        else {
            writeMessage("(packet-tunnel) discarding expired start options snapshot")
            Self.clearPersistedStartOptions()
            return nil
        }
        var usable = options
        usable.removeValue(forKey: snapshotVersionKey)
        usable.removeValue(forKey: snapshotSavedAtKey)
        return usable
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

    /// Closes sing-box while leaving this tunnel session in place — the teardown
    /// half of `stopTunnel`, and of nothing else.
    ///
    /// Callers outside that path want [shutdownTunnel]: the network settings
    /// stay applied after this returns, so the default route still points into a
    /// utun that nothing is reading. That is not "the VPN dropped", it is "the
    /// device has no internet", while iOS and the app both keep saying
    /// `connected`.
    func stopService() {
        try? commandServer?.closeService()
        platformInterface.reset()
    }

    /// Ends the tunnel session for real: closes sing-box *and* asks iOS to tear
    /// the tunnel down, which retracts the routes and returns the device to its
    /// ordinary network.
    func shutdownTunnel() {
        stopService()
        cancelTunnelWithError(nil)
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
        // A session the user (or the system configuration) ended must not be
        // resurrectable: without this, an extension launched later without
        // options — on-demand, a restart after a jetsam kill — would reconnect
        // to whatever node was last used, with credentials that may since have
        // been revoked, for a user who may since have logged out.
        switch reason {
        case .userInitiated, .userLogout, .userSwitch,
            .configurationRemoved, .configurationDisabled, .authenticationCanceled:
            Self.clearPersistedStartOptions()
        default:
            break
        }
        // Same reason as on the start path: the widget is drawn by the system
        // long after this process is gone, and nothing else will tell it the
        // tunnel went down — a stop from Settings → VPN never reaches the app.
        FatVpnWidgetSnapshot.patchTunnelState("disconnected", connectedAt: nil)
        stopService()
        commandServer?.close()
        commandServer = nil
        // After sing-box, mirroring the start order: while sing-box winds down
        // it can still push traffic at the SOCKS port.
        stopXray()
        completionHandler()
    }

    /// Commands the container app sends over `sendProviderMessage`.
    ///
    /// Only a JSON envelope carrying a `"command"` is accepted. This channel
    /// used to treat anything else as a start-options plist and *immediately
    /// restart sing-box with it*, unvalidated — nothing on the Dart side ever
    /// sent that shape, so it was dead code with a live foot-gun attached.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let envelope = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
            let command = envelope["command"] as? String
        else {
            completionHandler?(Self.encode(["ok": false, "error": "Unrecognized message"]))
            return
        }
        handleCommand(command, envelope, completionHandler: completionHandler)
    }

    private func handleCommand(
        _ command: String,
        _ envelope: [String: Any],
        completionHandler: ((Data?) -> Void)?
    ) {
        switch command {
        case "measureLatency":
            measureLatency(envelope, completionHandler: completionHandler)
        case "stats":
            reportTraffic(completionHandler: completionHandler)
        case "forget":
            // The user logged out or turned the VPN off for good. Drop the
            // snapshot from in here too, not just from the app, so a running
            // extension can't re-persist it on its way down.
            Self.clearPersistedStartOptions()
            completionHandler?(Self.encode(["ok": true]))
        default:
            completionHandler?(Self.encode(["ok": false, "error": "Unknown command: \(command)"]))
        }
    }

    /// Cumulative traffic counters, read from sing-box's own control API.
    ///
    /// The container app cannot ask that API itself — it listens on this
    /// process's loopback, which is not the app's — so the numbers the UI shows
    /// have to come back through here.
    private func reportTraffic(completionHandler: ((Data?) -> Void)?) {
        healthWatchdog.fetchTraffic { traffic in
            guard let traffic else {
                completionHandler?(Self.encode(["ok": false, "error": "Control API unavailable"]))
                return
            }
            completionHandler?(
                Self.encode([
                    "ok": true,
                    "uplinkBytes": traffic.uplinkBytes,
                    "downlinkBytes": traffic.downlinkBytes,
                ]))
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

    /// The device is going to sleep. sing-box is paused, and the watchdog is
    /// told so: a paused core answers no probe, and the two failed rounds that
    /// would produce used to rebuild a perfectly healthy tunnel instead of
    /// simply waking it.
    override func sleep(completionHandler: @escaping () -> Void) {
        corePaused = true
        commandServer?.pause()
        completionHandler()
    }

    /// The underlay this tunnel rides on changed — reported by
    /// [ExtensionPlatformInterface]'s path monitor, which sees it first.
    func underlayDidChange() {
        // Network activity while we believe the core is paused means the `wake`
        // that should have followed `sleep` never arrived (the system only
        // promises it best-effort, and an extension evicted in between never
        // hears it at all). Left alone, sing-box would stay paused forever with
        // the tunnel up and nothing passing through it.
        if corePaused {
            writeMessage("(packet-tunnel) network moved while paused — waking sing-box")
            commandServer?.wake()
            corePaused = false
        }
        healthWatchdog.checkSoon()
    }

    override func wake() {
        commandServer?.wake()
        corePaused = false
        // Coming out of device sleep is a prime moment for a tunnel to still be
        // an interface while no longer having a path to the server.
        healthWatchdog.checkSoon()
    }
}
