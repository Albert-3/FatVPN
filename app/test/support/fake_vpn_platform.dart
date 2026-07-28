// Shared plugin fake for the VpnController tests. Mirrors the pattern already
// used in packages/singbox_mm/test/smoke_vless_ws_config_test.dart: implement
// the whole platform interface so an unexpected call fails loudly rather than
// reaching a real channel.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:singbox_mm/singbox_mm.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

class FakeVpnPlatform with MockPlatformInterfaceMixin implements SignboxVpnPlatform {
  FakeVpnPlatform({
    this.pingLatency = const Duration(milliseconds: 1),
    this.initializeDelay = const Duration(milliseconds: 5),
  });

  final Duration pingLatency;

  /// Stands in for the platform-channel round trip inside `initialize`. It is
  /// the await that opens the §2.3 race, so the idempotency test needs it — but
  /// a `testWidgets` body must pump for a delay to complete, so tests that
  /// `await` initialization directly set this to zero.
  final Duration initializeDelay;

  final StreamController<VpnConnectionState> states =
      StreamController<VpnConnectionState>.broadcast();

  int initializeCalls = 0;

  /// How many times [stateStream] was read. `VpnController` reads it exactly
  /// once per `listen`, in `_ensureInitialized`, so this counts subscriptions.
  int stateStreamReads = 0;

  int startVpnCalls = 0;
  String? capturedConfig;
  VpnConnectionState reportedState = VpnConnectionState.disconnected;

  /// Every [setTunnelPreferences] call, in order — the on-demand / kill-switch
  /// pair from docs/improvement-plan-ios.md §1.3.
  final List<({bool onDemand, bool killSwitch})> tunnelPreferences =
      <({bool onDemand, bool killSwitch})>[];

  /// How many times the app asked the platform to erase the persisted config
  /// and start-options snapshot (§1.6 / §2.1).
  int clearPersistedStateCalls = 0;

  /// Set to have [clearPersistedState] throw, so the best-effort contract
  /// around it can be exercised.
  bool clearPersistedStateThrows = false;

  /// Set to have [setTunnelPreferences] throw. A real platform failure here
  /// costs the user their auto-reconnect / kill-switch preference; it must not
  /// cost them the connection.
  bool setTunnelPreferencesThrows = false;

  /// Set to have [setConfig] throw — a genuinely failed connect, used to prove
  /// the preferences guard did not widen into one that hides real failures.
  bool setConfigThrows = false;

  /// Ordered names of the platform calls that have to happen in a particular
  /// order (preferences must be written into the VPN profile before the tunnel
  /// that uses them starts).
  final List<String> callOrder = <String>[];

  void dispose() => states.close();

  @override
  Stream<VpnConnectionState> get stateStream {
    stateStreamReads++;
    return states.stream;
  }

  @override
  Stream<VpnConnectionSnapshot> get stateDetailsStream =>
      const Stream<VpnConnectionSnapshot>.empty();

  @override
  Stream<VpnRuntimeStats> get statsStream => const Stream<VpnRuntimeStats>.empty();

  @override
  Future<void> initialize(SingboxRuntimeOptions options) async {
    initializeCalls++;
    if (initializeDelay > Duration.zero) {
      await Future<void>.delayed(initializeDelay);
    }
  }

  @override
  Future<void> setConfig(String configJson) async {
    capturedConfig = configJson;
    if (setConfigThrows) {
      throw PlatformException(
        code: 'config_failed',
        message: 'the core refused the config',
      );
    }
  }

  @override
  Future<void> setXrayConfig(String? configJson) async {}

  @override
  Future<void> setTunnelPreferences({
    required bool onDemandEnabled,
    required bool killSwitchEnabled,
  }) async {
    callOrder.add('setTunnelPreferences');
    tunnelPreferences
        .add((onDemand: onDemandEnabled, killSwitch: killSwitchEnabled));
    if (setTunnelPreferencesThrows) {
      throw PlatformException(
        code: 'preferences_failed',
        message: 'could not save the VPN profile',
      );
    }
  }

  @override
  Future<void> clearPersistedState() async {
    callOrder.add('clearPersistedState');
    clearPersistedStateCalls++;
    if (clearPersistedStateThrows) {
      throw StateError('platform refused to clear persisted state');
    }
  }

  @override
  Future<String> validateConfig(String configJson) async => configJson;

  @override
  Future<void> startVpn() async {
    callOrder.add('startVpn');
    startVpnCalls++;
    reportedState = VpnConnectionState.connected;
    states.add(VpnConnectionState.connected);
  }

  @override
  Future<void> stopVpn() async {
    reportedState = VpnConnectionState.disconnected;
    states.add(VpnConnectionState.disconnected);
  }

  @override
  Future<void> restartVpn() async {}

  @override
  Future<VpnConnectionState> getState() async => reportedState;

  @override
  Future<VpnConnectionSnapshot> getStateDetails() async => VpnConnectionSnapshot(
        state: reportedState,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  @override
  Future<VpnRuntimeStats> getStats() async => VpnRuntimeStats.empty();

  @override
  Future<void> syncRuntimeState() async {}

  /// What `getLastError` answers. Settable so a test can play back what the
  /// tunnel service records when the user stops it from outside the app (the
  /// notification's Stop button or the home-screen widget) — see
  /// `VpnController._captureTunnelFailure`.
  String? lastError;

  @override
  Future<String?> getLastError() async => lastError;

  @override
  Future<String?> getSingboxVersion() async => 'fake';

  @override
  Future<bool> requestVpnPermission() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<VpnPingResult> pingServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
    bool useTls = false,
    String? tlsServerName,
    bool allowInsecure = false,
  }) async =>
      VpnPingResult(
        host: host,
        port: port,
        latency: pingLatency,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  @override
  Future<VpnPingResult> pingServerOutsideTunnel({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  }) =>
      pingServer(host: host, port: port, timeout: timeout);
}
