import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/widgets.dart';

void main() {
  test('visible chart range ignores values outside the zoomed x range', () {
    final range = visibleChartDataRangeForTest(
      const [
        (x: 0, y: 40),
        (x: 10, y: 68),
        (x: 20, y: 71),
        (x: 30, y: 130),
      ],
      viewMinX: 8,
      viewMaxX: 22,
    );

    expect(range.min, 68);
    expect(range.max, 71);
  });

  testWidgets('aborting countdown leaves the app route visible',
      (tester) async {
    final hostKey = GlobalKey();
    final abort = ValueNotifier<bool>(false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            key: hostKey,
            builder: (_) => const Text('Home bleibt sichtbar'),
          ),
        ),
      ),
    );

    final resultFuture = measurementStartCountdownForTest(
      hostKey.currentContext!,
      scheduledAt: DateTime.now().add(const Duration(seconds: 10)),
      abortSignal: abort,
    );
    await tester.pump();
    expect(find.text('Messung startet in 30 s'), findsOneWidget);

    abort.value = true;
    await tester.pumpAndSettle();

    expect(await resultFuture, isFalse);
    expect(find.text('Home bleibt sichtbar'), findsOneWidget);
    expect(find.text('Messung startet in 30 s'), findsNothing);
    abort.dispose();
  });

  testWidgets('countdown exposes and updates the signal setting',
      (tester) async {
    final hostKey = GlobalKey();
    final abort = ValueNotifier<bool>(false);
    bool? changedValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            key: hostKey,
            builder: (_) => const Text('Home'),
          ),
        ),
      ),
    );

    final resultFuture = measurementStartCountdownForTest(
      hostKey.currentContext!,
      scheduledAt: DateTime.now().add(const Duration(seconds: 10)),
      abortSignal: abort,
      signalEnabled: false,
      onSignalEnabledChanged: (value) => changedValue = value,
    );
    await tester.pump();

    expect(find.text('Signalton'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.text('Signalton'));
    await tester.pump();
    expect(changedValue, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    abort.value = true;
    await tester.pumpAndSettle();
    expect(await resultFuture, isFalse);
    abort.dispose();
  });
}
