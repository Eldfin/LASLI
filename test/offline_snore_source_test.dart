import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/measurement_controller.dart';
import 'package:lasli_flutter/src/mg24_protocol.dart';
import 'package:lasli_flutter/src/yamnet_raw_snore_tracker.dart';

void main() {
  Mg24EventRecord event(double startS, double durationS) {
    return Mg24EventRecord(
      startTick: (startS / Mg24EventRecord.tickSeconds).round(),
      durationTicks: (durationS / Mg24EventRecord.tickSeconds).round(),
      qualityPercent: 90,
    );
  }

  final breaths = [
    event(0, 4),
    event(4, 4),
    event(8, 4),
    event(12, 4),
  ];
  final alignedSnores = [
    event(0.4, 1.2),
    event(4.4, 1.2),
    event(8.4, 1.2),
  ];

  test('aligned snore windows are assigned to the wearer', () {
    final controller = MeasurementController();
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: alignedSnores.first,
        breaths: breaths,
        snores: alignedSnores,
      ),
      'wearer',
    );
    controller.dispose();
  });

  test('known YAMNet boundary width does not hide wearer alignment', () {
    final controller = MeasurementController();
    final broadYamnetSnores = [
      event(0, 2.8),
      event(4, 2.8),
      event(8, 2.8),
    ];

    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: broadYamnetSnores.first,
        breaths: breaths,
        snores: broadYamnetSnores,
      ),
      'unknown',
    );
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: broadYamnetSnores.first,
        breaths: breaths,
        snores: broadYamnetSnores,
        snoreBoundaryUncertaintyS: yamnetBoundaryUncertaintySeconds,
      ),
      'wearer',
    );
    controller.dispose();
  });

  test('confirmed snore timing exposes the inferred inhale halves', () {
    final controller = MeasurementController();
    final windows = controller.inhaleWindowsForTest(
      snores: alignedSnores,
      breaths: breaths,
    );

    expect(windows, hasLength(breaths.length));
    expect(windows.first.startS, closeTo(0, 0.01));
    expect(windows.first.endS, closeTo(2, 0.01));
    expect(windows.last.startS, closeTo(12, 0.01));
    expect(windows.last.endS, closeTo(14, 0.01));
    controller.dispose();
  });

  test('inhale halves remain hidden without phase evidence', () {
    final controller = MeasurementController();
    expect(
      controller.inhaleWindowsForTest(snores: const [], breaths: breaths),
      isEmpty,
    );
    controller.dispose();
  });

  test('one off-phase window stays unknown inside a wearer phase', () {
    final controller = MeasurementController();
    final external = event(10.4, 1.0);
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: external,
        breaths: breaths,
        snores: [...alignedSnores, external],
      ),
      'unknown',
    );
    controller.dispose();
  });

  test('a separate phase that misses the learned inhale side is external', () {
    final controller = MeasurementController();
    final longBreaths = [
      for (var start = 0; start <= 36; start += 4) event(start.toDouble(), 4)
    ];
    final wearerPhase = [
      event(0.4, 1.2),
      event(4.4, 1.2),
      event(8.4, 1.2),
      event(12.4, 1.2),
    ];
    final externalPhase = [
      event(26.4, 1.0),
      event(30.4, 1.0),
      event(34.4, 1.0),
    ];
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: externalPhase.first,
        breaths: longBreaths,
        snores: [...wearerPhase, ...externalPhase],
      ),
      'external',
    );
    controller.dispose();
  });

  test('posture-dependent breathing polarity is learned per snore phase', () {
    final controller = MeasurementController();
    final longBreaths = [
      for (var start = 0; start <= 40; start += 4) event(start.toDouble(), 4),
    ];
    final firstPolarity = [
      event(0.4, 1.2),
      event(4.4, 1.2),
      event(8.4, 1.2),
    ];
    final invertedPolarity = [
      event(26.4, 1.2),
      event(30.4, 1.2),
      event(34.4, 1.2),
    ];
    final allSnores = [...firstPolarity, ...invertedPolarity];

    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: firstPolarity.first,
        breaths: longBreaths,
        snores: allSnores,
      ),
      'wearer',
    );
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: invertedPolarity.first,
        breaths: longBreaths,
        snores: allSnores,
      ),
      'wearer',
    );
    controller.dispose();
  });

  test('two matching windows are not enough to classify a phase', () {
    final controller = MeasurementController();
    final twoSnores = alignedSnores.take(2).toList();
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: twoSnores.first,
        breaths: breaths,
        snores: twoSnores,
      ),
      'unknown',
    );
    controller.dispose();
  });

  test('missing snore breaths do not invalidate repeated phase alignment', () {
    final controller = MeasurementController();
    final sparseBreaths = [
      for (var start = 0; start <= 20; start += 4) event(start.toDouble(), 4)
    ];
    final sparseSnores = [
      event(0.4, 1.2),
      event(8.4, 1.2),
      event(16.4, 1.2),
    ];
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: sparseSnores.first,
        breaths: sparseBreaths,
        snores: sparseSnores,
      ),
      'wearer',
    );
    controller.dispose();
  });

  test('long merged snore windows remain unknown', () {
    final controller = MeasurementController();
    final longBreaths = [
      for (var start = 0; start <= 28; start += 4) event(start.toDouble(), 4),
    ];
    final mergedSnores = [
      event(0.4, 5.2),
      event(8.4, 4.8),
      event(16.4, 6.0),
    ];

    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: mergedSnores.first,
        breaths: longBreaths,
        snores: mergedSnores,
      ),
      'unknown',
    );
    controller.dispose();
  });

  test('a window crossing too far into the other breath half stays unknown',
      () {
    final controller = MeasurementController();
    final crossingSnores = [
      event(0.4, 3.2),
      event(4.4, 3.2),
      event(8.4, 3.2),
    ];

    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: crossingSnores.first,
        breaths: breaths,
        snores: crossingSnores,
        snoreBoundaryUncertaintyS: yamnetBoundaryUncertaintySeconds,
      ),
      'unknown',
    );
    controller.dispose();
  });

  test('missing breath events remain unknown', () {
    final controller = MeasurementController();
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: alignedSnores.first,
        breaths: const [],
        snores: alignedSnores,
      ),
      'unknown',
    );
    controller.dispose();
  });

  test('a pending source resolves after its breath cycle is available', () {
    final controller = MeasurementController();
    final pendingSnore = alignedSnores.first;

    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: pendingSnore,
        breaths: const [],
        snores: alignedSnores,
      ),
      'unknown',
    );
    expect(
      controller.classifyOfflineSnoreSourceForTest(
        snore: pendingSnore,
        breaths: breaths,
        snores: alignedSnores,
      ),
      'wearer',
    );
    controller.dispose();
  });
}
