import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [FlutterSecureStorage] that treats a store it cannot decrypt as an empty
/// one, instead of throwing.
///
/// On Android these values live in SharedPreferences encrypted with a key held
/// in the hardware Keystore, and the two can come apart: Android's Auto Backup
/// copies the preferences off the device, but a Keystore key is
/// non-exportable, so restoring that backup — onto a new phone, or onto a
/// fresh install of this app — leaves ciphertext with no key. Every read then
/// fails with `BadPaddingException: BAD_DECRYPT`.
///
/// That was not survivable before this wrapper. `AuthController.start` awaits a
/// read before the first frame, so the exception left `_initializing` true
/// forever: the app opened to the splash screen and stayed there, on a device
/// the user had done nothing wrong with. Observed on a Redmi Note 7 whose
/// Google account had a backup from another install (2026-07-28).
///
/// Recovery is to wipe the store. Nothing is lost that was not already lost —
/// the contents are unreadable by definition — and the app carries on as a
/// fresh install: onboarding, then a new session. The wipe also restores
/// writes, which fail for the same reason (the plugin unwraps the same key
/// before encrypting), so the next thing the user does actually persists.
///
/// The API mirrors [FlutterSecureStorage]'s named parameters so call sites read
/// the same either way.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(aOptions: _android);

  /// EncryptedSharedPreferences rather than the plugin's legacy Android mode,
  /// which encrypts each value with an RSA key from the Keystore and drops it
  /// into ordinary preferences — a path with a long history of losing its key
  /// across OS upgrades and restores. The plugin migrates existing values on
  /// first use; anything it can't is handled by the wipe below.
  static const _android = AndroidOptions(encryptedSharedPreferences: true);

  final FlutterSecureStorage _storage;

  /// Set once the store has been found undecryptable and wiped. A cold start
  /// reads a dozen keys; without this it would wipe once per key. After the
  /// first wipe the store is empty, so later reads return null rather than
  /// throwing, and a value written in between keeps its fresh key — the flag
  /// costs nothing but the redundant round trips.
  bool _wiped = false;

  Future<String?> read({required String key}) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      await _wipe();
      return null;
    }
  }

  Future<void> write({required String key, required String value}) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException {
      // What failed is the key material, not this value, so the write is worth
      // repeating once the store has been reset — otherwise the setting the
      // user just changed would silently not stick.
      await _wipe();
      try {
        await _storage.write(key: key, value: value);
      } on PlatformException {
        // Storage is unusable on this device. Losing a preference is bad; a
        // crash on every settings change is worse.
      }
    }
  }

  Future<void> delete({required String key}) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException {
      await _wipe();
    }
  }

  Future<void> _wipe() async {
    if (_wiped) return;
    _wiped = true;
    try {
      await _storage.deleteAll();
    } on PlatformException {
      // Nothing further to try: reads already answer null, so the app behaves
      // like a fresh install even if the old ciphertext is still on disk.
    }
  }
}
