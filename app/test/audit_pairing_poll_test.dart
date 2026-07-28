// Regression tests for docs/improvement-plan-app-android.md §2.13 and §3.8 —
// the /pair/status poll loop.
//
// §2.13 — `_pollOnce` wraps everything in `catch (_)` with no counter. A BFF
//         that answers `{"status":"completed"}` without tokens (a deploy/version
//         skew) makes `PairingStatus.fromJson` throw a TypeError, which is
//         swallowed, and the 2 s timer keeps firing forever while the user
//         stares at a spinner. `PairingStart.expiresAt` is parsed and never used.
// §3.8  — a fixed 2 s interval is 30 HTTP requests a minute on mobile radio
//         while the user is over in Telegram paying.
//
// Timers here run on the widget-test fake clock, so 2 minutes of polling costs
// no real time.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fatvpn_app/models/auth_session.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/auth_controller.dart';
import 'package:fatvpn_app/services/token_storage.dart';

class _NoopTokenStorage extends TokenStorage {
  AuthSession? stored;

  @override
  Future<void> save(AuthSession session) async => stored = session;
  @override
  Future<AuthSession?> read() async => stored;
  @override
  Future<String> readOrCreateDeviceKey() async => 'device-key';
  @override
  Future<void> saveSessionKind(String kind) async {}
  @override
  Future<String?> readSessionKind() async => null;
  @override
  Future<void> saveKeyCode(String code) async {}
  @override
  Future<void> clearKeyCode() async {}
  @override
  Future<String?> readKeyCode() async => null;
  @override
  Future<bool> hasAttemptedAutoTrial() async => false;
  @override
  Future<void> markAutoTrialAttempted() async {}
  @override
  Future<void> clear() async => stored = null;
}

/// Counts /pair/status requests. [status] produces each response.
class _PairingBff {
  _PairingBff({required this.expiresAt, required this.status});

  final DateTime expiresAt;
  final http.Response Function(int callIndex) status;
  int polls = 0;

  late final MockClient client = MockClient((request) async {
    if (request.url.path == '/pair/start') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'pairCode': 'ABCD12',
          'pollToken': 'poll-token',
          'expiresAt': expiresAt.toIso8601String(),
        }),
        200,
      );
    }
    if (request.url.path == '/pair/status') {
      return status(polls++);
    }
    return http.Response('unexpected ${request.url}', 404);
  });
}

AuthController _controllerFor(_PairingBff bff) => AuthController(
      apiClient: ApiClient(httpClient: bff.client, baseUrl: 'http://bff.test'),
      tokenStorage: _NoopTokenStorage(),
    );

void main() {
  testWidgets('a repeatedly failing poll gives up instead of running forever',
      (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // The exact §2.13 repro: "completed" with no tokens, so
    // PairingStatus.fromJson throws a TypeError inside the swallowing catch.
    final bff = _PairingBff(
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      status: (_) => http.Response(jsonEncode(<String, Object?>{'status': 'completed'}), 200),
    );
    final auth = _controllerFor(bff);
    addTearDown(auth.dispose);

    await auth.startPairing(expiredMessage: 'expired', genericMessage: 'generic');
    expect(auth.pairingActive, isTrue, reason: 'setup failed');

    await tester.pump(const Duration(minutes: 2));

    expect(bff.polls, lessThan(20),
        reason: 'a fixed 2 s interval means 60 requests in two minutes');
    expect(auth.pairingActive, isFalse,
        reason: 'after N consecutive failures the user must be told, not left '
            'on a spinner forever');
    expect(auth.error, isNotNull);
  });

  testWidgets('polling stops at the code\'s own expiry', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Already expired server-side: nothing this poll can ever learn.
    final bff = _PairingBff(
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      status: (_) => http.Response(jsonEncode(<String, Object?>{'status': 'pending'}), 200),
    );
    final auth = _controllerFor(bff);
    addTearDown(auth.dispose);

    await auth.startPairing(expiredMessage: 'expired', genericMessage: 'generic');
    await tester.pump(const Duration(minutes: 2));

    expect(bff.polls, lessThanOrEqualTo(2),
        reason: 'PairingStart.expiresAt is parsed — it must also be honoured');
    expect(auth.pairingActive, isFalse);
  });

  testWidgets('a transient blip does not abort a pairing that then completes',
      (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final session = jsonEncode(<String, Object?>{
      'status': 'completed',
      'accessToken': 'AT1',
      'refreshToken': 'RT1',
      'expiresAt': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
    });
    final bff = _PairingBff(
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      // Two failures, then the bot links the account.
      status: (i) => i < 2
          ? http.Response('', 502)
          : http.Response(session, 200),
    );
    final auth = _controllerFor(bff);
    addTearDown(auth.dispose);

    await auth.startPairing(expiredMessage: 'expired', genericMessage: 'generic');
    await tester.pump(const Duration(seconds: 40));

    expect(auth.isLoggedIn, isTrue,
        reason: 'back-off must not turn two blips into a failed pairing');
    expect(auth.pairingActive, isFalse);
  });

  testWidgets('the poll backs off rather than firing every 2 s', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final bff = _PairingBff(
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      status: (_) => http.Response(jsonEncode(<String, Object?>{'status': 'pending'}), 200),
    );
    final auth = _controllerFor(bff);

    await auth.startPairing(expiredMessage: 'expired', genericMessage: 'generic');
    await tester.pump(const Duration(seconds: 60));

    // 2 s flat would be 30. A 2 → 3 → 5 s ramp lands around 13.
    expect(bff.polls, lessThan(25),
        reason: '30 requests a minute on mobile radio while the user is in '
            'Telegram paying (§3.8)');
    expect(bff.polls, greaterThan(3),
        reason: 'it must still poll often enough to feel instant');

    // This is the only case that ends with the poll still armed, so the timer
    // has to go before the framework's pending-timer check runs.
    auth.dispose();
  });
}
