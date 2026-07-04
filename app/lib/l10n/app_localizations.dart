import 'package:flutter/widgets.dart';

import '../services/locale_controller.dart';
import 'strings.dart';

class AppLocalizationsScope extends InheritedNotifier<LocaleController> {
  const AppLocalizationsScope({
    super.key,
    required LocaleController controller,
    required super.child,
  }) : super(notifier: controller);

  static LocaleController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppLocalizationsScope>();
    assert(scope != null, 'No AppLocalizationsScope found in context');
    return scope!.notifier!;
  }
}

/// Shorthand accessor: `S.of(context).settingsTitle`.
class S {
  static Strings of(BuildContext context) =>
      AppLocalizationsScope.of(context).strings;
}
