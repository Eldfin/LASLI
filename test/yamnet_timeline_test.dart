import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/processing.dart';
import 'package:lasli_flutter/src/yamnet_raw_snore_tracker.dart';
import 'package:lasli_flutter/src/yamnet_snore_detector.dart';

void main() {
  test('uses the full analyzed audio lookback only at the start boundary', () {
    final center = DateTime(2026, 8, 21, 12);
    final interval = yamnetReportedSnoreInterval(center);

    expect(
      center.difference(interval.startAt),
      const Duration(microseconds: yamnetStartLookbackMicroseconds),
    );
    expect(
      interval.endAt.difference(center),
      const Duration(milliseconds: yamnetBoundaryUncertaintyMilliseconds),
    );
  });

  test('maps the complete YAMNet window onto a delayed breathing timeline', () {
    final startedAt = DateTime(2026, 8, 21, 12);
    final mapped = yamnetWindowOnTimeline(
      YamnetRawSnoreWindow(
        startAt: startedAt.add(const Duration(seconds: 5)),
        endAt: startedAt.add(const Duration(seconds: 6)),
      ),
      fallbackStartedAt: startedAt,
      timelineAnchorAt: startedAt.add(const Duration(seconds: 10)),
      timelineAnchorS: 8,
    );

    expect(mapped, isNotNull);
    expect(mapped!.startS, 3);
    expect(mapped.endS, 4);
  });

  test('uses the common start when no breathing anchor is available', () {
    final startedAt = DateTime(2026, 8, 21, 12);
    final mapped = yamnetWindowOnTimeline(
      YamnetRawSnoreWindow(
        startAt: startedAt.add(const Duration(milliseconds: 2500)),
        endAt: startedAt.add(const Duration(milliseconds: 3400)),
      ),
      fallbackStartedAt: startedAt,
    );

    expect(mapped, isNotNull);
    expect(mapped!.startS, 2.5);
    expect(mapped.endS, 3.4);
  });

  test('localizes a YAMNet-confirmed burst from the 10 ms energy envelope', () {
    const frameUs = 10000;
    final frames = <YamnetAudioEnergyFrame>[];
    for (var centerUs = 5000; centerUs < 4000000; centerUs += frameUs) {
      final inBurst = centerUs >= 1200000 && centerUs < 2300000;
      final shortDip = centerUs >= 1710000 && centerUs < 1780000;
      frames.add(
        YamnetAudioEnergyFrame(
          centerMonotonicUs: centerUs,
          rmsDb: inBurst && !shortDip ? -35 : -60,
        ),
      );
    }

    final burst = localizeYamnetAudioBurst(
      frames,
      inferenceStartMonotonicUs: 1000000,
      inferenceCenterMonotonicUs: 1900000,
      inferenceEndMonotonicUs: 2800000,
    );

    expect(burst, isNotNull);
    expect(burst!.startMonotonicUs, closeTo(1200000, 50000));
    expect(burst.endMonotonicUs, closeTo(2300000, 50000));
  });

  test('does not invent precise boundaries in flat background noise', () {
    final frames = <YamnetAudioEnergyFrame>[
      for (var centerUs = 5000; centerUs < 3000000; centerUs += 10000)
        YamnetAudioEnergyFrame(
          centerMonotonicUs: centerUs,
          rmsDb: -58 + (centerUs % 30000) / 30000,
        ),
    ];

    expect(
      localizeYamnetAudioBurst(
        frames,
        inferenceStartMonotonicUs: 1000000,
        inferenceCenterMonotonicUs: 1500000,
        inferenceEndMonotonicUs: 2000000,
      ),
      isNull,
    );
  });

  test('measurement requires two candidates and keeps the first onset', () {
    final gate = YamnetConsecutiveCandidateGate();
    final firstStart = DateTime(2026, 8, 27, 12);

    final first = gate.update(
      score: 0.62,
      threshold: yamnetMeasurementSnoreThreshold,
      minimumConsecutiveCandidates: yamnetMeasurementMinimumConsecutiveFrames,
      intervalStartAt: firstStart,
    );
    final second = gate.update(
      score: 0.57,
      threshold: yamnetMeasurementSnoreThreshold,
      minimumConsecutiveCandidates: yamnetMeasurementMinimumConsecutiveFrames,
      intervalStartAt: firstStart.add(const Duration(milliseconds: 100)),
    );
    final thirdStart = firstStart.add(const Duration(milliseconds: 200));
    final third = gate.update(
      score: 0.65,
      threshold: yamnetMeasurementSnoreThreshold,
      minimumConsecutiveCandidates: yamnetMeasurementMinimumConsecutiveFrames,
      intervalStartAt: thirdStart,
    );

    expect(first.confirmed, isFalse);
    expect(second.confirmed, isTrue);
    expect(second.firstIntervalStartAt, firstStart);
    expect(third.confirmed, isTrue);
    expect(third.firstIntervalStartAt, thirdStart);
  });

  test('a sub-threshold frame resets measurement confirmation', () {
    final gate = YamnetConsecutiveCandidateGate();
    final start = DateTime(2026, 8, 27, 12);

    gate.update(
      score: 0.60,
      threshold: yamnetMeasurementSnoreThreshold,
      minimumConsecutiveCandidates: yamnetMeasurementMinimumConsecutiveFrames,
      intervalStartAt: start,
    );
    gate.update(
      score: 0.30,
      threshold: yamnetMeasurementSnoreThreshold,
      minimumConsecutiveCandidates: yamnetMeasurementMinimumConsecutiveFrames,
      intervalStartAt: start.add(const Duration(milliseconds: 100)),
    );
    final restarted = gate.update(
      score: 0.70,
      threshold: yamnetMeasurementSnoreThreshold,
      minimumConsecutiveCandidates: yamnetMeasurementMinimumConsecutiveFrames,
      intervalStartAt: start.add(const Duration(milliseconds: 200)),
    );

    expect(restarted.confirmed, isFalse);
    expect(
      restarted.firstIntervalStartAt,
      start.add(const Duration(milliseconds: 200)),
    );
  });

  test('automatic teacher labels keep their high-confidence single hit', () {
    final gate = YamnetConsecutiveCandidateGate();
    final start = DateTime(2026, 8, 27, 12);

    final tooWeak = gate.update(
      score: 0.79,
      threshold: yamnetRawTeacherSnoreThreshold,
      minimumConsecutiveCandidates: 1,
      intervalStartAt: start,
    );
    final accepted = gate.update(
      score: 0.81,
      threshold: yamnetRawTeacherSnoreThreshold,
      minimumConsecutiveCandidates: 1,
      intervalStartAt: start.add(const Duration(milliseconds: 100)),
    );

    expect(tooWeak.confirmed, isFalse);
    expect(accepted.confirmed, isTrue);
  });
}
