// Regression tests for docs/improvement-plan-ios.md §1.3 (no on-demand rules /
// no kill switch) and §1.6 + §2.1 (the persisted start-options snapshot is
// never erased).
//
// §1.3: `isOnDemandEnabled` / `onDemandRules` were set nowhere in the repo, so
// a network extension killed by jetsam — which §3.1/§3.2 make likely — was
// never restarted by iOS. The user kept an app that said "connected" and
// traffic that went out in the clear until they next opened it.
//
// §1.6/§2.1: `start_options.plist` holds the whole config, credentials
// included, and `resolveStartOptions` falls back to it whenever iOS brings the
// extension up without options. Nothing deleted it, so a logout, an expired
// subscription or a server change could be followed by the OS silently
// reconnecting to the old node on credentials the panel had revoked.
//
// Both are Swift-side fixes, but they are driven from Dart — which is the part
// a host test run can hold to account.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:singbox_mm/singbox_mm.dart';
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

    final subscription = base64.encode(utf8.encode(_link));
    settings = ConnectionSettingsController();
    await settings.load();
    vpn = VpnController(
      connectionSettings: settings,
      apiClient: ApiClient(
        baseUrl: 'http://bff.test',
        httpClient: MockClient((request) async => request.url.path == '/config'
            ? http.Response(subscription, 200)
            : http.Response('unexpected ${request.url}', 404)),
      ),
    );
  });

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  Future<void> connect() =>
      vpn.connectToBestNode(_country, networkErrorMessage: 'network');

  group('§1.3 the OS is told how to treat the tunnel', () {
    test('connecting pushes the on-demand and kill-switch preferences',
        () async {
      await connect();

      expect(platform.tunnelPreferences, isNotEmpty,
          reason: 'without an on-demand rule iOS never restarts an extension '
              'it killed, and the user is left unprotected without being told');
    });

    test('the preferences are written before the tunnel starts', () async {
      await connect();

      final prefsAt = platform.callOrder.indexOf('setTunnelPreferences');
      final startAt = platform.callOrder.indexOf('startVpn');

      expect(prefsAt, isNonNegative);
      expect(startAt, isNonNegative);
      expect(prefsAt, lessThan(startAt),
          reason: 'the platform writes these into the VPN profile at start; '
              'pushing them afterwards leaves the running session governed by '
              'the previous values');
    });

    test('the user\'s own choices are what get pushed', () async {
      await settings.setAutoReconnect(true);
      await settings.setKillSwitch(true);

      await connect();

      expect(platform.tunnelPreferences.last.onDemand, isTrue);
      expect(platform.tunnelPreferences.last.killSwitch, isTrue);
    });

    test('both default to off, and a switch-off reaches the platform',
        () async {
      await connect();
      expect(platform.tunnelPreferences.last.onDemand, isFalse);
      expect(platform.tunnelPreferences.last.killSwitch, isFalse);

      await settings.setAutoReconnect(true);
      await vpn.disconnect();
      await connect();
      expect(platform.tunnelPreferences.last.onDemand, isTrue);

      await settings.setAutoReconnect(false);
      await vpn.disconnect();
      await connect();
      expect(platform.tunnelPreferences.last.onDemand, isFalse,
          reason: 'a kill switch or an auto-reconnect the user turned off but '
              'that stays in the VPN profile is the worse half of this bug: '
              'the OS keeps re-establishing a tunnel they ended');
    });
  });

  group('a platform failure costs the preference, not the connection', () {
    // `_invokeOptional` no longer swallows PlatformException — only
    // MissingPluginException, which is how a platform that simply has no such
    // feature answers. That makes a genuine failure visible, so the connect
    // path has to decide what to do with it: refusing to connect because the
    // kill-switch preference could not be written would be a far worse trade
    // than connecting without it.
    test('a failing setTunnelPreferences does not abort the connect', () async {
      platform.setTunnelPreferencesThrows = true;

      await expectLater(connect(), completes);

      expect(platform.startVpnCalls, greaterThanOrEqualTo(1),
          reason: 'the tunnel must still come up');
      expect(platform.capturedConfig, isNotNull);
    });

    test('the failure is not silent — the attempt is still recorded', () async {
      platform.setTunnelPreferencesThrows = true;

      await connect();

      expect(platform.tunnelPreferences, isNotEmpty,
          reason: 'the call is made and fails, rather than being skipped');
    });

    test('the guard is narrow: a real connect failure still surfaces',
        () async {
      // The try/catch must wrap only the preferences call. If it were widened
      // to cover the connect itself, every tunnel failure would be downgraded
      // to a log line and the user would see a green toggle over nothing.
      platform.setConfigThrows = true;

      await expectLater(connect(), throwsA(isA<Exception>()),
          reason: 'a config the platform refuses is a failed connect; it must '
              'propagate, not be logged and walked past like the preferences');
      expect(vpn.errorMessage, isNotNull);
      expect(vpn.state, VpnConnectionState.error,
          reason: 'the user has to be told, rather than shown a green toggle '
              'over a tunnel that never came up');
    });
  });

  group('§1.6 / §2.1 the persisted snapshot is erased when the session ends',
      () {
    test('ending the session clears the platform state', () async {
      await connect();

      await vpn.disconnect();

      expect(platform.clearPersistedStateCalls, greaterThanOrEqualTo(1),
          reason: 'the start-options snapshot is what the OS would reconnect '
              'from — on credentials that may since have been revoked');
    });

    test('a mere reconnect does not clear it', () async {
      // Switching servers tears the tunnel down with endSession: false; wiping
      // the snapshot there would defeat on-demand recovery mid-session.
      await connect();

      await vpn.disconnect(endSession: false);

      expect(platform.clearPersistedStateCalls, 0);
    });

    test('a platform that refuses to clear does not break sign-out', () async {
      await connect();
      platform.clearPersistedStateThrows = true;

      await expectLater(vpn.disconnect(), completes);
      expect(platform.clearPersistedStateCalls, greaterThanOrEqualTo(1));
    });

    test('the control-API secret is dropped along with the tunnel state',
        () async {
      await connect();
      final storage = const FlutterSecureStorage();
      expect(await storage.read(key: 'vpn_clash_api_secret'), isNotNull);

      await vpn.disconnect();

      expect(await storage.read(key: 'vpn_clash_api_secret'), isNull,
          reason: 'a secret kept past the session it belonged to is a secret '
              'in a support bundle with nothing left to protect');
    });
  });

  group('the wipe never lands inside the connect it would disarm', () {
    // A connect takes seconds; the home screen reads `connecting` as "on", so a
    // second tap on the power button is a disconnect and the two run at once.
    // The disconnect's wipe erases the config the connect is about to start
    // from, and iOS then answers "Config is missing. Call setConfig() first." —
    // an error message for a session the user themselves cancelled.
    test('a disconnect mid-connect does not fail the connect', () async {
      platform.setConfigReached = Completer<void>();
      platform.holdAfterSetConfig = Completer<void>();

      final connecting = connect();
      await platform.setConfigReached!.future;

      // The second tap, landing squarely in the window.
      final disconnecting = vpn.disconnect();
      platform.holdAfterSetConfig!.complete();

      await expectLater(connecting, completes,
          reason: 'the cancelled connect must not surface as a platform error');
      await disconnecting;

      expect(vpn.errorMessage, isNull);
    });

    test('the cancelled session is still torn down, wipe included', () async {
      platform.setConfigReached = Completer<void>();
      platform.holdAfterSetConfig = Completer<void>();

      final connecting = connect();
      await platform.setConfigReached!.future;
      final disconnecting = vpn.disconnect();
      platform.holdAfterSetConfig!.complete();
      await connecting;
      await disconnecting;

      expect(vpn.isConnected, isFalse,
          reason: 'the user asked for the VPN to be off; a connect that landed '
              'after that request must not leave them on it');
      expect(platform.clearPersistedStateCalls, greaterThanOrEqualTo(1),
          reason: 'deferring the wipe must not mean skipping it — the config '
              'and the start-options snapshot still have to go');
      expect(platform.callOrder.indexOf('clearPersistedState'),
          greaterThan(platform.callOrder.indexOf('startVpn')),
          reason: 'the wipe belongs after the start it would otherwise disarm');
    });

    test('a failed connect still honours the deferred wipe', () async {
      platform.setConfigReached = Completer<void>();
      platform.holdAfterSetConfig = Completer<void>();

      final connecting = connect();
      await platform.setConfigReached!.future;
      platform.setConfigThrows = true;
      final disconnecting = vpn.disconnect();
      platform.holdAfterSetConfig!.complete();

      await expectLater(connecting, throwsA(isA<Exception>()));
      await disconnecting;
      // The deferral is dispatched from the connect's `finally`, so let the
      // microtask carrying it run.
      await Future<void>.delayed(Duration.zero);

      expect(platform.clearPersistedStateCalls, greaterThanOrEqualTo(1),
          reason: 'a cancelled connect that also failed must not leave the '
              'subscription on disk');
    });
  });
}
