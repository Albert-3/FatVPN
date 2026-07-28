// Regression tests for docs/improvement-plan-ios.md V24 — a flipped
// auto-reconnect / kill-switch reached the VPN profile only at the *next
// manual connect*, and flipping either on a live tunnel tore the session.
//
// Both halves matter. The profile half: after a jetsam kill the profile still
// said `onDemand = true`, so the user unchecked the box and the OS went on
// resurrecting the tunnel — the manual connect that was the only thing
// writing the profile might never come. The session half: these two live in
// the OS profile, not in the sing-box config, so a reconnect for them tears a
// live session for a setting the tunnel doesn't read.
//
// [VpnController.applyTunnelPreferences] is the new direct push; HomeScreen
// routes preference flips to it (and only real config changes to the
// reconnect debounce).

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

const _link = 'vless://11111111-2222-3333-4444-555555555555'
    '@de1.example.com:443?security=tls&type=tcp#DE-1';

const _country = ServerCountry(
  country: 'DE',
  flag: 'DE',
  nodeCount: 1,
  nodes: <ServerNode>[
    ServerNode(
      id: 'node-1',
      name: 'DE-1',
      address: 'de1.example.com',
      port: 443,
      usersOnline: null,
      configUri: _link,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVpnPlatform platform;
  late ConnectionSettingsController settings;
  late VpnController vpn;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = FakeVpnPlatform();
    SignboxVpnPlatform.instance = platform;
    settings = ConnectionSettingsController();
    await settings.load();
    vpn = VpnController(
      connectionSettings: settings,
      apiClient: ApiClient(
        baseUrl: 'http://bff.test',
        httpClient: MockClient((request) async =>
            request.url.path == '/config'
                ? http.Response(base64.encode(utf8.encode(_link)), 200)
                : http.Response('unexpected ${request.url}', 404)),
      ),
    );
  });

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  test('applyTunnelPreferences pushes without touching the tunnel', () async {
    await vpn.connectToBestNode(_country, networkErrorMessage: 'network');
    final startsBefore = platform.startVpnCalls;
    final pushesBefore = platform.tunnelPreferences.length;

    await settings.setAutoReconnect(true);
    await vpn.applyTunnelPreferences();

    expect(platform.tunnelPreferences.length, pushesBefore + 1);
    expect(platform.tunnelPreferences.last.onDemand, isTrue);
    expect(platform.startVpnCalls, startsBefore,
        reason: 'the preference lives in the OS profile, not in the config — '
            'a reconnect for it tears a live session for nothing');
  });

  test('the push works with the tunnel down — the jetsam scenario', () async {
    // No connect at all: the profile may still say onDemand=true from an
    // earlier session the OS keeps resurrecting.
    await settings.setAutoReconnect(false);
    await settings.setKillSwitch(false);

    await vpn.applyTunnelPreferences();

    expect(platform.tunnelPreferences, isNotEmpty,
        reason: 'waiting for the next manual connect is exactly the bug: '
            'with on-demand still true in the profile it may never come');
    expect(platform.tunnelPreferences.last.onDemand, isFalse);
    expect(platform.tunnelPreferences.last.killSwitch, isFalse);
  });

  test('a platform refusal is a log line, not an error', () async {
    platform.setTunnelPreferencesThrows = true;

    await expectLater(vpn.applyTunnelPreferences(), completes);
  });
}
