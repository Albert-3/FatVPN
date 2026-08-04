// Two defects found on the emulator on 2026-08-03, both in what the app says
// about a session it did not personally start or stop.
//
//  1. The session clock counted time the VPN had been *off*. `_sessionStartedAt`
//     is persisted and used to be cleared only by `disconnect(endSession: true)`
//     — an in-app power-off. Every other way a tunnel ends (the widget's power
//     button, the notification's Stop, the app being killed, a reboot) left the
//     start on disk, and the next connect inherited it: a tunnel up for thirty
//     seconds was shown as `09:34:33`, then `04:41`, then `32:09`.
//
//  2. The connected node was lost with the process. Relaunching onto a live
//     tunnel — the ordinary end of a widget connect — left `connectedNode` null,
//     so the home screen, which follows the tunnel when no country was chosen,
//     fell back to "best server" while plainly connected to a specific country.
//
// Both are asserted through the real connect path; the stop that bypasses the
// app is played back the way the platform really delivers it, as a state
// broadcast from the tunnel service with no Dart call behind it.

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

const _uuid = '11111111-2222-3333-4444-555555555555';
const _host = 'fr1.example.com';
const _link = 'vless://$_uuid@$_host:443?security=tls&type=tcp#FR-1';

const _country = ServerCountry(
  country: 'FR',
  flag: 'FR',
  nodeCount: 1,
  nodes: <ServerNode>[
    ServerNode(
      id: 'node-fr-1',
      name: 'FR-1',
      address: _host,
      port: 443,
      usersOnline: null,
      configUri: _link,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVpnPlatform platform;
  late VpnController vpn;
  late ConnectionSettingsController settings;

  ApiClient newApiClient() {
    final subscription = base64.encode(utf8.encode(_link));
    return ApiClient(
      baseUrl: 'http://bff.test',
      httpClient: MockClient((request) async => request.url.path == '/config'
          ? http.Response(subscription, 200)
          : http.Response('unexpected ${request.url}', 404)),
    );
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = FakeVpnPlatform();
    SignboxVpnPlatform.instance = platform;
    settings = ConnectionSettingsController();
    await settings.load();
    vpn = VpnController(
      connectionSettings: settings,
      apiClient: newApiClient(),
    );
  });

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  Future<DateTime?> connect() async {
    await vpn.connectToBestNode(_country, networkErrorMessage: 'network');
    return vpn.sessionStartedAt;
  }

  /// The tunnel going down with nothing in Dart asking it to: the widget's
  /// power button and the notification's Stop both stop the service natively,
  /// and the app — running or not — only ever learns about it from the state
  /// broadcast this plays back.
  Future<void> stopFromOutsideTheApp() async {
    platform.reportedState = VpnConnectionState.disconnected;
    platform.states.add(VpnConnectionState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('a tunnel stopped from outside the app does not carry its clock into '
      'the next session', () async {
    final first = await connect();
    await stopFromOutsideTheApp();
    final second = await connect();

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second!.isAfter(first!), isTrue,
        reason: 'the previous session ended when the tunnel went down; a new '
            'connect that keeps its start counts the time the VPN was off — '
            'which is how a 30-second tunnel came to read 09:34:33');
  });

  test('a user power-off starts the next session from scratch', () async {
    final first = await connect();
    await vpn.disconnect();
    final second = await connect();

    expect(second!.isAfter(first!), isTrue);
  });

  test('a reconnect that is part of the same session keeps the clock', () async {
    final first = await connect();
    // What an auto-switch and a Settings change do: tear the tunnel down
    // declaring the session survives, then connect again.
    await vpn.disconnect(endSession: false);
    final second = await connect();

    expect(second, equals(first),
        reason: 'moving to a faster node, or re-applying DNS / split '
            'tunnelling, must not restart the timer the user is watching');
  });

  test('the connected node survives the process that started the tunnel',
      () async {
    await connect();
    expect(vpn.connectedNode?.id, 'node-fr-1');
    // Let the write-through land before the next process reads it.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // A fresh process over the same storage and the same live tunnel — what a
    // relaunch after a widget connect actually is.
    final relaunched = VpnController(
      connectionSettings: settings,
      apiClient: newApiClient(),
    );
    addTearDown(relaunched.dispose);
    platform.reportedState = VpnConnectionState.connected;
    await relaunched.syncFromRuntime();

    expect(relaunched.connectedNode?.id, 'node-fr-1',
        reason: 'without it the home screen shows "best server" while '
            'connected to a named country, and so does the widget');
    expect(relaunched.connectedNodeName, 'FR-1');
  });

  // Deliberately not tested here: that the restore *notifies* listeners.
  //
  // The real condition is `getState()` answering `connected` when the stream
  // has already settled the controller there — then the reconciliation finds no
  // state change and, without an explicit notify, the restored node reaches the
  // location card only when some unrelated event happens to fire. Against this
  // fake the state always changes, so the state-change notify covers for the
  // missing one and any such test passes with the fix removed. A green test
  // that cannot fail is worse than no test: it reads as a guarantee. Verified
  // on a device instead (docs/release-test-checklist.md, TA20).

  test('a power-off keeps the stored node — the snapshot it describes stays',
      () async {
    // Changed 2026-08-04 with the snapshot itself: an off-switch no longer
    // wipes the persisted tunnel state, because the iOS widget's native start
    // rides it — and any tunnel raised without the app after a power-off runs
    // the snapshot's config, i.e. exactly the node this label names. The
    // mislabeling the old test guarded against needs a *different* config,
    // which only an in-app connect can install — and it overwrites the label.
    await connect();
    await vpn.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final relaunched = VpnController(
      connectionSettings: settings,
      apiClient: newApiClient(),
    );
    addTearDown(relaunched.dispose);
    platform.reportedState = VpnConnectionState.connected;
    await relaunched.syncFromRuntime();

    expect(relaunched.connectedNode?.id, 'node-fr-1',
        reason: 'a widget start after a power-off raises the snapshot config, '
            'and the label must name the node that config is on');
  });

  test('the stored node is dropped with the session it belonged to', () async {
    await connect();
    await vpn.disconnect();
    // Session death (sign-out / 401 / 402) is what erases — see
    // HomeScreen._stopTunnelOnSignOut and stopAndForgetStandalone.
    await vpn.forgetPersistedTunnelState();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final relaunched = VpnController(
      connectionSettings: settings,
      apiClient: newApiClient(),
    );
    addTearDown(relaunched.dispose);
    // A tunnel the OS raised on its own after the user had signed off would be
    // a bug of its own; what must not happen is the *label* outliving the
    // session and naming a country for a tunnel that is not this one.
    platform.reportedState = VpnConnectionState.connected;
    await relaunched.syncFromRuntime();

    expect(relaunched.connectedNode, isNull,
        reason: 'a dead session wipes the tunnel state, and the node it was '
            'on is part of that state');
  });
}
