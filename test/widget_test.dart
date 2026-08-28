import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:lasli_flutter/main.dart';

void main() {
  testWidgets('LASLI dashboard renders', (WidgetTester tester) async {
    await tester.pumpWidget(const LasliApp());

    expect(find.text('LASLI'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Starten'), findsOneWidget);
    expect(find.text('Schlafjournal'), findsOneWidget);
  });

  testWidgets('YAMNet phone test is available without an MG24 sensor',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LasliApp());
    await tester.tap(find.text('Entwickler'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final button = find.widgetWithText(OutlinedButton, 'YAMNet Live');
    expect(button, findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
  });
}
