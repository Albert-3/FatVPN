// A key now runs on up to three phones (BFF `Auth:MaxDevicesPerKey`), so the
// old 409 copy — "this key is linked to another phone, change it in the bot" —
// is wrong for the person activating their own second device: nothing is
// linked to anyone else, they simply used up the slots. The BFF says which of
// the two it is in the 409 body (`{"error":"device_limit"}`), and a server that
// predates the limit sends a bare 409 and must still read the old way.
//
// Pinned here: the body's code, not the status alone, chooses the message.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fatvpn_app/models/auth_session.dart';
import 'package:fatvpn_app/services/api_client.dart';
import 'package:fatvpn_app/services/auth_controller.dart';
import 'package:fatvpn_app/services/token_storage.dart';

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

AuthController _authAgainst(MockClient bff) => AuthController(
      apiClient: ApiClient(httpClient: bff, baseUrl: 'http://bff.test'),
      tokenStorage: _MemoryTokenStorage(),
    );

Future<void> _pasteKey(AuthController auth) => auth.exchangeShortToken(
      'KEY-1',
      conflictMessage: 'bound-to-another-phone',
      deviceLimitMessage: 'all-slots-taken',
      notFoundMessage: 'not-found',
      genericMessage: 'generic',
    );

void main() {
  test('409 device_limit says the slots are used up, not that the key moved',
      () async {
    final auth = _authAgainst(MockClient((_) async => http.Response(
        jsonEncode(<String, Object?>{'error': 'device_limit'}), 409)));

    await _pasteKey(auth);

    expect(auth.error, 'all-slots-taken');
  });

  test('a bare 409 from a server without the limit keeps the old message',
      () async {
    final auth = _authAgainst(MockClient((_) async => http.Response('', 409)));

    await _pasteKey(auth);

    expect(auth.error, 'bound-to-another-phone');
  });

  test('an HTML 409 from a proxy does not crash the error mapping', () async {
    // Nothing guarantees the body is JSON — a gateway can answer with a page.
    final auth = _authAgainst(
        MockClient((_) async => http.Response('<html>409</html>', 409)));

    await _pasteKey(auth);

    expect(auth.error, 'bound-to-another-phone');
  });

  test('404 is still a wrong or expired key', () async {
    final auth = _authAgainst(MockClient((_) async => http.Response('', 404)));

    await _pasteKey(auth);

    expect(auth.error, 'not-found');
  });
}
