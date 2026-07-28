// Boot smoke test for the app shell.
//
// What this replaces: the original test tapped a power icon and expected the
// literal text "Disconnected" to flip to "Connected". That was written against
// the throwaway local-timer toggle that predates the real tunnel — the strings
// are localized (Russian by default) and the toggle now drives sing-box, so the
// test had been failing since long before the audit.
//
// What it covers now is the thing that matters and can be asserted without a
// backend: the root gate in `main.dart` (`_FatVpnAppState._rootScreen`) picks
// the right screen for each session state, and the app boots far enough to
// render it — MaterialApp, theme, localization scope, splash hand-off and all
// four controllers starting up.
//
// Hermetic by construction. `FatVpnApp` builds its own `ApiClient` inside
// `AuthController`, so there is no constructor seam to pass a `MockClient`
// through; instead `HttpOverrides` replaces `dart:io`'s `HttpClient` for the
// duration of each test (see support/no_network_http.dart). No socket is
// opened, nothing depends on the test BFF being up, and the tests assert what
// each path did or did not request. Waiting is done by pumping until a
// condition holds rather than for a fixed number of milliseconds, so a loaded
// machine cannot change the outcome.
//
// Deliberately NOT covered here (needs a device or a live BFF): connecting,
// real server lists, pairing hand-off, and anything past HomeScreen's first
// frame. Those live in the audit_* suites, which drive the controllers directly.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/main.dart';
import 'package:fatvpn_app/screens/awaiting_auth_screen.dart';
import 'package:fatvpn_app/screens/home_screen.dart';
import 'package:fatvpn_app/screens/splash_screen.dart';

import 'support/fake_vpn_platform.dart';
import 'support/no_network_http.dart';

/// Channels the app touches on startup that have no Dart-side test double.
void _stubPlatformChannels(WidgetTester tester) {
  void stub(String name, Object? reply) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => reply);
  }

  // app_links: no link delivered the app, and no stream events.
  stub('com.llfbandit.app_links/messages', null);
  stub('com.llfbandit.app_links/events', null);
  // flutter_local_notifications registers its platform instance from native
  // code, which never runs here — without this every call throws a
  // LateInitializationError out of NotificationService.init. Its methods are
  // typed Future<bool>, so the reply cannot be null.
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  stub('dexterous.com/flutter/local_notifications', true);
}

/// A stored session.
///
/// Two things keep the gate decision local. The refresh token is empty, so
/// `AuthController.start` skips the background `/auth/refresh`; and the JWT's
/// own expiry is in the future, so `currentAccessToken` hands the stored token
/// back instead of rotating (which, with no refresh token, would sign out).
Map<String, String> _storedSession({required Duration expiresIn}) =>
    <String, String>{
      'access_token': 'stored-access-token',
      'refresh_token': '',
      // Despite the key's name this is the *subscription* expiry — it is what
      // the gate branches on.
      'access_token_expires_at':
          DateTime.now().add(expiresIn).toIso8601String(),
      'access_jwt_expires_at':
          DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
    };

/// Pumps until [condition] holds, or gives up after [budget] of frames.
///
/// The splash alone holds for 1.4 s and never settles on its own (its glow
/// animation repeats forever, so `pumpAndSettle` would time out). Pumping to a
/// condition keeps the test independent of how long the startup reads take.
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

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) =>
    _pumpUntil(tester, () => finder.evaluate().isNotEmpty);

/// Lets AppLogger's 2 s flush timer (§2.11 — a one-shot re-armed per batch)
/// fire before the test ends.
///
/// The logger is a process-wide singleton, so whichever test arms the timer
/// inside its own zone is the one the framework's end-of-test pending-timer
/// check fails. Draining it here keeps that from depending on test order.
Future<void> _drainLoggerFlush(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

void main() {
  late FakeVpnPlatform vpnPlatform;
  late NoNetworkHttpOverrides network;
  HttpOverrides? previousOverrides;

  setUp(() {
    // HomeScreen reconciles with the running tunnel on its first frame.
    vpnPlatform = FakeVpnPlatform(initializeDelay: Duration.zero);
    SignboxVpnPlatform.instance = vpnPlatform;

    previousOverrides = HttpOverrides.current;
    network = NoNetworkHttpOverrides();
    HttpOverrides.global = network;
  });

  tearDown(() {
    HttpOverrides.global = previousOverrides;
    vpnPlatform.dispose();
  });

  testWidgets('holds the splash while the stored session is resolving',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    _stubPlatformChannels(tester);

    await tester.pumpWidget(const FatVpnApp());
    await tester.pump();

    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(AwaitingAuthScreen), findsNothing);
    expect(find.byType(HomeScreen), findsNothing);

    await _pumpUntilFound(tester, find.byType(AwaitingAuthScreen));
    await _drainLoggerFlush(tester);
  });

  testWidgets('a device with no session lands on onboarding, offline',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    _stubPlatformChannels(tester);

    await tester.pumpWidget(const FatVpnApp());
    await _pumpUntilFound(tester, find.byType(AwaitingAuthScreen));

    expect(find.byType(AwaitingAuthScreen), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
    // A first-run device still holds its trial, so this is the trial-first
    // onboarding rather than the renew variant.
    expect(
      tester.widget<AwaitingAuthScreen>(find.byType(AwaitingAuthScreen)).renew,
      isFalse,
    );
    // And it must reach onboarding without talking to anything: a fresh install
    // opened offline has to show the trial button, not a spinner or an error.
    expect(network.requests, isEmpty,
        reason: 'first launch issued ${network.requests}');
    await _drainLoggerFlush(tester);
  });

  testWidgets('a lapsed subscription is routed to renew, not to onboarding',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(
        _storedSession(expiresIn: const Duration(days: -1)));
    _stubPlatformChannels(tester);

    await tester.pumpWidget(const FatVpnApp());
    await _pumpUntilFound(tester, find.byType(AwaitingAuthScreen));

    final screen = find.byType(AwaitingAuthScreen);
    expect(screen, findsOneWidget);
    expect(tester.widget<AwaitingAuthScreen>(screen).renew, isTrue,
        reason: 'a paying user whose plan ran out must get the renew screen, '
            'not be dropped back into the trial flow');
    expect(find.byType(HomeScreen), findsNothing);
    // The renew screen needs a pairing code to show, so this path does go to
    // the BFF — and only there. A stored session must never be re-validated by
    // a call the gate has already decided without.
    await _pumpUntil(tester, () => network.requests.isNotEmpty);
    expect(network.requests, everyElement(contains('/pair/start')));
    await _drainLoggerFlush(tester);
  });

  testWidgets('a live subscription lands on the home screen', (tester) async {
    FlutterSecureStorage.setMockInitialValues(
        _storedSession(expiresIn: const Duration(days: 30)));
    _stubPlatformChannels(tester);

    await tester.pumpWidget(const FatVpnApp());
    await _pumpUntilFound(tester, find.byType(HomeScreen));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(AwaitingAuthScreen), findsNothing);

    // The tunnel is asked what state it is really in — the reconciliation that
    // stops a relaunch from showing "disconnected" over a live VPN.
    await _pumpUntil(tester, () => vpnPlatform.initializeCalls > 0);
    expect(vpnPlatform.initializeCalls, 1,
        reason: 'HomeScreen enters _ensureInitialized twice on launch (§2.3)');
    await _drainLoggerFlush(tester);
  });
}
