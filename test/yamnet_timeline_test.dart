import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/processing.dart';
import 'package:lasli_flutter/src/yamnet_raw_snore_tracker.dart';
import 'package:lasli_flutter/src/yamnet_snore_detector.dart';

void main() {
  YamnetClassScores scores({
    double snoring = 0.10,
    double breathing = 0.05,
    double speech = 0.01,
    double whispering = 0.01,
    double sigh = 0.01,
    double wheeze = 0.01,
    double gasp = 0.01,
    double pant = 0.01,
    double snort = 0.01,
    double cough = 0.01,
    double wind = 0.01,
    double microphoneWind = 0.01,
  }) {
    return YamnetClassScores(
      snoring: snoring,
      breathing: breathing,
      speech: speech,
      whispering: whispering,
      sigh: sigh,
      wheeze: wheeze,
      gasp: gasp,
      pant: pant,
      snort: snort,
      cough: cough,
      wind: wind,
      microphoneWind: microphoneWind,
    );
  }

  test('accepts quiet snoring when competing classes stay low', () {
    final decision = evaluateYamnetSnoreEvidence(
      scores(snoring: 0.10, breathing: 0.18),
    );

    expect(decision.accepted, isTrue);
    expect(decision.score, 0.10);
  });

  test('rejects blowing despite a simultaneous snoring score', () {
    final decision = evaluateYamnetSnoreEvidence(
      scores(snoring: 0.42, microphoneWind: 0.48),
    );

    expect(decision.accepted, isFalse);
    expect(decision.rejectionReason, 'Wind/Pusten');
  });

  test('rejects deep breathing without dominant snoring evidence', () {
    final decision = evaluateYamnetSnoreEvidence(
      scores(snoring: 0.10, breathing: 0.46),
    );

    expect(decision.accepted, isFalse);
    expect(decision.rejectionReason, 'Atmen ohne Schnarch-Evidenz');
  });

  test('rejects speech despite a weak snoring score', () {
    final decision = evaluateYamnetSnoreEvidence(
      scores(snoring: 0.11, speech: 0.38),
    );

    expect(decision.accepted, isFalse);
    expect(decision.rejectionReason, 'Sprache');
  });

  test('adaptive gain lifts a distant event but not flat room noise', () {
    final distantEvent = <YamnetAudioEnergyFrame>[
      for (var centerUs = 5000; centerUs < 4000000; centerUs += 10000)
        YamnetAudioEnergyFrame(
          centerMonotonicUs: centerUs,
          rmsDb: centerUs < 3000000 ? -61 : -45,
        ),
    ];
    final flatNoise = <YamnetAudioEnergyFrame>[
      for (var centerUs = 5000; centerUs < 4000000; centerUs += 10000)
        YamnetAudioEnergyFrame(
          centerMonotonicUs: centerUs,
          rmsDb: -60 + (centerUs % 30000) / 30000,
        ),
    ];

    expect(
      calculateYamnetAdaptiveGainDb(
        distantEvent,
        inferenceStartMonotonicUs: 3000000,
        inferenceEndMonotonicUs: 4000000,
      ),
      closeTo(19, 0.2),
    );
    expect(
      calculateYamnetAdaptiveGainDb(
        flatNoise,
        inferenceStartMonotonicUs: 3000000,
        inferenceEndMonotonicUs: 4000000,
      ),
      0,
    );
  });

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

  test('measurement requires three candidates and keeps the first onset', () {
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
    expect(second.confirmed, isFalse);
    expect(third.confirmed, isTrue);
    expect(third.firstIntervalStartAt, firstStart);
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
      score: 0.03,
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
