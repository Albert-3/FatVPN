// The employer's report (2026-07-29): "there is no refresh-servers button".
// Home had none — only a "Retry" link inside the error row, and that one
// called `_loadServers()` without `force`, so within the 5-minute client cache
// (`ApiClient._cacheTtl`, six times the BFF's own 45 s) a tap sent nothing at
// all and looked broken.
//
// Pinned here on the booted app, not on a controller: the header carries a
// refresh button, and pressing it reaches the network over a warm cache.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/main.dart';
import 'package:fatvpn_app/screens/home_screen.dart';

import 'support/fake_vpn_platform.dart';
import 'support/no_network_http.dart';

void _stubPlatformChannels(WidgetTester tester) {
  void stub(String name, Object? reply) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => reply);
  }

  stub('com.llfbandit.app_links/messages', null);
  stub('com.llfbandit.app_links/events', null);
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  stub('dexterous.com/flutter/local_notifications', true);
}

/// A live subscription, resolved without any network call — see widget_test.
Map<String, String> _storedSession() => <String, String>{
      'access_token': 'stored-access-token',
      'refresh_token': '',
      'access_token_expires_at':
          DateTime.now().add(const Duration(days: 30)).toIso8601String(),
      'access_jwt_expires_at':
          DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
    };

/// One country, enough for `/servers` to parse and be cached. `/config` gets
/// the same body, fails to parse, and falls back to this list — which is the
/// documented behaviour of `getUsableServers`, not an accident of the stub.
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
]);

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration budget = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 100),
}) async {
  var elapsed = Duration.zero;
  while (elapsed < budget) {
    if (condition()) return;
    await tester.pump(step);
    elapsed += step;
  }
}

void main() {
  late FakeVpnPlatform vpnPlatform;
  late NoNetworkHttpOverrides network;
  HttpOverrides? previousOverrides;

  setUp(() {
    vpnPlatform = FakeVpnPlatform(initializeDelay: Duration.zero);
    SignboxVpnPlatform.instance = vpnPlatform;

    previousOverrides = HttpOverrides.current;
    network = NoNetworkHttpOverrides(statusCode: 200, body: _serversBody);
    HttpOverrides.global = network;
  });

  tearDown(() {
    HttpOverrides.global = previousOverrides;
    vpnPlatform.dispose();
  });

  testWidgets('the home header refreshes the server list over a warm cache',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(_storedSession());
    _stubPlatformChannels(tester);

    await tester.pumpWidget(const FatVpnApp());
    await _pumpUntil(tester, () => find.byType(HomeScreen).evaluate().isNotEmpty);

    final refresh = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.widgetWithIcon(IconButton, Icons.refresh),
    );
    expect(refresh, findsOneWidget,
        reason: 'the home header must carry a refresh button');

    // The list loads once on its own, and the button stays disabled until it
    // finishes; everything after that is the user asking.
    await _pumpUntil(
        tester, () => tester.widget<IconButton>(refresh).onPressed != null);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull,
        reason: 'the button must come back once the first load settles');
    final beforeTap =
        network.requests.where((r) => r.contains('/servers')).length;
    expect(beforeTap, 1, reason: 'the automatic first load should have run');

    await tester.tap(refresh);
    await _pumpUntil(
        tester,
        () =>
            network.requests.where((r) => r.contains('/servers')).length >
            beforeTap);

    expect(network.requests.where((r) => r.contains('/servers')).length,
        greaterThan(beforeTap),
        reason: 'the tap must reach the network — the client cache is still '
            'warm, so a request that is not forced would be answered from it');

    await tester.pump(const Duration(seconds: 3)); // AppLogger's flush timer
  });
}
