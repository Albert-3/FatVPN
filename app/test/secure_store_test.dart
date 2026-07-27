import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatvpn_app/services/secure_store.dart';
import 'package:fatvpn_app/services/token_storage.dart';

/// Stands in for Android's secure storage after a backup restore: the
/// ciphertext is there, the Keystore key that would decrypt it is not, so every
/// operation fails the way the platform actually fails — with the
/// `BadPaddingException` seen on a Redmi Note 7 (2026-07-28). Wiping the store
/// is what makes it usable again, exactly as on the device.
class _PoisonedStorage {
  _PoisonedStorage({this.poisoned = true});

  static const _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  bool poisoned;
  int wipes = 0;
  final Map<String, String> values = <String, String>{};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'deleteAll') {
      wipes++;
      poisoned = false;
      values.clear();
      return null;
    }
    if (poisoned) {
      throw PlatformException(
        code: 'Exception encountered',
        message: 'read',
        details: 'javax.crypto.BadPaddingException: '
            'error:1e000065:Cipher functions:OPENSSL_internal:BAD_DECRYPT',
      );
    }
    final Map<Object?, Object?> args =
        (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
    final String key = args['key']! as String;
    switch (call.method) {
      case 'read':
        return values[key];
      case 'write':
        values[key] = args['value']! as String;
        return null;
      case 'delete':
        values.remove(key);
        return null;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureStore on a store that cannot be decrypted', () {
    test('answers null instead of throwing, and wipes it once', () async {
      final storage = _PoisonedStorage()..install();
      final store = SecureStore();

      expect(await store.read(key: 'access_token'), isNull);
      expect(await store.read(key: 'refresh_token'), isNull);
      expect(await store.read(key: 'app_language'), isNull);

      expect(
        storage.wipes,
        1,
        reason: 'a cold start reads many keys; one reset covers them all',
      );
    });

    test('is usable again afterwards', () async {
      _PoisonedStorage().install();
      final store = SecureStore();

      await store.read(key: 'access_token');
      await store.write(key: 'access_token', value: 'fresh');

      expect(await store.read(key: 'access_token'), 'fresh');
    });

    test('lands a write that arrives before any read', () async {
      // Settings changed on a poisoned store must still stick: the key
      // material is what failed, not the value, so the write is retried once
      // the store has been reset.
      final storage = _PoisonedStorage()..install();
      final store = SecureStore();

      await store.write(key: 'app_language', value: 'en');

      expect(storage.wipes, 1);
      expect(await store.read(key: 'app_language'), 'en');
    });

    test('leaves a healthy store alone', () async {
      final storage = _PoisonedStorage(poisoned: false)..install();
      final store = SecureStore();

      await store.write(key: 'access_token', value: 'kept');
      expect(await store.read(key: 'access_token'), 'kept');
      expect(storage.wipes, 0, reason: 'nothing was wrong to recover from');
    });
  });

  test('TokenStorage reports no session rather than failing startup', () async {
    // The regression this all exists for: AuthController.start awaits this
    // read before the first frame, so throwing here left the app on its splash
    // screen for good.
    _PoisonedStorage().install();

    expect(await TokenStorage().read(), isNull);
  });
}
