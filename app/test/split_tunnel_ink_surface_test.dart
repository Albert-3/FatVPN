// Two defects found on the emulator on 2026-08-02, pinned together because the
// same widget draws both (`docs/open-bugs.md` 4.3 and 4.4):
//
//   * a `ListTile`/`CheckboxListTile` inside a decorated box paints its ink on
//     whatever Material sits *behind* the card, so the ripple is invisible and
//     the framework asserts about it — 13 times per list render;
//   * an app whose icon bytes never arrived (or arrived unusable) drew nothing
//     at all, which reads as "the icons disappeared" rather than as a failure.
//
// Neither shows up as a crash and neither is visible in release, so only a test
// keeps them fixed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/l10n/app_localizations.dart';
import 'package:fatvpn_app/screens/split_tunnel_hosts_screen.dart';
import 'package:fatvpn_app/screens/split_tunneling_screen.dart';
import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/installed_apps_service.dart';
import 'package:fatvpn_app/services/locale_controller.dart';
import 'package:fatvpn_app/theme/app_colors.dart';

const _appsChannel = MethodChannel('fatvpn/apps');

/// Stands in for `MainActivity.getLaunchableApps`.
void _mockApps(WidgetTester tester, List<Map<String, Object?>> apps) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _appsChannel,
    (call) async => call.method == 'getLaunchableApps' ? apps : null,
  );
}

Widget _wrap(Widget child) => AppLocalizationsScope(
      controller: LocaleController(),
      child: MaterialApp(home: Scaffold(body: child)),
    );

/// The Material a tile's ink actually lands on. The bug is that this used to be
/// the Scaffold's sheet, hidden behind an opaque card.
Material _inkSurfaceOf(WidgetTester tester, Finder tile) => tester.widget<Material>(
      find.ancestor(of: tile, matching: find.byType(Material)).first,
    );

Future<ConnectionSettingsController> _settings() async {
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  final c = ConnectionSettingsController();
  await c.load();
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_appsChannel, null);
  });

  testWidgets('an app row draws its ink on the card, not behind it',
      (tester) async {
    _mockApps(tester, <Map<String, Object?>>[
      <String, Object?>{'name': 'Chrome', 'packageName': 'com.android.chrome'},
    ]);
    final settings = await _settings();

    await tester.pumpWidget(_wrap(AppBypassPicker(connectionSettings: settings)));
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(_inkSurfaceOf(tester, find.byType(CheckboxListTile)).color,
        AppColors.card);
  });

  testWidgets('a host row draws its ink on the card, not behind it',
      (tester) async {
    final settings = await _settings();
    // The seeded defaults give the list something to render.
    expect(settings.bypassHosts, isNotEmpty);

    await tester.pumpWidget(_wrap(HostBypassEditor(connectionSettings: settings)));
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsWidgets);
    expect(_inkSurfaceOf(tester, find.byType(ListTile).first).color,
        AppColors.card);
  });

  testWidgets('an app with no icon gets the fallback glyph, not a hole',
      (tester) async {
    _mockApps(tester, <Map<String, Object?>>[
      // Two ways the native side reports "no picture": the key is absent, or
      // the compressor answered with nothing. Both used to reach `Image.memory`
      // — the second one as bytes that decode to an empty frame.
      <String, Object?>{'name': 'No icon', 'packageName': 'a.b.c'},
      <String, Object?>{
        'name': 'Empty icon',
        'packageName': 'd.e.f',
        'icon': Uint8List(0),
      },
    ]);
    final settings = await _settings();

    await tester.pumpWidget(_wrap(AppBypassPicker(connectionSettings: settings)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.android), findsNWidgets(2));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('zero-length icon bytes never reach the widget layer',
      (tester) async {
    _mockApps(tester, <Map<String, Object?>>[
      <String, Object?>{
        'name': 'Empty icon',
        'packageName': 'd.e.f',
        'icon': Uint8List(0),
      },
    ]);

    final apps = await InstalledAppsService.getLaunchableApps();

    expect(apps, hasLength(1));
    expect(apps.single.icon, isNull);
  });
}
