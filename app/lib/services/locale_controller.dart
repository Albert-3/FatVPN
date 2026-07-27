import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import 'secure_store.dart';

class LocaleController extends ChangeNotifier {
  static const _storageKey = 'app_language';
  final _storage = SecureStore();

  AppLanguage _language = AppLanguage.ru;
  AppLanguage get language => _language;
  Strings get strings => stringsFor(_language);

  Future<void> load() async {
    final saved = await _storage.read(key: _storageKey);
    if (saved == 'en') {
      _language = AppLanguage.en;
      notifyListeners();
    }
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_language == language) return;
    _language = language;
    notifyListeners();
    await _storage.write(
      key: _storageKey,
      value: language == AppLanguage.ru ? 'ru' : 'en',
    );
  }
}
