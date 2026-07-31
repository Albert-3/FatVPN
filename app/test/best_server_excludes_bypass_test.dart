// "Best server" must not land on the panel's bypass hosts.
//
// The subscription carries two kinds of entry: real exits, grouped by country,
// and the flagless bucket the panel names "🌍 Белые списки #1" / "Авто 🔥
// [GRPC]" — fronted hosts meant for the case where the ordinary nodes are
// blocked. The automatic pick ranks by latency alone, and a fronted host
// answers a handshake from the nearest CDN edge, so it reliably beats a real
// exit on ping and used to win the automatic pick every time.

import 'dart:convert';

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
import 'package:fatvpn_app/utils/country_flag.dart';

import 'support/fake_vpn_platform.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

String _link(String host) =>
    'vless://$_uuid@$host:443?security=tls&type=tcp#$host';

ServerNode _node(String host) => ServerNode(
      id: 'node-$host',
      name: host,
      address: host,
      port: 443,
      usersOnline: null,
      configUri: _link(host),
    );

ServerCountry _country(String code, List<String> hosts) => ServerCountry(
      country: code,
      flag: code,
      nodeCount: hosts.length,
      nodes: hosts.map(_node).toList(),
    );

/// Ping service reading a fixed latency table; an absent host is unreachable.
class _FixedPingService extends PingService {
  _FixedPingService(this.latencyByAddress) : super(measureOutsideProcess: false);

  final Map<String, int?> latencyByAddress;
  final List<String> asked = <String>[];

  @override
  Future<int?> pingMs(String address, int port) async {
    asked.add(address);
    return latencyByAddress[address];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Nullable rather than `late`: the two pure-function tests below never call
  // [setUpWith], and a `late` field would make the shared tearDown throw for
  // them instead of simply having nothing to dispose.
  FakeVpnPlatform? platform;
  VpnController? vpn;
  late _FixedPingService pings;

  Future<void> setUpWith(
    List<ServerCountry> countries,
    Map<String, int?> latencies,
  ) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final fakePlatform = FakeVpnPlatform();
    platform = fakePlatform;
    SignboxVpnPlatform.instance = fakePlatform;
    pings = _FixedPingService(latencies);

    final hosts = countries.expand((c) => c.nodes).map((n) => n.address);
    final subscription =
        base64.encode(utf8.encode(hosts.map(_link).join('\n')));
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
    vpn?.dispose();
    platform?.dispose();
    vpn = null;
    platform = null;
  });

  group('autoPickCandidates', () {
    test('drops the bypass bucket', () {
      final servers = <ServerCountry>[
        _country('DE', <String>['de1.example.com']),
        _country(unknownCountryCode, <String>['bypass.example.com']),
        _country('NL', <String>['nl1.example.com']),
      ];

      expect(
        autoPickCandidates(servers).map((c) => c.country),
        <String>['DE', 'NL'],
      );
    });

    test('keeps it when it is the only thing on offer', () {
      // Refusing to connect at all would be worse than the bypass host, which
      // is exactly the situation those hosts exist for.
      final servers = <ServerCountry>[
        _country(unknownCountryCode, <String>['bypass.example.com']),
      ];

      expect(autoPickCandidates(servers), servers);
    });
  });

  test('the automatic pick ignores a bypass host that pings fastest', () async {
    final servers = <ServerCountry>[
      _country('DE', <String>['de1.example.com']),
      _country(unknownCountryCode, <String>['bypass.example.com']),
      _country('NL', <String>['nl1.example.com']),
    ];
    await setUpWith(servers, <String, int?>{
      'de1.example.com': 120,
      'bypass.example.com': 10, // a CDN edge always looks like the best server
      'nl1.example.com': 60,
    });

    final picked = await vpn!.connectToBestOverall(
      servers,
      networkErrorMessage: 'network',
    );

    expect(vpn!.connectedNode?.address, 'nl1.example.com');
    expect(picked?.country, 'NL');
    expect(pings.asked, isNot(contains('bypass.example.com')),
        reason: 'a node that can never be chosen should not be measured either');
  });

  test('a deliberate pick of the bypass bucket still connects to it', () async {
    // Excluded from "best server", not from the app: the location picker still
    // offers it, and choosing it must work.
    final bypass = _country(unknownCountryCode, <String>['bypass.example.com']);
    await setUpWith(
      <ServerCountry>[_country('DE', <String>['de1.example.com']), bypass],
      <String, int?>{'de1.example.com': 120, 'bypass.example.com': 10},
    );

    await vpn!.connectToBestNode(bypass, networkErrorMessage: 'network');

    expect(vpn!.connectedNode?.address, 'bypass.example.com');
  });

  test('with only bypass hosts left, the automatic pick uses one', () async {
    final servers = <ServerCountry>[
      _country(unknownCountryCode, <String>['bypass.example.com']),
    ];
    await setUpWith(servers, <String, int?>{'bypass.example.com': 10});

    final picked = await vpn!.connectToBestOverall(
      servers,
      networkErrorMessage: 'network',
    );

    expect(vpn!.connectedNode?.address, 'bypass.example.com');
    expect(picked?.country, unknownCountryCode);
  });
}
