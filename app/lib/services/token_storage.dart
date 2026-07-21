import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/auth_session.dart';

class TokenStorage {
  TokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _expiresAtKey = 'access_token_expires_at';
  static const _deviceKeyKey = 'device_attestation_key';
  static const _autoTrialKey = 'auto_trial_attempted';
  static const _keyCodeKey = 'active_key_code';
  static const _sessionKindKey = 'last_session_kind';

  final FlutterSecureStorage _storage;

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
    await _storage.write(key: _accessTokenKey, value: session.accessToken);
    await _storage.write(key: _refreshTokenKey, value: session.refreshToken);
    await _storage.write(
      key: _expiresAtKey,
      value: session.expiresAt.toIso8601String(),
    );
  }

  /// The key code the user pasted to connect (the "код ключа" from the bot),
  /// so Settings can show which key is active. Only set for the paste-key /
  /// deep-link path — pairing/trial sessions have no user-entered code.
  /// Cleared by [clear] so signing out or switching sessions drops the label.
  Future<void> saveKeyCode(String code) =>
      _storage.write(key: _keyCodeKey, value: code);

  Future<void> clearKeyCode() => _storage.delete(key: _keyCodeKey);

  Future<String?> readKeyCode() => _storage.read(key: _keyCodeKey);

  Future<AuthSession?> read() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final expiresAtRaw = await _storage.read(key: _expiresAtKey);
    if (accessToken == null || expiresAtRaw == null) {
      return null;
    }
    return AuthSession(
      accessToken: accessToken,
      refreshToken: await _storage.read(key: _refreshTokenKey) ?? '',
      expiresAt: DateTime.parse(expiresAtRaw),
    );
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _expiresAtKey);
    await _storage.delete(key: _keyCodeKey);
  }
}
