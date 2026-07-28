// Trial anti-abuse stopgap (docs/improvement-plan-app-android.md §1.8,
// docs/prod-readiness.md §0 п.4): the `attestationToken` used to be a random
// key living in secure storage, and secure storage dies with the install — so
// uninstall → reinstall minted a fresh identity and with it a fresh free
// trial, forever.
//
// The stopgap pins the identity to the platform instead: Android hands over a
// hash of SSAID (stable across reinstalls for a given signing key), and the
// random key remains only as the fallback — iOS, where the Keychain already
// survives reinstalls, and devices whose SSAID is missing or junk.
//
// The compatibility rule matters as much as the feature: a key that already
// exists is kept whatever its origin, because the BFF knows the device by
// that key — swapping identities under existing installs would hand each of
// them a second trial, the exact bug being closed.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/services/token_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  const ssaidHash =
      'a3f1c2d4e5b60718293a4b5c6d7e8f90a3f1c2d4e5b60718293a4b5c6d7e8f90';

  test('the platform identity wins over minting a random key', () async {
    final storage = TokenStorage(
      platformDeviceIdentifier: () async => ssaidHash,
    );

    expect(await storage.readOrCreateDeviceKey(), ssaidHash,
        reason: 'a random key dies with the install; the SSAID-derived one is '
            'what makes the trial survive uninstall → reinstall');
  });

  test('the chosen identity is persisted and stable', () async {
    var platformCalls = 0;
    final storage = TokenStorage(
      platformDeviceIdentifier: () async {
        platformCalls++;
        return ssaidHash;
      },
    );

    final first = await storage.readOrCreateDeviceKey();
    final second = await storage.readOrCreateDeviceKey();

    expect(second, first);
    expect(platformCalls, 1,
        reason: 'later reads come from storage, not the platform');
  });

  test('no platform identity falls back to a random 64-hex key', () async {
    final storage = TokenStorage(platformDeviceIdentifier: () async => null);

    final key = await storage.readOrCreateDeviceKey();

    expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await storage.readOrCreateDeviceKey(), key,
        reason: 'the fallback still has to be stable within the install');
  });

  test('a too-short platform answer is junk, not an identity', () async {
    // The BFF requires 16–512 chars; below that everyone would hash alike.
    final storage = TokenStorage(platformDeviceIdentifier: () async => 'abc');

    final key = await storage.readOrCreateDeviceKey();

    expect(key, isNot('abc'));
    expect(key.length, greaterThanOrEqualTo(16));
  });

  test('a platform that throws costs nothing but the upgrade', () async {
    final storage = TokenStorage(
      platformDeviceIdentifier: () async => throw StateError('no channel'),
    );

    // Must not escape: this is every iOS device and every test host.
    final key = await storage.readOrCreateDeviceKey();
    expect(key.length, greaterThanOrEqualTo(16));
  });

  test('an existing key is kept, whatever the platform now says', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'device_attestation_key': 'legacy-random-key-0123456789abcdef',
    });
    final storage = TokenStorage(
      platformDeviceIdentifier: () async => ssaidHash,
    );

    expect(await storage.readOrCreateDeviceKey(),
        'legacy-random-key-0123456789abcdef',
        reason: 'the BFF knows this device by its old key; a new identity '
            'would be read as a new device — and grant a second trial');
  });

  test('signing out does not erase the device identity', () async {
    final storage = TokenStorage(
      platformDeviceIdentifier: () async => ssaidHash,
    );
    final key = await storage.readOrCreateDeviceKey();

    await storage.clear();

    expect(await storage.readOrCreateDeviceKey(), key,
        reason: 'sign-out must not re-arm the trial');
  });
}
