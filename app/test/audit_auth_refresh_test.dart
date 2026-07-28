// Regression test for docs/improvement-plan-app-android.md §2.1 —
// "Ротированный refresh-токен сохраняется fire-and-forget".
//
// The BFF rotates the refresh token on every /auth/refresh and runs reuse
// detection: presenting an already-rotated token revokes the whole session
// family and forces a re-pair. So the client may only treat a rotation as
// successful once the new token is on disk. Two properties follow, and both are
// pinned here:
//
//   1. ordering — persist first, then publish to memory/listeners;
//   2. failure  — a save that throws must abort the refresh, leaving the old
//      (still valid, thanks to the BFF grace window) token authoritative,
//      rather than being swallowed by `catchError((_) {})`.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fatvpn_app/models/auth_session.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/auth_controller.dart';
import 'package:fatvpn_app/services/token_storage.dart';

/// Token storage that appends to a shared trace, so the order of "written to
/// disk" against "visible to listeners" is observable.
class _TracingTokenStorage extends TokenStorage {
  _TracingTokenStorage(this.trace, {this.failSave = false});

  final List<String> trace;
  final bool failSave;
  AuthSession? stored;

  @override
  Future<void> save(AuthSession session) async {
    trace.add('disk:${session.refreshToken}');
    if (failSave) {
      // Exactly what the legacy secure-storage path throws after an OS upgrade
      // or a restored backup (see §1.5).
      throw PlatformException(code: 'BAD_DECRYPT', message: 'no key');
    }
    stored = session;
  }

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
  Future<void> clearPairing() async {}

  @override
  Future<bool> hasAttemptedAutoTrial() async => false;

  @override
  Future<void> markAutoTrialAttempted() async {}

  @override
  Future<void> clear() async {
    stored = null;
  }
}

String _sessionBody(String access, String refresh) => jsonEncode(<String, Object?>{
      'accessToken': access,
      'refreshToken': refresh,
      'expiresAt':
          DateTime.now().add(const Duration(days: 30)).toIso8601String(),
    });

/// Serves the key exchange that mints RT1 and the rotation that replaces it
/// with RT2.
MockClient _rotatingBff({int refreshStatus = 200}) {
  return MockClient((request) async {
    switch (request.url.path) {
      case '/auth/token':
        return http.Response(_sessionBody('AT1', 'RT1'), 200);
      case '/auth/refresh':
        if (refreshStatus != 200) return http.Response('', refreshStatus);
        return http.Response(_sessionBody('AT2', 'RT2'), 200);
      default:
        return http.Response('unexpected ${request.url}', 404);
    }
  });
}

Future<(AuthController, _TracingTokenStorage, List<String>)> _signedIn({
  bool failSave = false,
  int refreshStatus = 200,
}) async {
  final trace = <String>[];
  final storage = _TracingTokenStorage(trace, failSave: failSave);
  final api = ApiClient(
    httpClient: _rotatingBff(refreshStatus: refreshStatus),
    baseUrl: 'http://bff.test',
  );
  final auth = AuthController(apiClient: api, tokenStorage: storage);
  // Establishes the session without going through start() (which would need a
  // real AppLinks/platform channel).
  await auth.exchangeShortToken(
    'KEY-1',
    conflictMessage: 'conflict',
    notFoundMessage: 'not-found',
    genericMessage: 'generic',
  );
  expect(auth.session?.refreshToken, 'RT1', reason: 'setup failed');
  auth.addListener(() => trace.add('memory:${auth.session?.refreshToken}'));
  trace.clear();
  return (auth, storage, trace);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the rotated token reaches disk before it reaches memory', () async {
    final (auth, storage, trace) = await _signedIn();

    final token = await auth.ensureFreshAccessToken();

    expect(token, 'AT2');
    expect(auth.session?.refreshToken, 'RT2');
    expect(storage.stored?.refreshToken, 'RT2');
    expect(
      trace,
      containsAllInOrder(<String>['disk:RT2', 'memory:RT2']),
      reason: 'a rotation published to memory before the write completes is '
          'one process kill away from replaying a revoked token',
    );
  });

  test('a save that throws aborts the refresh instead of being swallowed',
      () async {
    final (auth, storage, trace) = await _signedIn(failSave: true);

    final token = await auth.ensureFreshAccessToken();

    expect(trace, contains('disk:RT2'), reason: 'the write must be attempted');
    expect(token, isNull,
        reason: 'an unpersisted rotation must not be reported as success');
    expect(
      auth.session?.refreshToken,
      'RT1',
      reason: 'the old token stays authoritative — the BFF grace window covers '
          'the retry, whereas an in-memory-only RT2 does not survive a kill',
    );
    expect(storage.stored, isNull);
  });

  test('the session survives a refresh the network could not complete',
      () async {
    // 500 is not a revocation; the session must be kept for a later retry.
    final (auth, _, _) = await _signedIn(refreshStatus: 500);

    expect(await auth.ensureFreshAccessToken(), isNull);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.session?.refreshToken, 'RT1');
  });

  test('a 401 refresh signs out (revoked family)', () async {
    final (auth, _, _) = await _signedIn(refreshStatus: 401);

    expect(await auth.ensureFreshAccessToken(), isNull);
    expect(auth.isLoggedIn, isFalse);
  });
}
