// Regression tests for the 2026-07-31 session clobber, found on a real iPhone
// (build 186) the evening the trial ran out.
//
// The renew screen refreshes the old, expired session ("проверить снова", app
// resume) while /pair/status is being polled. When the poll delivered the paid
// session first and the refresh response landed second, `_doRefresh` applied it
// unconditionally: the freshly-minted account session was overwritten — in
// memory and on disk — by a rotation of the expired trial session, and the gate
// dropped the user straight back onto the renew screen, which minted a new pair
// code. Prod data showed it twice in a row (PairingCodes consumed at 20:27:14
// and 20:27:36, both sessions abandoned without a single later refresh) before
// the user gave up and pasted the key by hand.
//
// The same guard protects the other replacement paths: a pasted key, a trial
// grant, and a sign-out racing an in-flight refresh — including a late 401,
// which used to be able to sign the *new* session out.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fatvpn_app/models/auth_session.dart';
import 'package:fatvpn_app/models/pairing.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/auth_controller.dart';
import 'package:fatvpn_app/services/token_storage.dart';

class _MemoryTokenStorage extends TokenStorage {
  AuthSession? stored;
  PairingStart? pairing;

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
  @override
  Future<void> savePairing(PairingStart p) async => pairing = p;
  @override
  Future<void> clearPairing() async => pairing = null;
  @override
  Future<PairingStart?> readPairing() async => pairing;
}

String _session({
  required String suffix,
  required bool lapsed,
}) =>
    jsonEncode(<String, Object?>{
      'accessToken': 'AT-$suffix',
      'refreshToken': 'RT-$suffix',
      'expiresAt': DateTime.now()
          .add(Duration(days: lapsed ? -1 : 30))
          .toIso8601String(),
    });

/// BFF where /auth/refresh answers only when the test lets it, so a response
/// can be made to land *after* pairing has already replaced the session.
class _RacingBff {
  _RacingBff({this.refreshStatus = 200});

  final int refreshStatus;
  final Completer<void> refreshGate = Completer<void>();
  int refreshCalls = 0;

  late final MockClient client = MockClient((request) async {
    switch (request.url.path) {
      case '/auth/token':
        // The starting point: an expired trial the user is stuck on.
        return http.Response(_session(suffix: 'OLD', lapsed: true), 200);
      case '/auth/refresh':
        refreshCalls++;
        await refreshGate.future;
        if (refreshStatus != 200) return http.Response('', refreshStatus);
        // A rotation of the expired session: still lapsed, new tokens.
        return http.Response(_session(suffix: 'OLD2', lapsed: true), 200);
      case '/pair/start':
        return http.Response(
          jsonEncode(<String, Object?>{
            'pairCode': 'ABCD12',
            'pollToken': 'poll-token',
            'expiresAt':
                DateTime.now().add(const Duration(minutes: 15)).toIso8601String(),
          }),
          200,
        );
      case '/pair/status':
        // The bot has already linked the paid key: completed on the first poll.
        return http.Response(
          jsonEncode(<String, Object?>{
            'status': 'completed',
            'accessToken': 'AT-NEW',
            'refreshToken': 'RT-NEW',
            'expiresAt':
                DateTime.now().add(const Duration(days: 30)).toIso8601String(),
          }),
          200,
        );
      case '/auth/logout':
        return http.Response('', 204);
      default:
        return http.Response('unexpected ${request.url}', 404);
    }
  });
}

void main() {
  Future<(AuthController, _MemoryTokenStorage)> signedInOnExpiredTrial(
      _RacingBff bff) async {
    final storage = _MemoryTokenStorage();
    final auth = AuthController(
      apiClient: ApiClient(httpClient: bff.client, baseUrl: 'http://bff.test'),
      tokenStorage: storage,
    );
    // Establishes the session without start() (which needs a real AppLinks).
    await auth.exchangeShortToken(
      'KEY-OLD',
      conflictMessage: 'conflict',
      deviceLimitMessage: 'device-limit',
      notFoundMessage: 'not-found',
      genericMessage: 'generic',
    );
    expect(auth.session?.refreshToken, 'RT-OLD', reason: 'setup failed');
    return (auth, storage);
  }

  testWidgets('a refresh landing after pairing completed does not clobber '
      'the new session', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final bff = _RacingBff();
    final (auth, storage) = await signedInOnExpiredTrial(bff);
    addTearDown(auth.dispose);

    // The renew screen refreshing the expired session — held on the wire.
    final refreshFuture = auth.ensureFreshAccessToken();
    await tester.pump();
    expect(bff.refreshCalls, 1, reason: 'setup failed');

    // Meanwhile pairing completes and installs the paid session.
    await auth.startPairing(expiredMessage: 'expired', genericMessage: 'generic');
    await tester.pump(const Duration(seconds: 3));
    expect(auth.session?.refreshToken, 'RT-NEW', reason: 'setup failed');
    expect(auth.pairingActive, isFalse, reason: 'setup failed');

    // Now the stale refresh response lands.
    bff.refreshGate.complete();
    expect(await refreshFuture, isNull,
        reason: 'the rotation belongs to the abandoned session — it must not '
            'be handed to callers as a usable access token');

    expect(auth.session?.refreshToken, 'RT-NEW',
        reason: 'the in-flight refresh of the expired trial used to overwrite '
            'the session pairing just delivered');
    expect(auth.subscriptionActive, isTrue,
        reason: 'flipping back to "expired" is what sent the user to the renew '
            'screen for a second pair code');
    expect(storage.stored?.refreshToken, 'RT-NEW',
        reason: 'disk must hold the live session, or the next cold start '
            'restores the abandoned one');

    // Drain the logger's flush timer before the pending-timer check runs.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a late 401 for the abandoned session does not sign the new '
      'session out', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final bff = _RacingBff(refreshStatus: 401);
    final (auth, _) = await signedInOnExpiredTrial(bff);
    addTearDown(auth.dispose);

    final refreshFuture = auth.ensureFreshAccessToken();
    await tester.pump();
    expect(bff.refreshCalls, 1, reason: 'setup failed');

    await auth.startPairing(expiredMessage: 'expired', genericMessage: 'generic');
    await tester.pump(const Duration(seconds: 3));
    expect(auth.session?.refreshToken, 'RT-NEW', reason: 'setup failed');

    bff.refreshGate.complete();
    expect(await refreshFuture, isNull);

    expect(auth.isLoggedIn, isTrue,
        reason: 'the 401 answered the dead session\'s token; signing out here '
            'would destroy the session the user just paired');
    expect(auth.session?.refreshToken, 'RT-NEW');

    // Drain the logger's flush timer before the pending-timer check runs.
    await tester.pump(const Duration(seconds: 3));
  });
}
