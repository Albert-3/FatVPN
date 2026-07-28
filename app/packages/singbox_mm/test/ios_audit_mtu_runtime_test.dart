// docs/improvement-plan-ios.md §3.4, second half: the MTU that reaches the
// config through the *runtime* path, not just the config builder.
//
// The builder resolves `throttlePolicy.tunMtu ?? inbound.mtu ?? platform
// default`, but the throttle policy handed to it is not the one the caller
// passed — `_effectiveThrottlePolicyForProfile` rewrites it first, and that is
// where the auto-MTU probe lives. Making `tunMtu` nullable created a specific
// hazard there: `mtuCandidates.indexOf(null)` is -1, `max(0, -1)` is 0, and
// candidate 0 is the *highest* value in the list. Unguarded, every ordinary
// connect would have been pinned to 1400 — overriding the platform default on
// Android (1100), which is the shipped, device-tested value.
//
// So these tests drive SignboxVpn itself and read what was actually written.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:singbox_mm/singbox_mm.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

class _CapturePlatform
    with MockPlatformInterfaceMixin
    implements SignboxVpnPlatform {
  final StreamController<VpnConnectionState> _states =
      StreamController<VpnConnectionState>.broadcast();
  final List<String> writtenConfigs = <String>[];

  @override
  Stream<VpnConnectionState> get stateStream => _states.stream;

  @override
  Stream<VpnConnectionSnapshot> get stateDetailsStream =>
      const Stream<VpnConnectionSnapshot>.empty();

  @override
  Stream<VpnRuntimeStats> get statsStream =>
      const Stream<VpnRuntimeStats>.empty();

  @override
  Future<void> initialize(SingboxRuntimeOptions options) async {}

  @override
  Future<void> setConfig(String configJson) async {
    writtenConfigs.add(configJson);
  }

  @override
  Future<void> setXrayConfig(String? configJson) async {}

  @override
  Future<void> setTunnelPreferences({
    required bool onDemandEnabled,
    required bool killSwitchEnabled,
  }) async {}

  @override
  Future<void> clearPersistedState() async {}

  @override
  Future<String> validateConfig(String configJson) async => configJson;

  @override
  Future<void> startVpn() async {
    _states.add(VpnConnectionState.connected);
  }

  @override
  Future<void> stopVpn() async {
    _states.add(VpnConnectionState.disconnected);
  }

  @override
  Future<void> restartVpn() async {}

  @override
  Future<VpnConnectionState> getState() async => VpnConnectionState.connected;

  @override
  Future<VpnConnectionSnapshot> getStateDetails() async =>
      VpnConnectionSnapshot(
        state: VpnConnectionState.connected,
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

  VpnPingResult _pong(String host, int port) => VpnPingResult(
        host: host,
        port: port,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        latency: const Duration(milliseconds: 1),
      );

  @override
  Future<VpnPingResult> pingServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
    bool useTls = false,
    String? tlsServerName,
    bool allowInsecure = false,
  }) async => _pong(host, port);

  @override
  Future<VpnPingResult> pingServerOutsideTunnel({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  }) async => _pong(host, port);

  Future<void> dispose() async => _states.close();
}

VpnProfile _profile(String tag) => VpnProfile.vless(
      tag: tag,
      server: '$tag.example.com',
      serverPort: 443,
      uuid: '11111111-2222-3333-4444-555555555555',
      tls: const TlsOptions(enabled: true),
    );

int _mtuOf(String configJson) {
  final config = jsonDecode(configJson) as Map<String, dynamic>;
  final tun = (config['inbounds'] as List<dynamic>).firstWhere(
    (dynamic i) => i is Map<String, dynamic> && i['type'] == 'tun',
  ) as Map<String, dynamic>;
  return tun['mtu'] as int;
}

void main() {
  test('an ordinary connect keeps the platform default MTU', () async {
    // The regression this exists to catch. TLS is on and the auto-MTU probe is
    // enabled by default, which is exactly the combination that reaches the
    // tuning code — but nothing has been configured and nothing has probed, so
    // there is no baseline to tune and the platform default must survive.
    final platform = _CapturePlatform();
    SignboxVpnPlatform.instance = platform;
    final vpn = SignboxVpn();
    await vpn.initialize(const SingboxRuntimeOptions());

    await vpn.applyEndpointPool(
      profiles: <VpnProfile>[_profile('edge-a')],
      throttlePolicy: const TrafficThrottlePolicy(),
      options: const EndpointPoolOptions(
        healthCheck: VpnHealthCheckOptions(failoverOnNoTraffic: false),
      ),
    );

    expect(platform.writtenConfigs, isNotEmpty);
    expect(
      _mtuOf(platform.writtenConfigs.first),
      1100,
      reason: 'flutter_test reports the Android platform, whose shipped MTU is '
          '1100; resolving an unset tunMtu to the top probe candidate would '
          'silently move every Android install to 1400',
    );

    await vpn.dispose();
    await platform.dispose();
  });

  test('an explicitly configured MTU still reaches the config', () async {
    final platform = _CapturePlatform();
    SignboxVpnPlatform.instance = platform;
    final vpn = SignboxVpn();
    await vpn.initialize(const SingboxRuntimeOptions());

    await vpn.applyEndpointPool(
      profiles: <VpnProfile>[_profile('edge-a')],
      throttlePolicy: const TrafficThrottlePolicy(tunMtu: 1360),
      options: const EndpointPoolOptions(
        healthCheck: VpnHealthCheckOptions(failoverOnNoTraffic: false),
      ),
    );

    expect(_mtuOf(platform.writtenConfigs.first), 1360,
        reason: 'the knob must not have become decoration in the other '
            'direction');

    await vpn.dispose();
    await platform.dispose();
  });

  test('the app\'s own connect path keeps the platform default MTU', () async {
    // The path VpnController actually takes. It reaches `connectManualProfile`
    // rather than `applyEndpointPool`, so nothing seeds the MTU probe cursor
    // and the null-baseline guard in `_effectiveThrottlePolicyForProfile` does
    // fire — which is why this is green while the pool path above is not. Kept
    // as a separate test precisely because that difference is invisible from
    // the call site: the two entry points must not disagree about what an
    // unconfigured connect means.
    final platform = _CapturePlatform();
    SignboxVpnPlatform.instance = platform;
    final vpn = SignboxVpn();
    await vpn.initialize(const SingboxRuntimeOptions());

    await vpn.connectManualConfigLink(
      configLink: 'vless://11111111-2222-3333-4444-555555555555'
          '@de1.example.com:443?security=tls&type=tcp#DE-1',
      requestPermission: false,
    );

    expect(platform.writtenConfigs, isNotEmpty);
    expect(
      _mtuOf(platform.writtenConfigs.first),
      1100,
      reason: 'SingboxInboundBuilder.defaultTunMtu documents "Android keeps '
          '1100: that value is what the device testing behind the current '
          'release was done against" — either the preset must stop overriding '
          'it, or that promise is not being kept',
    );

    await vpn.dispose();
    await platform.dispose();
  });

  test('the probe candidate list ignores an unset baseline', () async {
    // A null tunMtu must not join the candidate set as a sentinel — the guard
    // against `indexOf(null) == -1` collapsing to the highest candidate.
    final platform = _CapturePlatform();
    SignboxVpnPlatform.instance = platform;
    final vpn = SignboxVpn();
    await vpn.initialize(const SingboxRuntimeOptions());

    await vpn.applyEndpointPool(
      profiles: <VpnProfile>[_profile('edge-a'), _profile('edge-b')],
      throttlePolicy: const TrafficThrottlePolicy(
        enableAutoMtuProbe: true,
        mtuProbeCandidates: <int>[1400, 1380, 1360],
      ),
      options: const EndpointPoolOptions(
        healthCheck: VpnHealthCheckOptions(failoverOnNoTraffic: false),
      ),
    );

    expect(_mtuOf(platform.writtenConfigs.first), 1100,
        reason: 'candidates exist, but none of them was asked for');

    await vpn.dispose();
    await platform.dispose();
  });
}
