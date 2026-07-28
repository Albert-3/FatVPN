import 'secure_store.dart';

/// The country the user picked by hand, remembered between launches.
///
/// It used to live in [HomeScreen]'s state alone, which was enough while the
/// home screen was the only thing that could connect. It no longer is: the
/// widget's power button brings the tunnel up with no UI in the process at all
/// (see `WidgetConnectRunner`), and it has to reach the same server a tap on
/// the app's own button would.
///
/// "Best server" is the *absence* of a record rather than a value — which is
/// exactly what a first press on a fresh install finds, and why it connects to
/// the fastest node overall instead of nothing.
class SelectedLocationStore {
  SelectedLocationStore({SecureStore? storage})
      : _storage = storage ?? SecureStore();

  static const _key = 'selected_country';

  final SecureStore _storage;

  /// The chosen country code (e.g. `DE`), or null for "best server".
  Future<String?> read() async {
    final value = await _storage.read(key: _key);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> write(String countryCode) =>
      _storage.write(key: _key, value: countryCode);

  /// Back to "best server" — see the class comment on why this deletes rather
  /// than writing a sentinel.
  Future<void> clear() => _storage.delete(key: _key);
}
