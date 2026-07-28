import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/auth_session.dart';
import 'secure_store.dart';

class TokenStorage {
  TokenStorage({FlutterSecureStorage? storage})
      : _storage = SecureStore(storage: storage);

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _expiresAtKey = 'access_token_expires_at';
  // The JWT's own lifetime, as opposed to _expiresAtKey, which despite its name
  // holds the subscription's. Kept so a cold start knows whether the stored
  // access token is still usable instead of refreshing (and rotating) blindly.
  static const _accessJwtExpiresAtKey = 'access_jwt_expires_at';
  static const _deviceKeyKey = 'device_attestation_key';
  static const _autoTrialKey = 'auto_trial_attempted';
  static const _keyCodeKey = 'active_key_code';
  static const _sessionKindKey = 'last_session_kind';

  final SecureStore _storage;

  /// Whether we've already tried to auto-grant a free trial on this install.
  /// Set once the attempt reaches a definitive outcome (granted, or the device
  /// already used its trial) so cold starts don't keep re-requesting. A
  /// transient failure (empty pool / no network) leaves it false to retry.
  /// Deliberately survives [clear] — signing out must not re-grant a trial.
  Future<bool> hasAttemptedAutoTrial() async =>
      await _storage.read(key: _autoTrialKey) == 'true';

  Future<void> markAutoTrialAttempted() async =>
      _storage.write(key: _autoTrialKey, value: 'true');

  /// Stable per-install identifier used as the MVP `attestationToken` for
  /// `POST /trial`. Deliberately NOT removed by [clear] so signing out can't
  /// hand the same device a second trial. Real Play Integrity / App Attest
  /// verification is a later task.
  Future<String> readOrCreateDeviceKey() async {
    final existing = await _storage.read(key: _deviceKeyKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _deviceKeyKey, value: key);
    return key;
  }

  /// Which kind of session was last established: `'trial'`, `'key'` (pasted
  /// code), or `'pairing'` (Telegram). Deliberately survives [clear] — after
  /// sign-out this is the only way to tell whether a leftover trial is safe to
  /// silently resume, or whether the device has since moved on to a real
  /// subscription (in which case a stale trial must NOT be resurrected).
  Future<void> saveSessionKind(String kind) =>
      _storage.write(key: _sessionKindKey, value: kind);

  Future<String?> readSessionKind() => _storage.read(key: _sessionKindKey);

  Future<void> save(AuthSession session) async {
    final accessTokenExpiresAt = session.accessTokenExpiresAt;
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: session.accessToken),
      _storage.write(key: _refreshTokenKey, value: session.refreshToken),
      _storage.write(
        key: _expiresAtKey,
        value: session.expiresAt.toIso8601String(),
      ),
      if (accessTokenExpiresAt != null)
        _storage.write(
          key: _accessJwtExpiresAtKey,
          value: accessTokenExpiresAt.toIso8601String(),
        )
      else
        _storage.delete(key: _accessJwtExpiresAtKey),
    ]);
  }

  /// The key code the user pasted to connect (the "код ключа" from the bot),
  /// so Settings can show which key is active. Only set for the paste-key /
  /// deep-link path — pairing/trial sessions have no user-entered code.
  /// Cleared by [clear] so signing out or switching sessions drops the label.
  Future<void> saveKeyCode(String code) =>
      _storage.write(key: _keyCodeKey, value: code);

  Future<void> clearKeyCode() => _storage.delete(key: _keyCodeKey);

  Future<String?> readKeyCode() => _storage.read(key: _keyCodeKey);

  /// Reads the stored session. The four values are fetched together: each one
  /// crosses a platform channel and is decrypted with a Keystore key, which on
  /// a budget device is 5-15 ms — and this sits directly in front of the first
  /// frame, alongside a dozen other reads.
  Future<AuthSession?> read() async {
    final values = await Future.wait([
      _storage.read(key: _accessTokenKey),
      _storage.read(key: _expiresAtKey),
      _storage.read(key: _refreshTokenKey),
      _storage.read(key: _accessJwtExpiresAtKey),
    ]);
    final accessToken = values[0];
    final expiresAtRaw = values[1];
    if (accessToken == null || expiresAtRaw == null) {
      return null;
    }
    final accessJwtExpiresAtRaw = values[3];
    return AuthSession(
      accessToken: accessToken,
      refreshToken: values[2] ?? '',
      expiresAt: DateTime.parse(expiresAtRaw),
      accessTokenExpiresAt: accessJwtExpiresAtRaw != null
          ? DateTime.tryParse(accessJwtExpiresAtRaw)
          : null,
    );
  }

  Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _expiresAtKey),
      _storage.delete(key: _accessJwtExpiresAtKey),
      _storage.delete(key: _keyCodeKey),
    ]);
  }
}
