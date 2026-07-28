import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'singbox_mm_method_channel.dart';
import 'src/models/singbox_runtime_options.dart';
import 'src/models/vpn_connection_state.dart';
import 'src/models/vpn_connection_snapshot.dart';
import 'src/models/vpn_ping_result.dart';
import 'src/models/vpn_runtime_stats.dart';

/// Platform interface for the native VPN bridge.
abstract class SignboxVpnPlatform extends PlatformInterface {
  /// Creates a platform interface instance.
  SignboxVpnPlatform() : super(token: _token);

  static final Object _token = Object();
  static SignboxVpnPlatform _instance = MethodChannelSignboxVpn();

  /// Active platform implementation.
  static SignboxVpnPlatform get instance => _instance;

  /// Overrides the active platform implementation.
  static set instance(SignboxVpnPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Connection-state stream (`connecting`, `connected`, `error`, ...).
  Stream<VpnConnectionState> get stateStream =>
      const Stream<VpnConnectionState>.empty();

  /// Detailed state stream including diagnostics.
  Stream<VpnConnectionSnapshot> get stateDetailsStream =>
      const Stream<VpnConnectionSnapshot>.empty();

  /// Runtime traffic/stats stream.
  Stream<VpnRuntimeStats> get statsStream =>
      const Stream<VpnRuntimeStats>.empty();

  /// Initializes native runtime with [options].
  Future<void> initialize(SingboxRuntimeOptions options) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Requests VPN permission from the user.
  Future<bool> requestVpnPermission() {
    throw UnimplementedError(
      'requestVpnPermission() has not been implemented.',
    );
  }

  /// Requests Android notification permission when needed.
  Future<bool> requestNotificationPermission() {
    throw UnimplementedError(
      'requestNotificationPermission() has not been implemented.',
    );
  }

  /// Applies raw sing-box JSON config.
  Future<void> setConfig(String configJson) {
    throw UnimplementedError('setConfig() has not been implemented.');
  }

  /// Validates raw sing-box JSON config via the native core and returns
  /// a normalized config string safe to persist/start.
  Future<String> validateConfig(String configJson) {
    throw UnimplementedError('validateConfig() has not been implemented.');
  }

  /// Hands the tunnel process the Xray configuration to run alongside sing-box,
  /// or `null` to run sing-box alone.
  ///
  /// The bundled Xray core terminates transports sing-box has no
  /// implementation for and offers them as a local SOCKS server. It has to be
  /// launched inside the VPN process — that is the only place whose sockets can
  /// be kept out of the tunnel it is feeding — so Dart can only hand the config
  /// down before [startVpn]; the launch itself happens natively.
  ///
  /// Must be called on every connect, including with `null`, so a previous
  /// session's core is not left running for a node that does not need it.
  Future<void> setXrayConfig(String? configJson) {
    throw UnimplementedError('setXrayConfig() has not been implemented.');
  }

  /// Tells the platform how the *system* should treat this tunnel, from the
  /// next connect onward.
  ///
  /// * [onDemandEnabled] — the OS keeps the tunnel up on its own. On iOS this
  ///   is the only thing that ever restarts a network extension the system
  ///   killed (a jetsam kill under memory pressure, a crash): without it the
  ///   user is left with no VPN and traffic in the clear until they next open
  ///   the app. It also brings the tunnel back after a reboot.
  /// * [killSwitchEnabled] — traffic must not leave at all while the tunnel is
  ///   down, rather than quietly falling back to the physical interface.
  ///
  /// A platform that has no equivalent ignores this.
  Future<void> setTunnelPreferences({
    required bool onDemandEnabled,
    required bool killSwitchEnabled,
  }) {
    throw UnimplementedError(
      'setTunnelPreferences() has not been implemented.',
    );
  }

  /// Erases everything the platform keeps on disk about the current
  /// subscription — the stored config, and on iOS the extension's start-options
  /// snapshot and its diagnostics.
  ///
  /// Called when the user turns the VPN off for good and when they log out.
  /// The snapshot in particular is what the OS would otherwise reconnect
  /// *from*, on credentials that may since have been revoked.
  Future<void> clearPersistedState() {
    throw UnimplementedError('clearPersistedState() has not been implemented.');
  }

  /// Starts the VPN service.
  Future<void> startVpn() {
    throw UnimplementedError('startVpn() has not been implemented.');
  }

  /// Stops the VPN service.
  Future<void> stopVpn() {
    throw UnimplementedError('stopVpn() has not been implemented.');
  }

  /// Restarts the VPN service.
  Future<void> restartVpn() {
    throw UnimplementedError('restartVpn() has not been implemented.');
  }

  /// Returns current connection state.
  Future<VpnConnectionState> getState() {
    throw UnimplementedError('getState() has not been implemented.');
  }

  /// Returns detailed connection snapshot.
  Future<VpnConnectionSnapshot> getStateDetails() {
    throw UnimplementedError('getStateDetails() has not been implemented.');
  }

  /// Returns current runtime stats.
  Future<VpnRuntimeStats> getStats() {
    throw UnimplementedError('getStats() has not been implemented.');
  }

  /// Synchronizes state/stats from persisted runtime snapshot.
  Future<void> syncRuntimeState() {
    throw UnimplementedError('syncRuntimeState() has not been implemented.');
  }

  /// Returns last runtime error string, if any.
  Future<String?> getLastError() {
    throw UnimplementedError('getLastError() has not been implemented.');
  }

  /// Returns current sing-box core version string.
  Future<String?> getSingboxVersion() {
    throw UnimplementedError('getSingboxVersion() has not been implemented.');
  }

  /// Executes an active TCP/TLS ping test against [host]:[port].
  Future<VpnPingResult> pingServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
    bool useTls = false,
    String? tlsServerName,
    bool allowInsecure = false,
  }) {
    throw UnimplementedError('pingServer() has not been implemented.');
  }

  /// Measures TCP connect latency to [host]:[port] from **outside** the running
  /// tunnel, so the number describes the route to that server rather than the
  /// route through whichever server is currently carrying this app's traffic.
  ///
  /// Both platforms tunnel this app's own sockets, so an ordinary connect
  /// measures "this device → current server → target": every candidate is
  /// inflated by the live tunnel's own round-trip, and once that tunnel stops
  /// passing traffic every measurement fails at once — exactly when picking a
  /// replacement matters most. How the tunnel is stepped around differs:
  ///
  /// * **iOS** — the measurement is taken inside the packet-tunnel extension,
  ///   whose own traffic bypasses the tunnel it provides, and handed back.
  /// * **Android** — the socket is handed to `VpnService.protect()` before it
  ///   connects, which keeps that one connection on the underlay.
  ///
  /// With no tunnel running this is an ordinary connect, which is the same
  /// answer: there is nothing to step around.
  Future<VpnPingResult> pingServerOutsideTunnel({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  }) {
    throw UnimplementedError(
      'pingServerOutsideTunnel() has not been implemented.',
    );
  }
}
