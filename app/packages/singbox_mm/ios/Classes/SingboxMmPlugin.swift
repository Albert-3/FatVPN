import Flutter
import Foundation
import Network
import NetworkExtension
import UIKit
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

  /// Bytes of sing-box stderr folded into a diagnostics report. Read from the
  /// end of the file rather than by loading it whole — the log has no rotation
  /// and grows for the lifetime of the install.
  private static let stderrTailBytes = 6000

  /// How often the traffic counters are refreshed while the stats screen is
  /// open. Each round is an IPC round-trip to the extension plus an HTTP call
  /// inside it, so a 1 Hz tick was three times the cost for numbers that change
  /// meaningfully far slower.
  private static let statsInterval: TimeInterval = 3.0

  /// How long the app waits for a tunnel it asked to stop to actually be down.
  private static let teardownTimeout: TimeInterval = 10

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

  // The Xray config for the node being connected to, if it needs the second
  // core. Kept in memory only: it is rebuilt on every connect, and a stale one
  // on disk would be worse than none.
  private var activeXrayConfig: String?

  /// Whether iOS should keep this tunnel up on its own (on-demand) and whether
  /// it should be a kill switch. Both off unless the app says otherwise — see
  /// [setTunnelPreferences].
  private var onDemandEnabled = false
  private var killSwitchEnabled = false

  private var connectionState: String = "disconnected"
  private var lastError: String?
  private var connectedAtMillis: Int64?
  private var uplinkBytes: Int64 = 0
  private var downlinkBytes: Int64 = 0

  private var stateSink: FlutterEventSink?
  private var statsSink: FlutterEventSink?
  private var statsTimer: Timer?
  private var statsStreamHandler: StatsStreamHandler?
  private var statsRequestInFlight = false

  private var vpnManager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?
  private var lifecycleObservers: [NSObjectProtocol] = []

  deinit {
    stopStatsTimer()
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
    for observer in lifecycleObservers {
      NotificationCenter.default.removeObserver(observer)
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
    instance.observeAppLifecycle()
  }

  /// Stops polling the tunnel for traffic counters once the app is no longer on
  /// screen. `onListen` fires once and the timer used to keep running for the
  /// rest of the process — including in the background, where nobody is looking
  /// at the numbers and every tick is an IPC round-trip into the extension.
  private func observeAppLifecycle() {
    let center = NotificationCenter.default
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.stopStatsTimer()
      })
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.startStatsTimer()
      })
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    stateSink = events
    // Only publish the cached state when it was actually derived from a tunnel
    // we're observing. On a cold launch `connectionState` is still its
    // "disconnected" default, and emitting it here told the app the VPN was off
    // while it was in fact up from a previous app run — the app then anchored a
    // brand-new session (timer restarting at 00:00:00) once the real status
    // arrived a moment later.
    if vpnManager != nil {
      emitState()
    }
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
    case "setXrayConfig":
      setXrayConfig(arguments: call.arguments, result: result)
    case "setTunnelPreferences":
      setTunnelPreferences(arguments: call.arguments, result: result)
    case "clearPersistedState":
      clearPersistedState(result: result)
    case "startVpn":
      startVpn(result: result)
    case "stopVpn":
      stopVpn(result: result)
    case "restartVpn":
      restartVpn(result: result)
    case "getState":
      resolveState(result: result)
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
    case "pingServerOutsideTunnel":
      pingServerOutsideTunnel(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Latency to a server measured from *outside* the running tunnel, by asking
  /// the Packet Tunnel extension to time the handshake for us.
  ///
  /// A connect issued here, in the container app, is carried by the tunnel — so
  /// measuring a candidate server really measures "device → current server →
  /// candidate". Every alternative comes back inflated by the live tunnel's own
  /// round-trip, and when that tunnel stops passing traffic every candidate
  /// looks unreachable at once, which is exactly when the app needs to find one
  /// that works. The extension's own sockets bypass the tunnel it provides, so
  /// the measurement is honest there (see PacketTunnelProvider.measureLatency).
  ///
  /// With no tunnel running there is nothing to bypass and the in-app path is
  /// already direct, so this falls back to [pingServer] — as it does when the
  /// extension can't be reached at all, which must degrade to a worse number
  /// rather than to no number.
  private func pingServerOutsideTunnel(arguments: Any?, result: @escaping FlutterResult) {
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

    guard let session = vpnManager?.connection as? NETunnelProviderSession,
      session.status == .connected,
      let message = try? JSONSerialization.data(withJSONObject: [
        "command": "measureLatency",
        "host": host,
        "port": port,
        "timeoutMs": timeoutMs,
      ])
    else {
      pingServer(arguments: arguments, result: result)
      return
    }

    // `answered` is only ever touched on the main queue, so the watchdog and
    // the extension's reply can't both resolve the call — handing a
    // FlutterResult two answers is a hard crash.
    var answered = false
    let deliver: ([String: Any]) -> Void = { payload in
      DispatchQueue.main.async {
        guard !answered else { return }
        answered = true
        result(payload)
      }
    }

    do {
      try session.sendProviderMessage(message) { response in
        guard let response,
          let payload = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        else {
          deliver([
            "ok": false,
            "error": "Tunnel extension returned no usable answer",
          ])
          return
        }
        deliver(payload)
      }
    } catch {
      pingServer(arguments: arguments, result: result)
      return
    }

    // A reply that never comes would leave the caller awaiting forever. The
    // extension bounds its own measurement by timeoutMs, so anything past that
    // plus a margin means the IPC itself is gone, not that the server is slow.
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs + 2000)) {
      deliver([
        "ok": false,
        "error": "Tunnel extension did not answer in time",
      ])
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
    guard let nwPort = Network.NWEndpoint.Port(rawValue: UInt16(port)) else {
      result([
        "ok": false,
        "error": "Invalid port",
      ])
      return
    }

    Self.tcpLatencyMs(host: host, port: nwPort, timeoutMs: timeoutMs) { latencyMs, error in
      DispatchQueue.main.async {
        guard let latencyMs else {
          result(["ok": false, "error": error ?? "Ping failed"])
          return
        }
        result(["ok": true, "latencyMs": latencyMs])
      }
    }
  }

  /// Round-trip of a TCP connect to [host]:[port], or nil with a reason.
  ///
  /// One serial queue owns everything: NWConnection delivers its state updates
  /// there and the timeout is scheduled on it, so `settled` needs no lock and
  /// the completion fires exactly once whichever of "ready", "failed" and
  /// "timed out" arrives first — and the connection is always cancelled.
  ///
  /// The previous version wrote its result dictionary from the connection's
  /// queue *and* from a global one on timeout (a data race on a Swift
  /// dictionary), and left `.failed` connections uncancelled: a single
  /// auto-switch round pings every node in the subscription, so unreachable
  /// ones piled up as live NWConnections until the plugin was deallocated.
  private static func tcpLatencyMs(
    host: String,
    // `Network.` qualified: NetworkExtension exports its own (deprecated)
    // NWEndpoint, so the bare name is ambiguous once both are imported.
    port: Network.NWEndpoint.Port,
    timeoutMs: Int,
    completion: @escaping (Int?, String?) -> Void
  ) {
    let queue = DispatchQueue(label: "singbox_mm.ping")
    let connection = NWConnection(
      host: Network.NWEndpoint.Host(host), port: port, using: .tcp)
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
      // The config written into this directory is the user's subscription in
      // the clear; keep the whole directory out of backups.
      Self.harden(workingDirectory)

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

      guard let data = config.data(using: .utf8) else {
        throw NSError(
          domain: "singbox_mm", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "Config must be UTF-8 text"])
      }
      // This file holds the subscription verbatim — VLESS/VMess UUIDs, Trojan
      // and Hysteria2 passwords, WireGuard private keys, every node address.
      // Written protected at rest and excluded from backups, because an
      // unencrypted Finder or iCloud backup is the one place it would otherwise
      // leave the device in the clear.
      try data.write(
        to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      Self.harden(fileURL)
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

  /// Stores the Xray config the extension starts alongside sing-box, or clears
  /// it when the app passes nothing.
  ///
  /// Unlike `setConfig` a missing payload is not an error — it is how the app
  /// says "this node needs only sing-box". Clearing matters as much as setting:
  /// a config left from an earlier session would bring a second core up inside
  /// an extension that has little memory to spare.
  private func setXrayConfig(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any?]
    let config = (args?["config"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    activeXrayConfig = config
    result(nil)
  }

  /// Records how the *system* should treat this tunnel, for the next connect.
  ///
  /// * `onDemandEnabled` — iOS brings the tunnel back on its own. Without it a
  ///   network extension the system killed (a jetsam kill under memory
  ///   pressure, a crash) is never restarted: the user is left with no VPN and
  ///   traffic in the clear, and only finds out when they next open the app.
  ///   It also survives a device reboot.
  /// * `killSwitchEnabled` — `NEVPNProtocol.includeAllNetworks`, which stops
  ///   traffic from leaving at all while the tunnel is down, instead of
  ///   silently falling back to the physical interface.
  ///
  /// Applied on the next connect rather than immediately: rewriting the
  /// protocol configuration of a running tunnel can bounce it, and neither
  /// setting is urgent enough to justify dropping the session the user is on.
  private func setTunnelPreferences(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any?]
    onDemandEnabled = (args?["onDemandEnabled"] as? Bool) ?? false
    killSwitchEnabled = (args?["killSwitchEnabled"] as? Bool) ?? false
    result(nil)
  }

  /// Erases everything this app and its extension keep on disk about the
  /// current subscription. Called when the user turns the VPN off for good and
  /// when they log out.
  ///
  /// Three artifacts, all of them plain text and all of them quoting
  /// credentials: the Application Support copy of the config, the extension's
  /// start-options snapshot in the App Group (which is what iOS would otherwise
  /// reconnect *from*, on a subscription that may since have been revoked), and
  /// the diagnostics/stderr the extension wrote.
  private func clearPersistedState(result: @escaping FlutterResult) {
    activeConfig = nil
    activeXrayConfig = nil
    lastError = nil

    let fm = FileManager.default
    // `configURL` is only set once `initialize`/`ensureRuntime` has run. A
    // logout in a process that never connected would otherwise leave the
    // config — the subscription in the clear — on disk, which is exactly what
    // this call exists to prevent. Fall back to the default location instead of
    // trusting the cached one.
    var configTargets: [URL] = []
    if let url = configURL {
      configTargets.append(url)
    }
    if let base = try? fm.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    {
      let defaultURL =
        base
        .appendingPathComponent("signbox", isDirectory: true)
        .appendingPathComponent("active-config.json")
      if !configTargets.contains(defaultURL) {
        configTargets.append(defaultURL)
      }
    }
    for url in configTargets {
      try? fm.removeItem(at: url)
    }
    if let base = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
      try? fm.removeItem(at: base.appendingPathComponent("start_options.plist"))
      try? fm.removeItem(at: base.appendingPathComponent("diagnostics.txt"))
      try? fm.removeItem(at: base.appendingPathComponent("Caches/stderr.log"))
    }
    // A still-running extension holds the config in memory and re-persists it
    // on the way down, so ask it to forget too. Best-effort: there is usually no
    // tunnel left to ask by the time this runs.
    if let session = vpnManager?.connection as? NETunnelProviderSession,
      session.status != .invalid, session.status != .disconnected,
      let message = try? JSONSerialization.data(withJSONObject: ["command": "forget"])
    {
      try? session.sendProviderMessage(message) { _ in }
    }
    result(nil)
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
              var startOptions: [String: NSObject] = ["configContent": config as NSString]
              if let xrayConfig = self.activeXrayConfig {
                startOptions["xrayConfigContent"] = xrayConfig as NSString
              }
              // sing-box has to know it is running inside a kill switch, so it
              // does not route around a tunnel nothing may escape.
              startOptions["includeAllNetworks"] = NSNumber(value: self.killSwitchEnabled)
              try manager.connection.startVPNTunnel(options: startOptions)
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
    // A stop that ran out the teardown timeout is still a stop — the
    // connection keeps winding down on its own and nothing waits to start
    // from it — so the flag is deliberately ignored here. It exists for
    // [restartVpn], which does have something waiting.
    stopTunnel { _ in
      result(nil)
    }
  }

  private func restartVpn(result: @escaping FlutterResult) {
    stopTunnel { [weak self] reachedDown in
      guard let self else {
        result(nil)
        return
      }
      // No arbitrary delay any more: [stopTunnel] only calls back once the
      // connection has actually left `.disconnecting`, which is the state
      // `startVPNTunnel` silently refuses to start from — that refusal is why
      // changing servers used to do nothing at all sometimes.
      //
      // And when the timeout ran out instead (V21): starting anyway means iOS
      // drops the start on the floor while `result(nil)` reports success —
      // the very "server change did nothing" this path was rewritten to end.
      // An error at least reaches Dart, where a failed switch is handled.
      guard reachedDown else {
        result(FlutterError(
          code: "RESTART_TIMEOUT",
          message: "The previous tunnel was still disconnecting after "
            + "\(Int(Self.teardownTimeout))s; not starting over it",
          details: nil))
        return
      }
      self.startVpn(result: result)
    }
  }

  /// Stops the tunnel and calls back once it is really down — `true` — or
  /// once [teardownTimeout] ran out with the connection still winding down —
  /// `false`.
  ///
  /// Uses [loadExistingManager], not `loadOrCreateManager`: if there is no
  /// saved configuration there is nothing to stop, and the fabricated manager
  /// the other one returns would be attached to and observed forever with a
  /// permanently `.invalid` connection — which pins the reported state to
  /// "disconnected" no matter what the real tunnel is doing.
  private func stopTunnel(completion: @escaping (Bool) -> Void) {
    loadExistingManager { [weak self] manager in
      guard let self, let manager else {
        DispatchQueue.main.async { completion(true) }
        return
      }
      self.attachManager(manager)
      let stop = {
        manager.connection.stopVPNTunnel()
        self.awaitDisconnected(manager, completion: completion)
      }
      // An on-demand rule would bring the tunnel straight back up the moment we
      // stopped it, so it has to come off first — otherwise the user's own
      // "disconnect" is undone by the system a second later.
      if manager.isOnDemandEnabled {
        manager.isOnDemandEnabled = false
        manager.saveToPreferences { error in
          if let error {
            // The stop below still happens, but the rule stayed in the profile:
            // iOS will bring the tunnel back up within seconds and the app will
            // have reported a successful disconnect. Without this line that
            // looks like the tunnel spontaneously reconnecting, with nothing
            // anywhere to explain it.
            self.lastError =
              "Failed to clear the on-demand rule before stopping: "
              + error.localizedDescription
            NSLog("[singbox_mm] on-demand teardown failed: \(error)")
          }
          stop()
        }
      } else {
        stop()
      }
    }
  }

  /// Waits for [manager]'s connection to reach a down state, or for
  /// [teardownTimeout] to pass.
  ///
  /// Teardown is asynchronous and takes as long as sing-box needs to wind down
  /// a loaded connection; answering immediately (or after a fixed 0.6 s, as
  /// this used to) means the next `startVPNTunnel` lands while the connection
  /// is still `.disconnecting`, where iOS drops it on the floor.
  private func awaitDisconnected(
    _ manager: NETunnelProviderManager, completion: @escaping (Bool) -> Void
  ) {
    // The whole body belongs on the main queue, not just the closures below.
    // This is called from a `loadExistingManager`/`saveToPreferences` callback,
    // and NE delivers those on a queue of its own choosing — registering the
    // observer there while `finish` reads `observer` on main is a data race, and
    // a status change landing in the gap leaves the observer registered for the
    // rest of the process.
    onPlatformThread {
      let isDown: (NEVPNStatus) -> Bool = { $0 == .disconnected || $0 == .invalid }
      if isDown(manager.connection.status) {
        completion(true)
        return
      }
      var observer: NSObjectProtocol?
      var finished = false
      // Everything here now runs on the main queue, so `finished` needs no lock.
      let finish = { (reachedDown: Bool) in
        guard !finished else { return }
        finished = true
        if let observer {
          NotificationCenter.default.removeObserver(observer)
        }
        completion(reachedDown)
      }
      observer = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: manager.connection,
        queue: .main
      ) { _ in
        if isDown(manager.connection.status) {
          finish(true)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.teardownTimeout) {
        // The caller decides what a timeout means (V21): for a plain stop it
        // is nothing, for a restart it is "do not start over a connection
        // still in .disconnecting — iOS ignores that start silently".
        finish(false)
      }
    }
  }

  private func syncRuntimeState(result: @escaping FlutterResult) {
    refreshManager(emit: true)
    result(nil)
  }

  /// Answers `getState` from the *real* tunnel status rather than the in-memory
  /// cache. The cache is only trustworthy once we're observing a manager: it
  /// starts out "disconnected" on every cold launch, so a tunnel still running
  /// from a previous app run used to be reported as down until the
  /// NEVPNStatusDidChange observer happened to fire. The app reconciles its UI
  /// against this call on launch and on resume, so a stale answer here is what
  /// made the toggle and the session timer disagree with the system VPN.
  private func resolveState(result: @escaping FlutterResult) {
    if let connection = vpnManager?.connection {
      handleStatusChange(connection.status)
      result(connectionState)
      return
    }
    loadExistingManager { [weak self] manager in
      // Always answer: a getState that never completes stalls the app's
      // launch/resume reconciliation on an un-completable await.
      guard let self else {
        DispatchQueue.main.async { result("disconnected") }
        return
      }
      if let manager {
        self.attachManager(manager)
      }
      DispatchQueue.main.async { result(self.connectionState) }
    }
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
    if #available(iOS 14.0, *) {
      // Kill switch. With it on, iOS refuses to carry traffic on any interface
      // while the tunnel is down, instead of quietly falling back to the
      // physical one — which is the window every "VPN dropped and I didn't
      // notice" report is really about.
      proto.includeAllNetworks = killSwitchEnabled
    }
    if #available(iOS 14.2, *) {
      // Local networks stay reachable even under the kill switch: AirPlay,
      // printers and the router's own admin page are not what it is for, and
      // capturing them breaks far more than it protects.
      proto.excludeLocalNetworks = killSwitchEnabled
    }
    manager.protocolConfiguration = proto
    manager.localizedDescription = "FatVPN"
    manager.isEnabled = true
    // On-demand. iOS never restarts a network extension it killed — a jetsam
    // kill or a crash leaves the user with no VPN and no notification — and it
    // never brings the tunnel back after a reboot. A connect rule is what turns
    // the snapshot the extension already persists into an actual recovery.
    manager.isOnDemandEnabled = onDemandEnabled
    if onDemandEnabled {
      let rule = NEOnDemandRuleConnect()
      rule.interfaceTypeMatch = .any
      manager.onDemandRules = [rule]
    } else {
      manager.onDemandRules = []
    }
  }

  /// Looks up our already-saved tunnel manager, or nil when the user has never
  /// approved a VPN configuration. Unlike [loadOrCreateManager] this never
  /// fabricates a fresh unsaved manager — attaching to one of those would
  /// observe a permanently `.invalid` connection and pin the state to
  /// "disconnected".
  private func loadExistingManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
      completion(
        managers?.first { manager in
          (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier == Self.tunnelBundleId
        })
    }
  }

  /// Loads the current manager (creating a reference if one exists in
  /// preferences) purely to observe its status, without touching preferences.
  private func refreshManager(emit: Bool) {
    loadExistingManager { [weak self] manager in
      guard let self, let manager else { return }
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

  /// The config last written by [setConfig], read back from disk.
  ///
  /// Resolves the location through [ensureRuntime] rather than trusting the
  /// cached `configURL`: that field is only populated once `initialize` (or an
  /// earlier `setConfig`) has run *in this process*, so a `startVpn` that
  /// arrives before either would report "Config is missing" while the config sat
  /// on disk the whole time. `clearPersistedState` already resolves the same
  /// default path for the delete side; this is the read side of it.
  private func readConfigFile() -> String? {
    let url = configURL ?? (try? ensureRuntime())?.workingDirectory
      .appendingPathComponent("active-config.json")
    guard let url, FileManager.default.fileExists(atPath: url.path) else {
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
    let stderrTail = Self.tailOfFile(
      at: base.appendingPathComponent("Caches/stderr.log"), maxBytes: Self.stderrTailBytes)?
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
  ///
  /// Everything quoted from the core is redacted first: this text is shown on
  /// screen and shared by the user, and sing-box's own error messages cite the
  /// outbound they failed on — credentials included.
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
    if let tail = Self.tailOfFile(
      at: base.appendingPathComponent("Caches/stderr.log"), maxBytes: Self.stderrTailBytes),
      !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      parts.append("--- sing-box stderr (tail) ---\n" + Self.redactSecrets(tail))
    } else {
      parts.append("stderr.log: (absent or empty)")
    }
    return parts.joined(separator: "\n")
  }

  /// Last [maxBytes] of a file, read from the end rather than loaded whole.
  /// `Data(contentsOf:)` here meant pulling a log with no rotation — months of
  /// sing-box stderr — entirely into memory just to quote its tail.
  private static func tailOfFile(at url: URL, maxBytes: Int) -> String? {
    guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
    defer { handle.closeFile() }
    let size = handle.seekToEndOfFile()
    let wanted = UInt64(max(maxBytes, 0))
    handle.seek(toFileOffset: size > wanted ? size - wanted : 0)
    return Self.decodeTail(handle.readDataToEndOfFile())
  }

  /// Decodes a byte range that almost certainly starts mid-character.
  ///
  /// Cutting a log at a fixed offset lands inside a multi-byte sequence
  /// whenever it contains one, and `String(data:encoding:.utf8)` answers `nil`
  /// for the *whole* buffer when it does. That `nil` is read as "no stderr" by
  /// the caller — so a tunnel that died of a jetsam kill, the one case where
  /// this file is the only evidence, would be reported as "no errors". Skip
  /// forward past any continuation bytes (`10xxxxxx`) and decode from the first
  /// real character boundary.
  private static func decodeTail(_ data: Data) -> String? {
    if let text = String(data: data, encoding: .utf8) { return text }
    var start = data.startIndex
    let limit = data.index(start, offsetBy: min(4, data.count))
    while start < limit, data[start] & 0xC0 == 0x80 {
      start = data.index(after: start)
    }
    return String(data: data[start...], encoding: .utf8)
      ?? String(decoding: data[start...], as: UTF8.self)
  }

  /// Marks a file or directory as protected at rest and keeps it out of
  /// iCloud/Finder backups.
  private static func harden(_ url: URL) {
    var target = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? target.setResourceValues(values)
    try? FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path)
  }

  /// Replaces credentials and endpoints in free-form diagnostic text. Mirrors
  /// app/lib/utils/sanitize.dart and PacketTunnelProvider.redactSecrets:
  /// over-redacting costs a support engineer context, under-redacting hands
  /// whoever reads a shared log the user's subscription.
  private static func redactSecrets(_ text: String) -> String {
    var output = text
    for (pattern, template) in redactionPatterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      output = regex.stringByReplacingMatches(
        in: output,
        options: [],
        range: NSRange(output.startIndex..., in: output),
        withTemplate: template)
    }
    // The passes a (pattern, template) pair cannot express — each one keeps
    // something the blunt regex would eat (timestamps, loopback, outbound
    // tags). Mirrored in app/lib/utils/sanitize.dart and
    // PacketTunnelProvider.redactSecrets (V26).
    output = replaceMatches(in: output, pattern: "\\b[0-9a-fA-F]{32,}\\b") { _ in
      "<redacted-hex>"
    }
    output = replaceMatches(in: output, pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b") { match in
      localAddresses.contains(match) ? match : "<redacted-ip>"
    }
    output = replaceMatches(
      in: output,
      pattern: "(?<![\\w.:])[0-9a-fA-F:]*:[0-9a-fA-F:]+(?![\\w.:])"
    ) { match in
      isIpv6Literal(match) ? "<redacted-ip>" : match
    }
    output = replaceMatches(in: output, pattern: "[A-Za-z0-9+/]{20,}={0,2}") { match in
      looksLikeSecretBlob(match) ? "<redacted-blob>" : match
    }
    return output
  }

  /// Loopback identifies the phone, not the panel, and the watchdog's
  /// `127.0.0.1` / `[::1]` probes are half of every tunnel log.
  private static let localAddresses: Set<String> = ["127.0.0.1", "0.0.0.0", "::1", "::"]

  /// A timestamp's `12:00:00` has the same shape as an IPv6 candidate; what
  /// only an address has is a `::` or four-plus groups' worth of colons.
  private static func isIpv6Literal(_ text: String) -> Bool {
    if localAddresses.contains(text) { return false }
    if text.contains("::") { return true }
    return text.filter { $0 == ":" }.count >= 3
  }

  /// What separates a blob (an encoded subscription, a key) from a long word
  /// or an `outbound/vless…` tag: real base64 of real config material mixes
  /// cases and digits, or uses the `+`/`=` that never appear in prose.
  private static func looksLikeSecretBlob(_ text: String) -> Bool {
    if text.contains("+") || text.hasSuffix("=") { return true }
    let hasDigit = text.rangeOfCharacter(from: .decimalDigits) != nil
    let hasLower = text.rangeOfCharacter(from: .lowercaseLetters) != nil
    let hasUpper = text.rangeOfCharacter(from: .uppercaseLetters) != nil
    return hasDigit && hasLower && hasUpper
  }

  /// `stringByReplacingMatches` with a closure instead of a template, for the
  /// passes whose replacement depends on what matched.
  private static func replaceMatches(
    in text: String,
    pattern: String,
    transform: (String) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let source = text as NSString
    var result = ""
    var consumed = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      result += source.substring(with: NSRange(location: consumed, length: match.range.location - consumed))
      result += transform(source.substring(with: match.range))
      consumed = match.range.location + match.range.length
    }
    result += source.substring(from: consumed)
    return result
  }

  /// Field names that carry a credential. One list for both notations below,
  /// kept in step with app/lib/utils/sanitize.dart and PacketTunnelProvider.
  private static let secretKeys =
    "uuid|password|pbk|sid|short_id|obfs[-_]?password"
    + "|auth|auth_str|secret|private_key|pre_shared_key|public_key"

  private static let redactionPatterns: [(String, String)] = [
    (
      "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
      "<redacted-uuid>"
    ),
    // URI form — how a config link spells its credentials.
    (
      "(?i)\\b(\(SingboxMmPlugin.secretKeys))=[^\\s&\"']+",
      "$1=<redacted>"
    ),
    // JSON form — how sing-box spells them when it quotes the config it failed
    // to load, which is the shape that actually reaches the stderr tail.
    (
      "(?i)\"(\(SingboxMmPlugin.secretKeys))\"\\s*:\\s*"
        + "(\"(?:[^\"\\\\]|\\\\.)*\"|[^,}\\s\\]]+)",
      "\"$1\": \"<redacted>\""
    ),
    // ss:// userinfo is base64 and '/' is in the base64 alphabet, so the
    // rule below (which stops at '/') walked straight past it.
    ("://[^\\s@]{6,}@", "://<redacted>@"),
    ("//[^\\s/@]{4,}@", "//<redacted>@"),
    ("\\b(?:\\d{1,3}\\.){3}\\d{1,3}:\\d{2,5}\\b", "<redacted-endpoint>"),
  ]

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
    Self.harden(workingDirectory)

    let fallback = RuntimeConfig(
      workingDirectory: workingDirectory,
      binaryPath: nil,
      logLevel: "info",
      enableVerboseLogs: false)

    runtimeConfig = fallback
    configURL = workingDirectory.appendingPathComponent("active-config.json")

    return fallback
  }

  /// Runs `work` on the platform thread, immediately when already there.
  ///
  /// Flutter sinks and channels may only be touched on the platform thread —
  /// in a debug build the engine asserts, in release it is undefined
  /// behaviour. Every `result(...)` in this file is already dispatched this
  /// way; the event sinks were not, and they are reachable from the same
  /// NetworkExtension callbacks (`attachManager` ends in `handleStatusChange`,
  /// which emits). NE promises nothing about which thread delivers those.
  private func onPlatformThread(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  private func emitState() {
    onPlatformThread { [weak self] in
      guard let self else { return }
      self.stateSink?(self.buildStateDetails())
    }
  }

  private func buildStateDetails() -> [String: Any?] {
    [
      "state": connectionState,
      "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
      "lastError": lastError,
    ]
  }

  private func emitStats() {
    onPlatformThread { [weak self] in
      guard let self else { return }
      self.statsSink?(self.buildStats())
    }
  }

  private func startStatsTimer() {
    stopStatsTimer()
    guard statsSink != nil else {
      return
    }
    statsTimer = Timer.scheduledTimer(withTimeInterval: Self.statsInterval, repeats: true) {
      [weak self] _ in
      self?.refreshStatsFromTunnel()
      self?.emitStats()
    }
    refreshStatsFromTunnel()
  }

  private func stopStatsTimer() {
    statsTimer?.invalidate()
    statsTimer = nil
  }

  /// Pulls the real byte counters out of the extension.
  ///
  /// They cannot be read here: sing-box reports them over its control API,
  /// which listens on the *extension's* loopback — a different process, and
  /// `127.0.0.1` is not shared between them. Without this the traffic figures
  /// on iOS were structurally zero: nothing ever incremented them, and the
  /// stats channel published that zero once a second forever.
  private func refreshStatsFromTunnel() {
    guard !statsRequestInFlight,
      let session = vpnManager?.connection as? NETunnelProviderSession,
      session.status == .connected,
      let message = try? JSONSerialization.data(withJSONObject: ["command": "stats"])
    else {
      return
    }
    statsRequestInFlight = true
    // A reply that never arrives must not wedge the poll permanently.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.statsInterval) { [weak self] in
      self?.statsRequestInFlight = false
    }
    do {
      try session.sendProviderMessage(message) { [weak self] response in
        DispatchQueue.main.async {
          guard let self else { return }
          self.statsRequestInFlight = false
          guard let response,
            let payload = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
            (payload["ok"] as? Bool) == true
          else {
            return
          }
          self.uplinkBytes = (payload["uplinkBytes"] as? NSNumber)?.int64Value ?? self.uplinkBytes
          self.downlinkBytes =
            (payload["downlinkBytes"] as? NSNumber)?.int64Value ?? self.downlinkBytes
          self.emitStats()
        }
      }
    } catch {
      statsRequestInFlight = false
    }
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
