import 'package:flutter_test/flutter_test.dart';

import 'package:lasli_flutter/main.dart';

void main() {
  testWidgets('LASLI dashboard renders', (WidgetTester tester) async {
    await tester.pumpWidget(const LasliApp());

    expect(find.text('LASLI'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Starten'), findsOneWidget);
    expect(find.text('Schlafjournal'), findsOneWidget);
  });
}
