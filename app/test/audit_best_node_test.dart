// Regression test for docs/improvement-plan-app-android.md §3.2 —
// "Выбор лучшей ноды — строго последовательный пинг".
//
// `_pickBestNode` awaits inside a `for` loop with a 3 s per-ping timeout, and it
// sits on the path of *every* Connect tap. In "Best server" mode the candidate
// list is every node of every country, so a subscription with 20 nodes of which
// 5 are unreachable spends 15 s in pings alone. The same measurement is already
// done with `Future.wait` in `_evaluateAutoSwitch` and in HomeScreen — the
// pattern exists, it is just not applied in the hottest place.
//
// §3.9 asks for the parallelism to be *bounded* (6-8 sockets), because firing
// 40 simultaneous `Socket.connect`s on mobile radio distorts the very numbers
// being measured.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/models/server_country.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/ping_service.dart';
import 'package:fatvpn_app/services/vpn_controller.dart';

import 'support/fake_vpn_platform.dart';

/// Ping service that records how many measurements are in flight at once.
class _ConcurrencyPingService extends PingService {
  _ConcurrencyPingService(this.latencyByAddress)
      : super(measureOutsideProcess: false);

  final Map<String, int?> latencyByAddress;
  final List<String> asked = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<int?> pingMs(String address, int port) async {
    asked.add(address);
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    inFlight--;
    return latencyByAddress[address];
  }
}

const _uuid = '11111111-2222-3333-4444-555555555555';

String _link(String host) => 'vless://$_uuid@$host:443?security=tls&type=tcp#$host';

ServerNode _node(int i) {
  final host = 'n$i.example.com';
  return ServerNode(
    id: 'node-$i',
    name: 'Node $i',
    address: host,
    port: 443,
    usersOnline: null,
    configUri: _link(host),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVpnPlatform platform;
  late _ConcurrencyPingService pings;
  late VpnController vpn;
  late List<ServerNode> nodes;

  Future<void> setUpWith(int nodeCount, Map<String, int?> latencies) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = FakeVpnPlatform();
    SignboxVpnPlatform.instance = platform;
    nodes = List<ServerNode>.generate(nodeCount, _node);
    pings = _ConcurrencyPingService(latencies);

    final subscription =
        base64.encode(utf8.encode(nodes.map((n) => _link(n.address)).join('\n')));
    final api = ApiClient(
      baseUrl: 'http://bff.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/config') {
          return http.Response(subscription, 200);
        }
        return http.Response('unexpected ${request.url}', 404);
      }),
    );

    final settings = ConnectionSettingsController();
    await settings.load();
    vpn = VpnController(
      connectionSettings: settings,
      apiClient: api,
      pingService: pings,
    );
  }

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  test('candidates are measured concurrently, not one after another', () async {
    await setUpWith(6, <String, int?>{
      'n0.example.com': 200,
      'n1.example.com': 150,
      'n2.example.com': null, // unreachable
      'n3.example.com': 40,
      'n4.example.com': 90,
      'n5.example.com': null,
    });

    final started = DateTime.now();
    try {
      await vpn.connectToBestNode(
        ServerCountry(country: 'DE', flag: 'DE', nodeCount: nodes.length, nodes: nodes),
        networkErrorMessage: 'network',
      );
    } catch (_) {
      // The connect itself is not what this test is about; the pings happen
      // before it and are already recorded.
    }
    final elapsed = DateTime.now().difference(started);

    expect(pings.asked.toSet(), hasLength(6),
        reason: 'every candidate must still be measured');
    expect(pings.maxInFlight, greaterThan(1),
        reason: 'sequential pings cost 3 s per unreachable node on the path of '
            'every Connect tap');
    expect(elapsed.inMilliseconds, lessThan(6 * 40),
        reason: '6 x 40 ms sequentially would be 240 ms');
  });

  test('parallelism is bounded so 20 nodes do not open 20 sockets at once',
      () async {
    await setUpWith(20, <String, int?>{
      for (var i = 0; i < 20; i++) 'n$i.example.com': 100 + i,
    });

    try {
      await vpn.connectToBestNode(
        ServerCountry(country: 'DE', flag: 'DE', nodeCount: nodes.length, nodes: nodes),
        networkErrorMessage: 'network',
      );
    } catch (_) {}

    expect(pings.maxInFlight, greaterThan(1));
    expect(pings.maxInFlight, lessThanOrEqualTo(8),
        reason: '§3.9 — a burst of simultaneous connects distorts the very '
            'latencies being measured, and looks like a port scan to some NATs');
  });

  test('the fastest reachable candidate wins', () async {
    await setUpWith(4, <String, int?>{
      'n0.example.com': 200,
      'n1.example.com': null,
      'n2.example.com': 35, // fastest
      'n3.example.com': 120,
    });

    await vpn.connectToBestNode(
      ServerCountry(country: 'DE', flag: 'DE', nodeCount: nodes.length, nodes: nodes),
      networkErrorMessage: 'network',
    );

    expect(vpn.connectedNode?.address, 'n2.example.com');
  });
}
