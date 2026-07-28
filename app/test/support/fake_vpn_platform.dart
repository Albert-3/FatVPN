// Shared plugin fake for the VpnController tests. Mirrors the pattern already
// used in packages/singbox_mm/test/smoke_vless_ws_config_test.dart: implement
// the whole platform interface so an unexpected call fails loudly rather than
// reaching a real channel.

import 'dart:async';

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
  }

  @override
  Future<void> setXrayConfig(String? configJson) async {}

  @override
  Future<String> validateConfig(String configJson) async => configJson;

  @override
  Future<void> startVpn() async {
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

  @override
  Future<String?> getLastError() async => null;

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
