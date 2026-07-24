import Flutter
import Foundation
import Network
import NetworkExtension
import UserNotifications

public class SingboxMmPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  // Bundle id of the Packet Tunnel Network Extension target (see
  // app/ios/tool/add_packet_tunnel_target.rb — EXT_BUNDLE_ID). The container
  // app never runs sing-box itself; it drives this extension through
  // NETunnelProviderManager, and the extension reads the config we hand it via
  // start options (key "configContent", matching PacketTunnelProvider.startTunnel0).
  private static let tunnelBundleId = "com.fatvpn.fatvpnApp.PacketTunnel"
  // Shared with the PacketTunnel extension. The extension can't stream its logs
  // to the container app, so on a tunnel start failure it writes the reason
  // (plus sing-box stderr tail) to diagnostics.txt here; getLastError reads it.
  private static let appGroupID = "group.com.fatvpn.fatvpnApp"

  private struct RuntimeConfig {
    let workingDirectory: URL
    let binaryPath: String?
    let logLevel: String
    let enableVerboseLogs: Bool
  }

  private final class StatsStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: SingboxMmPlugin?

    init(plugin: SingboxMmPlugin) {
      self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
      -> FlutterError?
    {
      plugin?.statsSink = events
      plugin?.startStatsTimer()
      plugin?.emitStats()
      return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
      plugin?.statsSink = nil
      plugin?.stopStatsTimer()
      return nil
    }
  }

  private var runtimeConfig: RuntimeConfig?
  private var configURL: URL?
  // The last config handed to setConfig(), kept in memory so startVpn() can
  // pass it straight through NETunnelProviderSession start options without
  // re-reading the file (the file write stays as a durability fallback).
  private var activeConfig: String?

  private var connectionState: String = "disconnected"
  private var lastError: String?
  private var connectedAtMillis: Int64?
  private var uplinkBytes: Int64 = 0
  private var downlinkBytes: Int64 = 0

  private var stateSink: FlutterEventSink?
  private var statsSink: FlutterEventSink?
  private var statsTimer: Timer?
  private var statsStreamHandler: StatsStreamHandler?

  private var vpnManager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?

  deinit {
    stopStatsTimer()
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SingboxMmPlugin()

    let methodChannel = FlutterMethodChannel(
      name: "singbox_mm/methods",
      binaryMessenger: registrar.messenger())
    let stateChannel = FlutterEventChannel(
      name: "singbox_mm/state",
      binaryMessenger: registrar.messenger())
    let statsChannel = FlutterEventChannel(
      name: "singbox_mm/stats",
      binaryMessenger: registrar.messenger())

    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    stateChannel.setStreamHandler(instance)
    let statsHandler = StatsStreamHandler(plugin: instance)
    instance.statsStreamHandler = statsHandler
    statsChannel.setStreamHandler(statsHandler)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    stateSink = events
    emitState()
    // Reflect the real tunnel status as soon as the app starts listening,
    // rather than assuming "disconnected" until the first explicit sync.
    refreshManager(emit: true)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stateSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      initialize(arguments: call.arguments, result: result)
    case "requestVpnPermission":
      requestVpnPermission(result: result)
    case "requestNotificationPermission":
      requestNotificationPermission(result: result)
    case "validateConfig":
      validateConfig(arguments: call.arguments, result: result)
    case "setConfig":
      setConfig(arguments: call.arguments, result: result)
    case "startVpn":
      startVpn(result: result)
    case "stopVpn":
      stopVpn(result: result)
    case "restartVpn":
      restartVpn(result: result)
    case "getState":
      result(connectionState)
    case "getStateDetails":
      result(buildStateDetails())
    case "syncRuntimeState":
      syncRuntimeState(result: result)
    case "getStats":
      result(buildStats())
    case "getLastError":
      result(readLastError())
    case "getSingboxVersion":
      result(nil)
    case "pingServer":
      pingServer(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pingServer(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any?],
      let host = args["host"] as? String,
      !host.isEmpty,
      let port = args["port"] as? Int,
      port > 0,
      port <= 65535
    else {
      result([
        "ok": false,
        "error": "Invalid host or port",
      ])
      return
    }

    let timeoutMs = max((args["timeoutMs"] as? Int) ?? 3000, 1)
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
      result([
        "ok": false,
        "error": "Invalid port",
      ])
      return
    }

    let queue = DispatchQueue(label: "singbox_mm.ping")
    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
    let semaphore = DispatchSemaphore(value: 0)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var payload: [String: Any] = [
      "ok": false,
      "error": "Ping failed",
    ]

    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        payload = [
          "ok": true,
          "latencyMs": latencyMs,
        ]
        connection.cancel()
        semaphore.signal()
      case .failed(let error):
        payload = [
          "ok": false,
          "error": error.localizedDescription,
        ]
        semaphore.signal()
      case .cancelled:
        semaphore.signal()
      default:
        break
      }
    }

    connection.start(queue: queue)

    DispatchQueue.global(qos: .utility).async {
      let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
      if waitResult == .timedOut {
        connection.cancel()
        payload = [
          "ok": false,
          "error": "Ping timed out",
        ]
      }
      DispatchQueue.main.async {
        result(payload)
      }
    }
  }

  private func initialize(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any?] else {
      result(
        FlutterError(
          code: "INIT_FAILED",
          message: "Invalid initialize arguments",
          details: nil))
      return
    }

    let workingDirectoryPath = args["workingDirectory"] as? String
    let logLevel = (args["logLevel"] as? String) ?? "info"
    let enableVerboseLogs = (args["enableVerboseLogs"] as? Bool) ?? false

    do {
      let workingDirectory: URL
      if let path = workingDirectoryPath, !path.isEmpty {
        workingDirectory = URL(fileURLWithPath: path, isDirectory: true)
      } else {
        let base = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true)
        workingDirectory = base.appendingPathComponent("signbox", isDirectory: true)
      }

      try FileManager.default.createDirectory(
        at: workingDirectory,
        withIntermediateDirectories: true)

      let binaryPath = args["binaryPath"] as? String

      runtimeConfig = RuntimeConfig(
        workingDirectory: workingDirectory,
        binaryPath: binaryPath,
        logLevel: logLevel,
        enableVerboseLogs: enableVerboseLogs)
      configURL = workingDirectory.appendingPathComponent("active-config.json")

      result(nil)
    } catch {
      result(
        FlutterError(
          code: "INIT_FAILED",
          message: "Unable to initialize runtime: \(error.localizedDescription)",
          details: nil))
    }
  }

  private func setConfig(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any?],
      let config = args["config"] as? String,
      !config.isEmpty
    else {
      result(
        FlutterError(
          code: "INVALID_CONFIG",
          message: "Missing config payload",
          details: nil))
      return
    }

    do {
      let runtime = try ensureRuntime()
      let fileURL = configURL ?? runtime.workingDirectory.appendingPathComponent("active-config.json")
      configURL = fileURL

      try config.write(to: fileURL, atomically: true, encoding: .utf8)
      activeConfig = config
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "CONFIG_WRITE_FAILED",
          message: "Unable to save config: \(error.localizedDescription)",
          details: nil))
    }
  }

  private func validateConfig(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any?],
      let config = args["config"] as? String,
      !config.isEmpty
    else {
      result(
        FlutterError(
          code: "INVALID_CONFIG",
          message: "Missing config payload",
          details: nil))
      return
    }

    do {
      guard let data = config.data(using: .utf8) else {
        throw NSError(
          domain: "singbox_mm",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Config must be UTF-8 text"])
      }
      let object = try JSONSerialization.jsonObject(with: data, options: [])
      guard JSONSerialization.isValidJSONObject(object) else {
        throw NSError(
          domain: "singbox_mm",
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "Config is not a valid JSON object"])
      }
      let normalizedData = try JSONSerialization.data(withJSONObject: object, options: [])
      let normalized = String(data: normalizedData, encoding: .utf8) ?? config
      result(normalized)
    } catch {
      result(
        FlutterError(
          code: "CONFIG_VALIDATE_FAILED",
          message: "Invalid config JSON: \(error.localizedDescription)",
          details: nil))
    }
  }

  // MARK: - Tunnel control (NETunnelProviderManager)

  private func startVpn(result: @escaping FlutterResult) {
    guard let config = activeConfig ?? readConfigFile(), !config.isEmpty else {
      result(
        FlutterError(
          code: "START_FAILED",
          message: "Config is missing. Call setConfig() first.",
          details: nil))
      return
    }

    loadOrCreateManager { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .failure(let error):
        DispatchQueue.main.async { result(self.startError(error)) }
      case .success(let manager):
        self.configure(manager)
        manager.saveToPreferences { saveError in
          if let saveError {
            DispatchQueue.main.async { result(self.startError(saveError)) }
            return
          }
          // Apple quirk: a manager must be re-loaded from preferences after a
          // save before its connection can be started, otherwise
          // startVPNTunnel throws NEVPNError.configurationInvalid.
          manager.loadFromPreferences { loadError in
            if let loadError {
              DispatchQueue.main.async { result(self.startError(loadError)) }
              return
            }
            self.attachManager(manager)
            do {
              try manager.connection.startVPNTunnel(
                options: ["configContent": config as NSString])
              self.lastError = nil
              DispatchQueue.main.async { result(nil) }
            } catch {
              self.lastError = error.localizedDescription
              self.connectionState = "error"
              DispatchQueue.main.async {
                self.emitState()
                result(self.startError(error))
              }
            }
          }
        }
      }
    }
  }

  private func stopVpn(result: @escaping FlutterResult) {
    stopTunnel {
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func restartVpn(result: @escaping FlutterResult) {
    stopTunnel { [weak self] in
      // Give the extension a moment to tear down before re-establishing —
      // starting while the connection is still .disconnecting races the OS.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        self?.startVpn(result: result)
      }
    }
  }

  private func stopTunnel(completion: @escaping () -> Void) {
    loadOrCreateManager { [weak self] outcome in
      guard let self else {
        completion()
        return
      }
      if case .success(let manager) = outcome {
        self.attachManager(manager)
        manager.connection.stopVPNTunnel()
      }
      completion()
    }
  }

  private func syncRuntimeState(result: @escaping FlutterResult) {
    refreshManager(emit: true)
    result(nil)
  }

  private func requestVpnPermission(result: @escaping FlutterResult) {
    loadOrCreateManager { [weak self] outcome in
      guard let self else {
        DispatchQueue.main.async { result(false) }
        return
      }
      switch outcome {
      case .failure:
        DispatchQueue.main.async { result(false) }
      case .success(let manager):
        self.configure(manager)
        // The first saveToPreferences is what surfaces the system "… would
        // like to add VPN configurations" prompt; a nil error means granted.
        manager.saveToPreferences { error in
          if error == nil {
            self.attachManager(manager)
          }
          DispatchQueue.main.async { result(error == nil) }
        }
      }
    }
  }

  private func requestNotificationPermission(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, _ in
      DispatchQueue.main.async { result(granted) }
    }
  }

  private func loadOrCreateManager(
    completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void
  ) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error {
        completion(.failure(error))
        return
      }
      let existing = managers?.first { manager in
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?
          .providerBundleIdentifier == Self.tunnelBundleId
      }
      completion(.success(existing ?? NETunnelProviderManager()))
    }
  }

  private func configure(_ manager: NETunnelProviderManager) {
    let proto =
      (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
    proto.providerBundleIdentifier = Self.tunnelBundleId
    // serverAddress must be non-nil for NEVPNProtocol; the real endpoints live
    // inside the sing-box config, so a human-readable placeholder is fine here.
    proto.serverAddress = "FatVPN"
    manager.protocolConfiguration = proto
    manager.localizedDescription = "FatVPN"
    manager.isEnabled = true
  }

  /// Loads the current manager (creating a reference if one exists in
  /// preferences) purely to observe its status, without touching preferences.
  private func refreshManager(emit: Bool) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
      guard let self else { return }
      guard
        let manager = managers?.first(where: { manager in
          (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier == Self.tunnelBundleId
        })
      else {
        return
      }
      self.attachManager(manager)
      if emit {
        self.handleStatusChange(manager.connection.status)
      }
    }
  }

  private func attachManager(_ manager: NETunnelProviderManager) {
    vpnManager = manager
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: manager.connection,
      queue: .main
    ) { [weak self] _ in
      self?.handleStatusChange(manager.connection.status)
    }
    handleStatusChange(manager.connection.status)
  }

  private func handleStatusChange(_ status: NEVPNStatus) {
    switch status {
    case .connecting:
      connectionState = "connecting"
    case .connected:
      connectionState = "connected"
      if connectedAtMillis == nil {
        connectedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
      }
    case .reasserting:
      connectionState = "connecting"
    case .disconnecting:
      connectionState = "disconnecting"
    case .disconnected, .invalid:
      connectionState = "disconnected"
      connectedAtMillis = nil
      uplinkBytes = 0
      downlinkBytes = 0
    @unknown default:
      connectionState = "disconnected"
    }
    emitState()
    emitStats()
  }

  private func startError(_ error: Error) -> FlutterError {
    FlutterError(
      code: "START_FAILED",
      message: error.localizedDescription,
      details: nil)
  }

  private func readConfigFile() -> String? {
    guard let url = configURL, FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// The extension's last *failure* report, or nil when the tunnel is healthy.
  ///
  /// This backs `getLastError`, which the app surfaces to the user as the
  /// connection error and folds into the support bundle. It must return nil
  /// when nothing actually went wrong — otherwise every benign disconnect
  /// (system on-demand toggle, network change, reconnect) paints a red error
  /// block, because the App Group probe (collectDiagnostics) is *always*
  /// non-empty. A failure is recorded only when the extension persisted one:
  /// a non-OK status line in diagnostics.txt (START FAILED), or a non-empty
  /// stderr tail (a post-start jetsam kill reaches .connected then dies without
  /// hitting startTunnel's error path, so diagnostics.txt is left saying "OK"
  /// and the real reason lives only in Caches/stderr.log, which survives the
  /// kill). When a failure is present we return the full probe so the support
  /// bundle keeps the container/App-Group context; otherwise nil (falling back
  /// to any in-process error).
  private func readLastError() -> String? {
    guard
      let base = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroupID)
    else {
      // The container app has no App Group access, so it can never read what the
      // extension persisted — a Runner-side entitlement/provisioning problem.
      // That *is* a real, actionable fault, so surface it.
      return "APP_GROUP_UNAVAILABLE: container nil for \(Self.appGroupID)"
    }
    let diagText = (try? String(
      contentsOf: base.appendingPathComponent("diagnostics.txt"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let stderrTail = (try? Data(contentsOf: base.appendingPathComponent("Caches/stderr.log")))
      .flatMap { String(data: $0.suffix(6000), encoding: .utf8) }?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    // Success writes "OK: tunnel started" (optionally with a stderr tail folded
    // in); anything else in diagnostics.txt is a persisted failure.
    let diagIndicatesFailure = !diagText.isEmpty && !diagText.contains("OK: tunnel started")
    let hasStderr = !stderrTail.isEmpty
    guard diagIndicatesFailure || hasStderr else {
      // Tunnel is healthy — no persisted failure. Don't surface the probe.
      return lastError
    }
    return collectDiagnostics(base: base)
  }

  /// Full App Group probe — always non-nil. Reports whether the container app
  /// can reach the App Group (the read side), what the container holds, and any
  /// diagnostics/stderr the extension wrote. This disambiguates the two blind
  /// spots — "the app can't read the App Group" vs "the extension wrote nothing"
  /// — which both otherwise surface identically as an empty result. Used to
  /// build the shareable support bundle when a failure is present; never
  /// surfaced on its own as the connection error (see readLastError).
  private func collectDiagnostics(base: URL) -> String {
    var parts: [String] = ["APP_GROUP_OK: \(base.path)"]
    let fm = FileManager.default
    if let rootFiles = try? fm.contentsOfDirectory(atPath: base.path) {
      parts.append("container files: [\(rootFiles.sorted().joined(separator: ", "))]")
    }
    let cachesPath = base.appendingPathComponent("Caches").path
    if let cacheFiles = try? fm.contentsOfDirectory(atPath: cachesPath) {
      parts.append("Caches files: [\(cacheFiles.sorted().joined(separator: ", "))]")
    }
    if let text = try? String(
      contentsOf: base.appendingPathComponent("diagnostics.txt"), encoding: .utf8),
      !text.isEmpty
    {
      parts.append("--- diagnostics.txt ---\n" + text)
    } else {
      parts.append("diagnostics.txt: (absent or empty)")
    }
    if let data = try? Data(contentsOf: base.appendingPathComponent("Caches/stderr.log")),
      let tail = String(data: data.suffix(6000), encoding: .utf8),
      !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      parts.append("--- sing-box stderr (tail) ---\n" + tail)
    } else {
      parts.append("stderr.log: (absent or empty)")
    }
    return parts.joined(separator: "\n")
  }

  private func ensureRuntime() throws -> RuntimeConfig {
    if let runtimeConfig {
      return runtimeConfig
    }

    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    let workingDirectory = base.appendingPathComponent("signbox", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

    let fallback = RuntimeConfig(
      workingDirectory: workingDirectory,
      binaryPath: nil,
      logLevel: "info",
      enableVerboseLogs: false)

    runtimeConfig = fallback
    configURL = workingDirectory.appendingPathComponent("active-config.json")

    return fallback
  }

  private func emitState() {
    stateSink?(buildStateDetails())
  }

  private func buildStateDetails() -> [String: Any?] {
    [
      "state": connectionState,
      "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
      "lastError": lastError,
    ]
  }

  private func emitStats() {
    statsSink?(buildStats())
  }

  private func startStatsTimer() {
    stopStatsTimer()
    guard statsSink != nil else {
      return
    }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.emitStats()
    }
  }

  private func stopStatsTimer() {
    statsTimer?.invalidate()
    statsTimer = nil
  }

  private func buildStats() -> [String: Any?] {
    [
      "uplinkBytes": uplinkBytes,
      "downlinkBytes": downlinkBytes,
      "activeConnections": connectionState == "connected" ? 1 : 0,
      "connectedAt": connectedAtMillis,
      "updatedAt": Int64(Date().timeIntervalSince1970 * 1000),
    ]
  }
}
