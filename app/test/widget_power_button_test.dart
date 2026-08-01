// The widget's power button: the tap that connects (or disconnects) without
// opening the app, and everything the app needs to know about it.
//
// Covered here, in the order the feature is used:
//   · an action the platform parked for us (the iOS App Intent path, which has
//     no URL to deep-link with) is collected and understood;
//   · the country the user picked is remembered on disk, because the widget
//     connects with no UI in the process and that record is all it has to go on
//     — and its absence is what "connect to the best server" means;
//   · signing out drops that record along with the session;
//   · the background connect ([WidgetConnectRunner]) hands over to the app in
//     exactly the cases only a screen can answer, and otherwise connects.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:singbox_mm/singbox_mm.dart';

import 'package:fatvpn_app/models/auth_session.dart';
import 'package:fatvpn_app/models/server_country.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/home_widget_bridge.dart';
import 'package:fatvpn_app/services/selected_location_store.dart';
import 'package:fatvpn_app/services/token_storage.dart';
import 'package:fatvpn_app/services/vpn_controller.dart';
import 'package:fatvpn_app/services/widget_connect_runner.dart';

final _serversBody = jsonEncode(<Object?>[
  <String, Object?>{
    'country': 'DE',
    'flag': 'DE',
    'nodeCount': 1,
    'nodes': <Object?>[
      <String, Object?>{
        'id': 'n1',
        'name': 'DE-1',
        'address': 'de1.example.com',
        'port': 2222,
        'usersOnline': 3,
      },
    ],
  },
  <String, Object?>{
    'country': 'NL',
    'flag': 'NL',
    'nodeCount': 1,
    'nodes': <Object?>[
      <String, Object?>{
        'id': 'n2',
        'name': 'NL-1',
        'address': 'nl1.example.com',
        'port': 2222,
        'usersOnline': 1,
      },
    ],
  },
]);

/// A VpnController that records what it was asked to connect to instead of
/// bringing a tunnel up. Only the two connect entry points are replaced — the
/// runner is what is under test, not the tunnel.
class _RecordingVpn extends VpnController {
  _RecordingVpn(ConnectionSettingsController settings)
      : super(connectionSettings: settings);

  String? connectedCountry;
  bool connectedToBestOverall = false;

  /// Thrown out of both connect paths when set — how the plugin reports a
  /// permission it cannot ask for, and a tunnel that would not start.
  SignboxVpnException? failWith;

  @override
  VpnConnectionState get state => VpnConnectionState.connected;

  @override
  DateTime? get sessionStartedAt => DateTime.fromMillisecondsSinceEpoch(1700000000000);

  @override
  Future<void> connectToBestNode(
    ServerCountry country, {
    required String networkErrorMessage,
  }) async {
    connectedCountry = country.country;
  }

  @override
  Future<ServerCountry?> connectToBestOverall(
    List<ServerCountry> countries, {
    required String networkErrorMessage,
  }) async {
    final failure = failWith;
    if (failure != null) throw failure;
    connectedToBestOverall = true;
    connectedCountry = countries.first.country;
    return countries.first;
  }
}

WidgetConnectRunner _runner({
  required http.Client client,
  required _RecordingVpn vpn,
  required ConnectionSettingsController settings,
}) {
  return WidgetConnectRunner(
    apiClient: ApiClient(baseUrl: 'http://bff.test', httpClient: client),
    connectionSettings: settings,
    buildVpn: (_, _) => vpn,
  );
}

/// A BFF that answers `/servers` with [servers] and refuses `/config`, which
/// sends `getUsableServers` down its documented fallback (the raw server list).
MockClient _bff({int serversStatus = 200}) {
  return MockClient((request) async {
    if (request.url.path == '/servers') {
      return http.Response(
        serversStatus == 200 ? _serversBody : '{}',
        serversStatus,
      );
    }
    if (request.url.path == '/config') return http.Response('nope', 500);
    return http.Response('not found', 404);
  });
}

Future<void> _storeSession({required Duration expiresIn}) async {
  await TokenStorage().save(AuthSession(
    accessToken: 'access',
    refreshToken: 'refresh',
    expiresAt: DateTime.now().add(expiresIn),
    accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 20)),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('homeWidgetActionFromName', () {
    test('understands the three actions and nothing else', () {
      expect(homeWidgetActionFromName('connect'), HomeWidgetAction.connect);
      expect(homeWidgetActionFromName('disconnect'), HomeWidgetAction.disconnect);
      expect(homeWidgetActionFromName('toggle'), HomeWidgetAction.toggle);
      // Not an action: it opens the app and does nothing, which is what a tap
      // outside the power button does.
      expect(homeWidgetActionFromName('open'), isNull);
      expect(homeWidgetActionFromName(''), isNull);
    });
  });

  group('HomeWidgetBridge.takePendingAction', () {
    setUp(() => HomeWidgetBridge.instance.resetForTest());
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, null);
      HomeWidgetBridge.instance.resetForTest();
    });

    test('collects what the platform parked', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async {
        return call.method == 'takePendingAction' ? 'toggle' : null;
      });

      expect(
        await HomeWidgetBridge.instance.takePendingAction(),
        HomeWidgetAction.toggle,
      );
    });

    test('an empty mailbox is not an action', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async => null);

      expect(await HomeWidgetBridge.instance.takePendingAction(), isNull);
    });

    test('a platform that does not know the call still gets snapshots',
        () async {
      // The regression this guards: answering `takePendingAction` with a
      // MissingPluginException must not be read as "this platform has no widget
      // support at all", which would stop the app publishing snapshots — a far
      // bigger loss than a tap that has to arrive by deep link instead.
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'takePendingAction') {
          throw MissingPluginException('older platform build');
        }
        return null;
      });

      expect(await HomeWidgetBridge.instance.takePendingAction(), isNull);
      await HomeWidgetBridge.instance.update(state: VpnConnectionState.connected);

      expect(calls.map((c) => c.method), ['takePendingAction', 'publish']);
    });
  });

  group('SelectedLocationStore', () {
    test('a fresh install has chosen nothing — which means "best server"',
        () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      expect(await SelectedLocationStore().read(), isNull);
    });

    test('remembers a country and forgets it again', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = SelectedLocationStore();
      await store.write('NL');
      expect(await store.read(), 'NL');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('signing out drops it with the session', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      await SelectedLocationStore().write('DE');
      await _storeSession(expiresIn: const Duration(days: 30));

      await TokenStorage().clear();

      // Not a secret, but it is a fact about an account that no longer has a
      // session on this phone — and the widget would otherwise offer to
      // reconnect the next user straight to it.
      expect(await SelectedLocationStore().read(), isNull);
      expect(await TokenStorage().read(), isNull);
    });
  });

  group('WidgetConnectRunner', () {
    late ConnectionSettingsController settings;
    late _RecordingVpn vpn;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      HomeWidgetBridge.instance.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async => null);
      settings = ConnectionSettingsController();
      vpn = _RecordingVpn(settings);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, null);
      HomeWidgetBridge.instance.resetForTest();
    });

    test('with no stored session, the app has to take over', () async {
      final outcome = await _runner(
        client: _bff(),
        vpn: vpn,
        settings: settings,
      ).run();

      expect(outcome, WidgetConnectOutcome.handOverToApp);
      expect(vpn.connectedCountry, isNull);
    });

    test('a lapsed subscription is the renew screen\'s business, not ours',
        () async {
      await _storeSession(expiresIn: const Duration(days: -1));

      final outcome = await _runner(
        client: _bff(),
        vpn: vpn,
        settings: settings,
      ).run();

      expect(outcome, WidgetConnectOutcome.handOverToApp);
      // Never even asked: a tunnel must not come up on a subscription that is
      // over, which is the whole reason this does not start from the config
      // left on disk.
      expect(vpn.connectedCountry, isNull);
    });

    test('a 402 from the panel hands over too', () async {
      await _storeSession(expiresIn: const Duration(days: 30));

      final outcome = await _runner(
        client: _bff(serversStatus: 402),
        vpn: vpn,
        settings: settings,
      ).run();

      expect(outcome, WidgetConnectOutcome.handOverToApp);
      expect(vpn.connectedCountry, isNull);
    });

    test('with no country ever chosen it connects to the best server overall',
        () async {
      await _storeSession(expiresIn: const Duration(days: 30));

      final outcome = await _runner(
        client: _bff(),
        vpn: vpn,
        settings: settings,
      ).run();

      expect(outcome, WidgetConnectOutcome.connected);
      expect(vpn.connectedToBestOverall, isTrue);
    });

    test(
        'the in-app country choice is ignored — a widget press always takes '
        'the best server (user decision, 2026-08-01)', () async {
      await _storeSession(expiresIn: const Duration(days: 30));
      await SelectedLocationStore().write('NL');

      final outcome = await _runner(
        client: _bff(),
        vpn: vpn,
        settings: settings,
      ).run();

      expect(outcome, WidgetConnectOutcome.connected);
      expect(vpn.connectedToBestOverall, isTrue);
      // The pick itself must survive for the app's own use.
      expect(await SelectedLocationStore().read(), 'NL');
    });

    test('a permission the plugin cannot ask for goes to the app', () async {
      await _storeSession(expiresIn: const Duration(days: 30));
      // What the first connect on a device looks like from here: the OS wants
      // to show its VPN consent dialog and there is no Activity to show it in.
      vpn.failWith = const SignboxVpnException(
        code: 'NO_ACTIVITY',
        message: 'An Activity is required to request VPN permission',
      );

      final outcome = await _runner(
        client: _bff(),
        vpn: vpn,
        settings: settings,
      ).run();

      expect(outcome, WidgetConnectOutcome.handOverToApp);
    });

    test('a tunnel that simply would not start does not open the app', () async {
      await _storeSession(expiresIn: const Duration(days: 30));
      vpn.failWith = const SignboxVpnException(
        code: 'START_FAILED',
        message: 'tunnel died',
      );

      final outcome = await _runner(
        client: _bff(),
        vpn: vpn,
        settings: settings,
      ).run();

      // The user asked for a tunnel, not for an app to be opened at them.
      expect(outcome, WidgetConnectOutcome.failed);
    });

  });
}
