import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/main.dart';

void main() {
  testWidgets('Home screen shows disconnected state and toggles on tap', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FatVpnApp());

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);

    await tester.tap(find.byIcon(Icons.power_settings_new));
    await tester.pump();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Disconnected'), findsNothing);
  });
}
