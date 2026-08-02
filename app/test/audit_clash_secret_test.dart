// App-side half of docs/improvement-plan-app-android.md §1.6 —
// "Локальный clash-API открыт без секрета".
//
// `experimental.clash_api` binds 127.0.0.1:16756, and Android's loopback is not
// isolated between apps: any app holding INTERNET can read `GET /connections`
// (a live log of every domain the user visits) and `PATCH /configs` (turn
// proxying off). The plugin only emits the secret it is handed — see
// packages/singbox_mm/test/clash_api_secret_test.dart — so the app is what must
// produce one, freshly, per tunnel start.
//
// This test goes through the real connect path and inspects the config that
// actually reaches the platform.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/models/server_country.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/vpn_controller.dart';

import 'support/fake_vpn_platform.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';
const _host = 'de1.example.com';
const _link = 'vless://$_uuid@$_host:443?security=tls&type=tcp#DE-1';

const _country = ServerCountry(
  country: 'DE',
  flag: 'DE',
  nodeCount: 1,
  nodes: <ServerNode>[
    ServerNode(
      id: 'node-1',
      name: 'DE-1',
      address: _host,
      port: 443,
      usersOnline: null,
      configUri: _link,
    ),
  ],
);

Map? _clashApiOf(String? configJson) {
  if (configJson == null) return null;
  final config = jsonDecode(configJson) as Map<String, dynamic>;
  final experimental = config['experimental'];
  if (experimental is! Map) return null;
  final clash = experimental['clash_api'];
  return clash is Map ? clash : null;
}

String? _secretOf(String? configJson) =>
    _clashApiOf(configJson)?['secret'] as String?;

int? _portOf(String? configJson) {
  final controller = _clashApiOf(configJson)?['external_controller'] as String?;
  if (controller == null) return null;
  return int.tryParse(controller.split(':').last);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVpnPlatform platform;
  late VpnController vpn;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = FakeVpnPlatform();
    SignboxVpnPlatform.instance = platform;

    final subscription = base64.encode(utf8.encode(_link));
    final settings = ConnectionSettingsController();
    await settings.load();
    vpn = VpnController(
      connectionSettings: settings,
      apiClient: ApiClient(
        baseUrl: 'http://bff.test',
        httpClient: MockClient((request) async =>
            request.url.path == '/config'
                ? http.Response(subscription, 200)
                : http.Response('unexpected ${request.url}', 404)),
      ),
    );
  });

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  Future<String?> connectAndReadSecret() async {
    await vpn.connectToBestNode(_country,
        networkErrorMessage: 'network');
    return _secretOf(platform.capturedConfig);
  }

  test('the tunnel is started with a control-API secret', () async {
    final secret = await connectAndReadSecret();

    expect(secret, isNotNull,
        reason: 'an unauthenticated 127.0.0.1 controller hands every installed '
            'app the browsing log and a routing kill switch');
    expect(secret!.length, greaterThanOrEqualTo(16),
        reason: 'short enough to brute-force is the same as no secret');
  });

  test('every start gets a different secret', () async {
    final first = await connectAndReadSecret();
    await vpn.disconnect();
    final second = await connectAndReadSecret();

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second, isNot(first),
        reason: 'a secret that leaked (support bundle, shared log) must stop '
            'working at the next connect');
  });

  // docs/open-bugs.md 3.4. The secret keeps other apps from *reading* the
  // control API; it does nothing about the port itself, and a port that never
  // moves is a fingerprint — one connection attempt to 127.0.0.1:16756 tells
  // any app on the phone that this VPN is running, with no secret and no
  // permission beyond INTERNET.
  test('the control API does not listen on a well-known port', () async {
    await vpn.connectToBestNode(_country, networkErrorMessage: 'network');
    final port = _portOf(platform.capturedConfig);

    expect(port, isNotNull);
    expect(port, isNot(16756),
        reason: 'the port every previous build used is the one to move off');
    // The ephemeral range: what the OS hands out for port 0, and where a
    // listener is unremarkable.
    expect(port, greaterThan(1023));
    expect(port, lessThanOrEqualTo(65535));
  });

  test('every start gets a different port', () async {
    await vpn.connectToBestNode(_country, networkErrorMessage: 'network');
    final first = _portOf(platform.capturedConfig);
    await vpn.disconnect();
    await vpn.connectToBestNode(_country, networkErrorMessage: 'network');
    final second = _portOf(platform.capturedConfig);

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second, isNot(first),
        reason: 'a port fixed for the life of an install is still a '
            'fingerprint, just a per-install one');
  });
}
