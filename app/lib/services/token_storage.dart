import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/auth_session.dart';

class TokenStorage {
  TokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'access_token';
  static const _expiresAtKey = 'access_token_expires_at';

  final FlutterSecureStorage _storage;

  Future<void> save(AuthSession session) async {
    await _storage.write(key: _accessTokenKey, value: session.accessToken);
    await _storage.write(
      key: _expiresAtKey,
      value: session.expiresAt.toIso8601String(),
    );
  }

  Future<AuthSession?> read() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final expiresAtRaw = await _storage.read(key: _expiresAtKey);
    if (accessToken == null || expiresAtRaw == null) {
      return null;
    }
    return AuthSession(
      accessToken: accessToken,
      expiresAt: DateTime.parse(expiresAtRaw),
    );
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _expiresAtKey);
  }
}
