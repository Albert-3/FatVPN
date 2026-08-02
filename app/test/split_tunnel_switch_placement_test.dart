// The employer asked for the split-tunnelling on/off switch to live in the
// main Settings list rather than in the header of the screen behind it
// (2026-08-02). Pinned as a widget test because it is an arrangement, not a
// behaviour: nothing fails, nothing logs, and a later refactor of either screen
// could put it back where it was without a single test noticing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/l10n/app_localizations.dart';
import 'package:fatvpn_app/l10n/strings.dart';
import 'package:fatvpn_app/screens/split_tunnel_hosts_screen.dart';
import 'package:fatvpn_app/services/locale_controller.dart';

Widget _wrap(Widget child) => AppLocalizationsScope(
      controller: LocaleController(),
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the detail screen header no longer carries a switch',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SplitTunnelHeader(title: 'Split tunneling'),
    ));

    expect(find.byType(Switch), findsNothing);
    // The back arrow and the title stay — this is a removal, not a rewrite.
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('Split tunneling'), findsOneWidget);
  });

  // The other half — that the switch is now *in* the Settings list — is not
  // pinned here. `SettingsScreen` reads localisations from `initState`, so
  // booting it needs a live session and a mocked `/me` before it will render at
  // all, and a test built on that scaffolding would fail for reasons that have
  // nothing to do with where a switch sits. It is covered by TA13 in
  // `docs/release-test-checklist.md` instead, by eye, once.

  test('the hints no longer point at a switch that moved away', () {
    // Four strings used to read "turn on the switch above". The switch is not
    // above anything any more, and a hint that names a control the user cannot
    // see is worse than no hint at all.
    for (final Strings s in <Strings>[enStrings, ruStrings]) {
      for (final hint in <String>[
        s.splitTunnelDisabledHint,
        s.splitTunnelHostsDisabledHint,
        s.splitTunnelIncludeDisabledHint,
        s.splitTunnelHostsIncludeDisabledHint,
      ]) {
        expect(hint.toLowerCase(), isNot(contains('switch above')));
        expect(hint.toLowerCase(), isNot(contains('переключатель выше')));
      }
    }
  });
}
