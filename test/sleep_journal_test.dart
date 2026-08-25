import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/sleep_journal.dart';

void main() {
  test('snore phase counts every affected minute as a full minute', () {
    expect(snorePhaseSecondsForMinute([null, 0, 0]), 0);
    expect(snorePhaseSecondsForMinute([0, 0.2, 0]), 60);
    expect(snorePhaseSecondsForMinute([null, double.nan]), isNull);
  });

  test('snore loudness keeps the maximum valid value per minute', () {
    expect(maximumSnoreVolumePercent([22, 71, 48]), 71);
    expect(maximumSnoreVolumePercent([null, double.nan]), isNull);
    expect(maximumSnoreVolumePercent([-4, 108]), 100);
  });

  test('stored pose bins normalize legacy angles', () {
    final bin = PoseSnoreBin.fromJson({
      'forehead_roll_deg': 725,
      'forehead_pitch_deg': -541,
      'forehead_yaw_deg': 360,
      'belly_roll_deg': -721,
      'belly_pitch_deg': 540,
      'belly_yaw_deg': 181,
      'sample_count': 1,
      'snore_sample_count': 0,
      'duration_seconds': 60,
      'snore_duration_seconds': 0,
    });

    expect(bin.foreheadRollDeg, 5);
    expect(bin.foreheadPitchDeg, 179);
    expect(bin.foreheadYawDeg, 0);
    expect(bin.bellyRollDeg, -1);
    expect(bin.bellyPitchDeg.abs(), 180);
    expect(bin.bellyYawDeg, -179);
  });

  test('relative angle snore analysis finds strongest and weakest bins', () {
    final stats = SleepMeasurementStats();
    final startedAt = DateTime(2026, 5, 13, 22);
    final endedAt = startedAt.add(const Duration(minutes: 1));

    for (var i = 0; i < 40; i++) {
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: -8,
        isSnoring: i < 30,
      );
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: 22,
        isSnoring: i < 4,
      );
    }

    final analysis = stats
        .summary(startedAt: startedAt, endedAt: endedAt)
        .relativeAngleSnore;

    expect(analysis.sampleCount, 80);
    expect(analysis.mostSnoredBin?.rangeLabel, '-15 bis 0 deg');
    expect(analysis.mostSnoredBin?.snoreProbability, closeTo(0.75, 0.001));
    expect(analysis.leastSnoredBin?.rangeLabel, '15 bis 30 deg');
    expect(analysis.leastSnoredBin?.snoreProbability, closeTo(0.10, 0.001));
    expect(analysis.probabilitySpread, closeTo(0.65, 0.001));
    expect(analysis.correlation, isNegative);
  });

  test('sleep summary reads older json without angle snore analysis', () {
    final summary = SleepMeasurementSummary.fromJson({
      'started_at': '2026-05-13T22:00:00.000',
      'ended_at': '2026-05-13T22:10:00.000',
      'duration_seconds': 600,
      'mean_heart_rate_bpm': 62,
      'mean_breathing_rate_per_min': 14,
      'mean_relative_angle_deg': 8,
      'snore_time_fraction': 0.2,
    });

    expect(summary.relativeAngleSnore.hasData, isFalse);
    expect(summary.relativeAngleSnore.bins, isEmpty);
    expect(summary.poseSnore.hasData, isFalse);
    expect(summary.poseSnore.bins, isEmpty);
  });

  test('pose snore analysis ranks by snore time fraction not total time', () {
    final stats = SleepMeasurementStats();
    final startedAt = DateTime(2026, 5, 13, 22);
    final endedAt = startedAt.add(const Duration(minutes: 6));

    for (var i = 0; i < 300; i++) {
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: 0,
        isSnoring: i < 30,
        foreheadRollDeg: 0,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 0,
        bellyRollDeg: 0,
        bellyPitchDeg: 0,
        bellyYawDeg: 0,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
    }
    for (var i = 0; i < 30; i++) {
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: 90,
        isSnoring: i < 15,
        foreheadRollDeg: 60,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 0,
        bellyRollDeg: -30,
        bellyPitchDeg: 0,
        bellyYawDeg: 0,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
    }

    final analysis =
        stats.summary(startedAt: startedAt, endedAt: endedAt).poseSnore;
    final top = analysis.topRiskBins();
    final lowest = analysis.lowestRiskBins(limit: 1);

    expect(analysis.hasData, isTrue);
    expect(top, isNotEmpty);
    expect(top.first.foreheadRollDeg, closeTo(60, 0.001));
    expect(top.first.bellyRollDeg, closeTo(-30, 0.001));
    expect(top.first.snoreDurationSeconds, 15);
    expect(top.first.snoreProbability, closeTo(0.5, 0.001));
    expect(lowest.single.foreheadRollDeg, closeTo(0, 0.001));
    expect(lowest.single.bellyRollDeg, closeTo(0, 0.001));
    expect(lowest.single.snoreProbability, closeTo(0.1, 0.001));
  });

  test('pose snore analysis exposes rotation and tilt features', () {
    final stats = SleepMeasurementStats();
    final startedAt = DateTime(2026, 5, 13, 22);
    final endedAt = startedAt.add(const Duration(minutes: 2));

    for (var i = 0; i < 40; i++) {
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: 0,
        isSnoring: i < 4,
        foreheadRollDeg: 0,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 0,
        bellyRollDeg: 0,
        bellyPitchDeg: 0,
        bellyYawDeg: 0,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: 0,
        isSnoring: i < 24,
        foreheadRollDeg: 0,
        foreheadPitchDeg: 48,
        foreheadYawDeg: -55,
        bellyRollDeg: 0,
        bellyPitchDeg: -35,
        bellyYawDeg: 62,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
    }

    final analysis =
        stats.summary(startedAt: startedAt, endedAt: endedAt).poseSnore;
    final top = analysis.topRiskBins();

    expect(top.first.foreheadRollDeg, closeTo(0, 0.001));
    expect(top.first.foreheadPitchDeg, closeTo(48, 0.001));
    expect(top.first.foreheadYawDeg, closeTo(-55, 0.001));
    expect(top.first.relativePitchCenterDeg, closeTo(83, 0.001));
    expect(top.first.snoreProbability, closeTo(0.6, 0.001));
    expect(analysis.angleFeatures.length, 6);
    expect(
      analysis.angleFeatures
          .firstWhere((feature) => feature.key == 'forehead_tilt')
          .mostSnoredBin
          ?.rangeLabel,
      '30 bis 60 deg',
    );
    expect(
      analysis.angleFeatures
          .firstWhere((feature) => feature.key == 'relative_tilt')
          .mostSnoredBin
          ?.rangeLabel,
      '60 bis 90 deg',
    );
  });

  test('visible pose estimate pools matching yaw bins by observed time', () {
    final stats = SleepMeasurementStats();
    final startedAt = DateTime(2026, 7, 26, 22);

    for (var i = 0; i < 6; i++) {
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: 0,
        isSnoring: true,
        durationSeconds: 60,
        snoreFraction: 0.1,
        foreheadRollDeg: 0,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 0,
        bellyRollDeg: 0,
        bellyPitchDeg: 0,
        bellyYawDeg: 0,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
      stats.add(
        heartRate: null,
        breathingRate: null,
        relativeAngleDeg: 0,
        isSnoring: true,
        durationSeconds: 60,
        snoreFraction: 0.5,
        foreheadRollDeg: 0,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 120,
        bellyRollDeg: 0,
        bellyPitchDeg: 0,
        bellyYawDeg: 120,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
    }

    final analysis = stats
        .summary(
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(minutes: 12)),
        )
        .poseSnore;
    final estimate = analysis.estimateAtVisiblePose(
      foreheadRollDeg: 0,
      foreheadPitchDeg: 0,
      bellyRollDeg: 0,
      bellyPitchDeg: 0,
    );

    expect(estimate, isNotNull);
    expect(estimate!.probability, closeTo(0.3, 0.001));
    expect(estimate.observedSeconds, closeTo(720, 0.001));
    expect(estimate.matchingBinCount, 2);
    expect(
      analysis.estimateAtVisiblePose(
        foreheadRollDeg: 120,
        foreheadPitchDeg: 120,
        bellyRollDeg: 120,
        bellyPitchDeg: 120,
      ),
      isNull,
    );
  });

  test('sleep score improves when heart breathing and snore values decrease',
      () {
    final startedAt = DateTime(2026, 7, 13, 22);
    SleepMeasurementSummary metrics({
      required double heartRate,
      required double breathingRate,
      required double snoreFraction,
    }) {
      return SleepMeasurementSummary(
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(hours: 8)),
        durationSeconds: 8 * 3600,
        meanHeartRateBpm: heartRate,
        meanBreathingRatePerMin: breathingRate,
        meanRelativeAngleDeg: null,
        snoreTimeFraction: snoreFraction,
        relativeAngleSnore: const RelativeAngleSnoreAnalysis.empty(),
        poseSnore: const PoseSnoreAnalysis.empty(),
      );
    }

    final better = computeSleepScore(
      const {},
      metrics(heartRate: 52, breathingRate: 11, snoreFraction: 0.03),
    );
    final worse = computeSleepScore(
      const {},
      metrics(heartRate: 88, breathingRate: 24, snoreFraction: 0.38),
    );

    expect(better, greaterThan(worse));
  });

  test('temperature score rewards a plausible range but not lower values', () {
    final normal = computeSleepMetricScores(
      meanHeartRateBpm: 55,
      meanBreathingRatePerMin: 14,
      snoreTimeFraction: 0.05,
      meanEarTemperatureC: 36.4,
    );
    final tooLow = computeSleepMetricScores(
      meanHeartRateBpm: 55,
      meanBreathingRatePerMin: 14,
      snoreTimeFraction: 0.05,
      meanEarTemperatureC: 34.2,
    );
    final invalid = computeSleepMetricScores(
      meanHeartRateBpm: 55,
      meanBreathingRatePerMin: 14,
      snoreTimeFraction: 0.05,
      meanEarTemperatureC: 2,
    );

    expect(normal.temperatureScore, 100);
    expect(tooLow.temperatureScore, lessThan(normal.temperatureScore!));
    expect(normal.overallScore, greaterThan(tooLow.overallScore));
    expect(invalid.temperatureScore, isNull);
  });

  test('sleep summary stores only plausible ear temperatures', () {
    final stats = SleepMeasurementStats();
    final startedAt = DateTime(2026, 7, 13, 22);
    stats.add(
      heartRate: 55,
      breathingRate: 14,
      earTemperatureC: 36.2,
      relativeAngleDeg: 0,
      isSnoring: false,
    );
    stats.add(
      heartRate: 55,
      breathingRate: 14,
      earTemperatureC: 2,
      relativeAngleDeg: 0,
      isSnoring: false,
    );
    final summary = stats.summary(
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(hours: 8)),
    );
    final restored = SleepMeasurementSummary.fromJson(summary.toJson());

    expect(summary.meanEarTemperatureC, closeTo(36.2, 0.001));
    expect(restored.meanEarTemperatureC, closeTo(36.2, 0.001));
  });

  test('question correlations target heart and breathing separately', () {
    final question = SleepQuestion(
      id: 'test_answer',
      title: 'Testantwort',
      prompt: 'Test?',
      phase: SleepQuestionPhase.evening,
      type: SleepQuestionType.scale,
      isCustom: true,
    );
    final records = <SleepSessionRecord>[];
    for (var i = 1; i <= 5; i++) {
      final startedAt = DateTime(2026, 7, i, 22);
      final metrics = SleepMeasurementSummary(
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(hours: 8)),
        durationSeconds: 8 * 3600,
        meanHeartRateBpm: 85 - i * 5,
        meanBreathingRatePerMin: 10 + i * 2,
        meanRelativeAngleDeg: null,
        snoreTimeFraction: 0.1,
        relativeAngleSnore: const RelativeAngleSnoreAnalysis.empty(),
        poseSnore: const PoseSnoreAnalysis.empty(),
      );
      records.add(
        SleepSessionRecord(
          id: 'session_$i',
          createdAt: startedAt,
          metrics: metrics,
          answers: {'test_answer': i},
          score: computeSleepScore(const {}, metrics),
          tips: const [],
        ),
      );
    }

    final result =
        computeSleepQuestionPhysiologyCorrelations(records, [question]);

    expect(result, hasLength(1));
    expect(result.single.prompt, 'Test?');
    expect(result.single.lowLabel, isNull);
    expect(result.single.highLabel, isNull);
    expect(result.single.heartRateCorrelation, closeTo(-1, 0.0001));
    expect(result.single.breathingRateCorrelation, closeTo(1, 0.0001));
    expect(result.single.heartRateSampleCount, 5);
    expect(result.single.breathingRateSampleCount, 5);
  });

  test('pose clusters retain fractional snore time and physiology means', () {
    final stats = SleepMeasurementStats();
    final startedAt = DateTime(2026, 7, 13, 22);
    for (var i = 0; i < 5; i++) {
      stats.add(
        heartRate: 70,
        breathingRate: 18,
        relativeAngleDeg: 0,
        isSnoring: true,
        snoreFraction: 0.1,
        durationSeconds: 60,
        foreheadRollDeg: 0,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 0,
        bellyRollDeg: 0,
        bellyPitchDeg: 0,
        bellyYawDeg: 0,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
      stats.add(
        heartRate: 55,
        breathingRate: 11,
        relativeAngleDeg: 0,
        isSnoring: true,
        snoreFraction: 0.3,
        durationSeconds: 60,
        foreheadRollDeg: 80,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 0,
        bellyRollDeg: -80,
        bellyPitchDeg: 0,
        bellyYawDeg: 0,
        hasForeheadPose: true,
        hasBellyPose: true,
      );
    }

    final analysis = stats
        .summary(
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(minutes: 10)),
        )
        .poseSnore;

    expect(analysis.topRiskBins(limit: 1).single.snoreProbability,
        closeTo(0.3, 0.0001));
    expect(analysis.lowestRiskBins(limit: 1).single.snoreProbability,
        closeTo(0.1, 0.0001));
    expect(analysis.lowestHeartRateBins().single.meanHeartRateBpm,
        closeTo(55, 0.0001));
    expect(analysis.lowestBreathingRateBins().single.meanBreathingRatePerMin,
        closeTo(11, 0.0001));
  });
}
