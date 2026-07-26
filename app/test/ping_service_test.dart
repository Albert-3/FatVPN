import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:singbox_mm/singbox_mm.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/services/ping_service.dart';

/// Stands in for the plugin. Only [pingServerOutsideTunnel] is exercised — the
/// base class leaves every other member throwing, which is what we want: a call
/// to anything else should fail the test loudly rather than pass silently.
class _FakePlatform extends SignboxVpnPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({this.answer, this.throwError = false});

  final VpnPingResult? answer;
  final bool throwError;
  int calls = 0;
  String? lastHost;
  int? lastPort;

  @override
  Future<VpnPingResult> pingServerOutsideTunnel({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    calls++;
    lastHost = host;
    lastPort = port;
    if (throwError) throw MissingPluginException('no implementation');
    return answer!;
  }
}

void main() {
  // 127.0.0.1:1 refuses immediately, so the in-app fallback resolves fast and
  // without touching the network.
  const deadHost = '127.0.0.1';
  const deadPort = 1;

  test('takes the extension measurement when it answers', () async {
    final platform = _FakePlatform(
      answer: VpnPingResult(
        host: 'de1.example.com',
        port: 443,
        latency: const Duration(milliseconds: 42),
        checkedAt: DateTime.now(),
      ),
    );
    final service = PingService(platform: platform, measureOutsideProcess: true);

    expect(await service.pingMs('de1.example.com', 443), 42);
    expect(platform.calls, 1);
    expect(platform.lastHost, 'de1.example.com');
    expect(platform.lastPort, 443);
  });

  test('reports unreachable when the extension says the handshake failed', () async {
    // The extension tried and got nothing. That is an answer about the node,
    // so it must not be second-guessed by a measurement through the tunnel.
    final platform = _FakePlatform(
      answer: VpnPingResult.failure(
        host: 'de1.example.com',
        port: 443,
        error: 'Ping timed out',
      ),
    );
    final service = PingService(platform: platform, measureOutsideProcess: true);

    expect(await service.pingMs('de1.example.com', 443), isNull);
  });

  test('falls back in-app when the extension cannot be asked', () async {
    final platform = _FakePlatform(throwError: true);
    final service = PingService(platform: platform, measureOutsideProcess: true);

    // Falls through to a direct connect, which this address refuses — the point
    // is that it measured rather than propagating the plugin failure.
    expect(await service.pingMs(deadHost, deadPort), isNull);
    expect(platform.calls, 1);
  });

  test('never asks the extension where the app is not captured', () async {
    final platform = _FakePlatform(throwError: true);
    final service = PingService(platform: platform, measureOutsideProcess: false);

    expect(await service.pingMs(deadHost, deadPort), isNull);
    expect(platform.calls, 0, reason: 'Android measures directly');
  });
}
