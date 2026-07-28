import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'singbox_mm_platform_interface.dart';
import 'src/models/singbox_runtime_options.dart';
import 'src/models/vpn_connection_state.dart';
import 'src/models/vpn_connection_snapshot.dart';
import 'src/models/vpn_ping_result.dart';
import 'src/models/vpn_runtime_stats.dart';

/// Default method-channel implementation of [SignboxVpnPlatform].
class MethodChannelSignboxVpn extends SignboxVpnPlatform {
  /// Method channel for request/response calls.
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel('singbox_mm/methods');

  /// State event channel.
  @visibleForTesting
  final EventChannel stateChannel = const EventChannel('singbox_mm/state');

  /// Stats event channel.
  @visibleForTesting
  final EventChannel statsChannel = const EventChannel('singbox_mm/stats');

  late final Stream<Map<Object?, Object?>> _stateEventStream = stateChannel
      .receiveBroadcastStream()
      .map<Map<Object?, Object?>>((Object? event) {
        if (event is Map<Object?, Object?>) {
          return event;
        }
        return <Object?, Object?>{'state': event};
      })
      .asBroadcastStream();

  late final Stream<VpnConnectionState> _stateStream = _stateEventStream
      .map<VpnConnectionState>(
        (Map<Object?, Object?> event) =>
            vpnConnectionStateFromWire(event['state']),
      )
      .distinct();

  late final Stream<VpnConnectionSnapshot> _stateDetailsStream =
      _stateEventStream.map<VpnConnectionSnapshot>((
        Map<Object?, Object?> event,
      ) {
        return VpnConnectionSnapshot.fromMap(event);
      });

  late final Stream<VpnRuntimeStats> _statsStream = statsChannel
      .receiveBroadcastStream()
      .map<VpnRuntimeStats>((Object? event) {
        if (event is Map<Object?, Object?>) {
          return VpnRuntimeStats.fromMap(event);
        }
        return VpnRuntimeStats.empty();
      });

  @override
  /// Broadcasts coarse connection state updates.
  Stream<VpnConnectionState> get stateStream => _stateStream;

  @override
  /// Broadcasts detailed connection snapshots.
  Stream<VpnConnectionSnapshot> get stateDetailsStream => _stateDetailsStream;

  @override
  /// Broadcasts runtime traffic statistics.
  Stream<VpnRuntimeStats> get statsStream => _statsStream;

  @override
  /// Initializes native runtime.
  Future<void> initialize(SingboxRuntimeOptions options) {
    return methodChannel.invokeMethod<void>('initialize', options.toMap());
  }

  @override
  /// Requests system VPN permission.
  Future<bool> requestVpnPermission() async {
    final bool? granted = await methodChannel.invokeMethod<bool>(
      'requestVpnPermission',
    );
    return granted ?? false;
  }

  @override
  /// Requests Android notification permission.
  Future<bool> requestNotificationPermission() async {
    final bool? granted = await methodChannel.invokeMethod<bool>(
      'requestNotificationPermission',
    );
    return granted ?? false;
  }

  @override
  /// Applies raw JSON config.
  Future<void> setConfig(String configJson) {
    return methodChannel.invokeMethod<void>('setConfig', <String, Object?>{
      'config': configJson,
    });
  }

  @override
  /// Validates config and returns normalized JSON from native runtime.
  Future<String> validateConfig(String configJson) async {
    final String? normalized = await methodChannel.invokeMethod<String>(
      'validateConfig',
      <String, Object?>{'config': configJson},
    );
    if (normalized == null || normalized.isEmpty) {
      throw PlatformException(
        code: 'CONFIG_VALIDATE_EMPTY',
        message: 'Native validation returned empty config.',
      );
    }
    return normalized;
  }

  @override
  /// Stores (or clears) the Xray config the tunnel process starts alongside
  /// sing-box.
  Future<void> setXrayConfig(String? configJson) {
    return methodChannel.invokeMethod<void>(
      'setXrayConfig',
      <String, Object?>{'config': configJson},
    );
  }

  @override
  /// Records how the OS should treat the tunnel — see
  /// [SignboxVpnPlatform.setTunnelPreferences].
  Future<void> setTunnelPreferences({
    required bool onDemandEnabled,
    required bool killSwitchEnabled,
  }) {
    return _invokeOptional('setTunnelPreferences', <String, Object?>{
      'onDemandEnabled': onDemandEnabled,
      'killSwitchEnabled': killSwitchEnabled,
    });
  }

  @override
  /// Erases the platform's stored copy of the config and any tunnel artifacts —
  /// see [SignboxVpnPlatform.clearPersistedState].
  Future<void> clearPersistedState() {
    return _invokeOptional('clearPersistedState', null);
  }

  /// Calls a method the host platform may not implement.
  ///
  /// Both calls above describe something only one platform has (iOS network
  /// extension lifecycle, iOS App Group artifacts). An older or a different
  /// native side answers `notImplemented`, which the channel raises as a
  /// [MissingPluginException] — a hard failure for a request whose whole
  /// meaning is "if you can, do this".
  ///
  /// Only that one exception is absorbed. A [PlatformException] means the
  /// platform *does* implement the call and it went wrong — the config was not
  /// erased, the VPN profile was not updated — and callers have to be able to
  /// see that: swallowing it here made the "could not clear persisted tunnel
  /// state" warning in VpnController unreachable, which is the same silent
  /// failure this audit is fixing everywhere else.
  Future<void> _invokeOptional(String method, Map<String, Object?>? arguments) async {
    try {
      await methodChannel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      return;
    }
  }

  @override
  /// Starts VPN service.
  Future<void> startVpn() {
    return methodChannel.invokeMethod<void>('startVpn');
  }

  @override
  /// Stops VPN service.
  Future<void> stopVpn() {
    return methodChannel.invokeMethod<void>('stopVpn');
  }

  @override
  /// Restarts VPN service.
  Future<void> restartVpn() {
    return methodChannel.invokeMethod<void>('restartVpn');
  }

  @override
  /// Reads current connection state.
  Future<VpnConnectionState> getState() async {
    final String? state = await methodChannel.invokeMethod<String>('getState');
    return vpnConnectionStateFromWire(state);
  }

  @override
  /// Reads current detailed state snapshot.
  Future<VpnConnectionSnapshot> getStateDetails() async {
    final dynamic raw = await methodChannel.invokeMethod<dynamic>(
      'getStateDetails',
    );
    if (raw is Map<Object?, Object?>) {
      return VpnConnectionSnapshot.fromMap(raw);
    }
    final VpnConnectionState state = await getState();
    return VpnConnectionSnapshot(
      state: state,
      timestamp: DateTime.now().toUtc(),
    );
  }

  @override
  /// Reads current traffic stats.
  Future<VpnRuntimeStats> getStats() async {
    final dynamic raw = await methodChannel.invokeMethod<dynamic>('getStats');
    if (raw is Map<Object?, Object?>) {
      return VpnRuntimeStats.fromMap(raw);
    }
    return VpnRuntimeStats.empty();
  }

  @override
  /// Syncs state/stats from persisted runtime snapshot.
  Future<void> syncRuntimeState() {
    return methodChannel.invokeMethod<void>('syncRuntimeState');
  }

  @override
  /// Reads last runtime error.
  Future<String?> getLastError() {
    return methodChannel.invokeMethod<String>('getLastError');
  }

  @override
  /// Reads current sing-box version.
  Future<String?> getSingboxVersion() {
    return methodChannel.invokeMethod<String>('getSingboxVersion');
  }

  @override
  /// Performs ping over TCP/TLS through native platform implementation.
  Future<VpnPingResult> pingServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
    bool useTls = false,
    String? tlsServerName,
    bool allowInsecure = false,
  }) async {
    final dynamic raw = await methodChannel
        .invokeMethod<dynamic>('pingServer', <String, Object?>{
          'host': host,
          'port': port,
          'timeoutMs': timeout.inMilliseconds,
          'useTls': useTls,
          'tlsServerName': tlsServerName,
          'allowInsecure': allowInsecure,
        });
    if (raw is Map<Object?, Object?>) {
      return VpnPingResult.fromMap(raw, host: host, port: port);
    }
    return VpnPingResult.failure(
      host: host,
      port: port,
      error: 'Invalid ping response',
    );
  }

  @override
  /// Measures latency from outside the tunnel — see
  /// [SingboxMmPlatform.pingServerOutsideTunnel].
  Future<VpnPingResult> pingServerOutsideTunnel({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final dynamic raw = await methodChannel
        .invokeMethod<dynamic>('pingServerOutsideTunnel', <String, Object?>{
          'host': host,
          'port': port,
          'timeoutMs': timeout.inMilliseconds,
        });
    if (raw is Map<Object?, Object?>) {
      return VpnPingResult.fromMap(raw, host: host, port: port);
    }
    return VpnPingResult.failure(
      host: host,
      port: port,
      error: 'Invalid ping response',
    );
  }
}
