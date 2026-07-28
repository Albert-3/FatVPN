// Regression tests for docs/improvement-plan-ios.md V17 — "Логаут по 401 и
// истечение подписки (402) обходят forgetPersistedTunnelState()".
//
// The tunnel is authorised by the session, so every way a session can die has
// to bring the tunnel down and erase the persisted state the OS would
// reconnect from. Before this fix, only the happy path did: [HomeScreen] wires
// [AuthController.onSessionDropped], but the moment `subscriptionActive` flips
// false the gate unmounts that screen, the wiring goes with it, and the
// automatic sign-out on a rejected refresh ran with nothing to call. A 402
// didn't stop the tunnel at all outside one code path in the servers loader.
// On iOS with on-demand enabled that means the OS keeps resurrecting the
// tunnel from `start_options.plist` on credentials the panel has revoked.
//
// Pinned here: every session-death path — manual sign-out, the automatic
// sign-out on a 401 refresh, a live 402, and a refresh that comes back already
// lapsed — reaches the platform's stop + wipe even when no screen is wired,
// and goes through the wired handler when one is.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/models/auth_session.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/auth_controller.dart';
import 'package:fatvpn_app/services/token_storage.dart';

import 'support/fake_vpn_platform.dart';

/// Just enough [TokenStorage] to sign in and out without a platform.
class _MemoryTokenStorage extends TokenStorage {
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
  Future<void> clearPairing() async {}

  @override
  Future<bool> hasAttemptedAutoTrial() async => false;

  @override
  Future<void> markAutoTrialAttempted() async {}

  @override
  Future<void> clear() async => stored = null;
}

String _sessionBody({required bool lapsed}) => jsonEncode(<String, Object?>{
      'accessToken': 'AT',
      'refreshToken': 'RT',
      'expiresAt': DateTime.now()
          .add(Duration(days: lapsed ? -1 : 30))
          .toIso8601String(),
    });

/// BFF that mints an active session on key exchange; what `/auth/refresh`
/// answers is the knob each test turns.
MockClient _bff({int refreshStatus = 200, bool refreshLapsed = false}) {
  return MockClient((request) async {
    switch (request.url.path) {
      case '/auth/token':
        return http.Response(_sessionBody(lapsed: false), 200);
      case '/auth/refresh':
        if (refreshStatus != 200) return http.Response('', refreshStatus);
        return http.Response(_sessionBody(lapsed: refreshLapsed), 200);
      case '/auth/logout':
        return http.Response('', 204);
      default:
        return http.Response('unexpected ${request.url}', 404);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVpnPlatform platform;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = FakeVpnPlatform();
    SignboxVpnPlatform.instance = platform;
  });

  tearDown(() => platform.dispose());

  Future<AuthController> signedIn(MockClient bff) async {
    final auth = AuthController(
      apiClient: ApiClient(httpClient: bff, baseUrl: 'http://bff.test'),
      tokenStorage: _MemoryTokenStorage(),
    );
    // Establishes the session without start() (which needs a real AppLinks).
    await auth.exchangeShortToken(
      'KEY-1',
      conflictMessage: 'conflict',
      notFoundMessage: 'not-found',
      genericMessage: 'generic',
    );
    expect(auth.isLoggedIn, isTrue, reason: 'setup failed');
    return auth;
  }

  test('a sign-out with no screen wired still stops and wipes the tunnel',
      () async {
    final auth = await signedIn(_bff());
    expect(auth.onSessionDropped, isNull, reason: 'the point of the test');

    await auth.signOut();
    await pumpEventQueue();

    expect(platform.stopVpnCalls, greaterThanOrEqualTo(1),
        reason: 'a sign-out from the renew screen — where HomeScreen is not '
            'on the tree — used to leave the tunnel running');
    expect(platform.clearPersistedStateCalls, greaterThanOrEqualTo(1),
        reason: 'the start-options snapshot is what iOS on-demand would '
            'reconnect from, on credentials the panel has revoked');
  });

  test('the automatic sign-out on a 401 refresh tears the tunnel down too',
      () async {
    final auth = await signedIn(_bff(refreshStatus: 401));

    expect(await auth.ensureFreshAccessToken(), isNull);
    await pumpEventQueue();

    expect(auth.isLoggedIn, isFalse);
    expect(platform.stopVpnCalls, greaterThanOrEqualTo(1),
        reason: 'this is the exact V17 path: signOut() from _doRefresh runs '
            'after the gate may have unmounted HomeScreen');
    expect(platform.clearPersistedStateCalls, greaterThanOrEqualTo(1));
  });

  test('a 402 goes through the wired handler while the screen still exists',
      () async {
    final auth = await signedIn(_bff());
    var dropped = 0;
    auth.onSessionDropped = () async => dropped++;

    auth.notifyExpired();
    await pumpEventQueue();

    expect(dropped, 1,
        reason: 'the handler must be read before notifyListeners unmounts '
            'the screen that wired it');

    auth.notifyExpired();
    await pumpEventQueue();
    expect(dropped, 1, reason: 'an already-lapsed subscription is not news');
  });

  test('a 402 with no screen wired falls back to the standalone teardown',
      () async {
    final auth = await signedIn(_bff());

    auth.notifyExpired();
    await pumpEventQueue();

    expect(auth.subscriptionActive, isFalse);
    expect(platform.stopVpnCalls, greaterThanOrEqualTo(1),
        reason: 'a lapsed subscription must take the tunnel down, not just '
            'flip the UI to the renew screen');
    expect(platform.clearPersistedStateCalls, greaterThanOrEqualTo(1));
  });

  test('a refresh that comes back already lapsed drops the tunnel', () async {
    final auth = await signedIn(_bff(refreshLapsed: true));
    var dropped = 0;
    auth.onSessionDropped = () async => dropped++;

    await auth.ensureFreshAccessToken();
    await pumpEventQueue();

    expect(auth.isLoggedIn, isTrue,
        reason: 'lapsed is not signed out — the renew screen needs a session');
    expect(auth.subscriptionActive, isFalse);
    expect(dropped, 1,
        reason: 'the refresh is how a cold start or resume learns the '
            'subscription lapsed; the tunnel dies with the entitlement');
  });

  test('a refresh that stays active does not touch the tunnel', () async {
    final auth = await signedIn(_bff());
    var dropped = 0;
    auth.onSessionDropped = () async => dropped++;

    await auth.ensureFreshAccessToken();
    await pumpEventQueue();

    expect(dropped, 0);
    expect(platform.stopVpnCalls, 0,
        reason: 'a routine silent refresh must never blip the tunnel');
  });
}
