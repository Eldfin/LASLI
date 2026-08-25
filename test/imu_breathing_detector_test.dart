import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/processing.dart';

void main() {
  test('detects breathing rate from dominant belly IMU axis', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    BreathingResult? lastStable;

    for (var i = 0; i < mg24SamplingRate * 38; i++) {
      final t = i / mg24SamplingRate;
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.35 * math.sin(2 * math.pi * 0.25 * t + 0.4),
        rollDeg: 0.20 * math.sin(2 * math.pi * 0.18 * t),
        pitchDeg: 3.8 * math.sin(2 * math.pi * 0.25 * t),
        ax: 0.010 * math.sin(2 * math.pi * 0.25 * t),
        ay: 0.003 * math.sin(2 * math.pi * 0.25 * t + 0.35),
        az: 1.0 + 0.004 * math.sin(2 * math.pi * 0.25 * t + 0.7),
        gx: null,
        gy: null,
        gz: null,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (t > 24 && result?.breathingRate != null) {
        lastStable = result;
      }
    }

    expect(lastStable, isNotNull);
    expect(lastStable!.breathingRate, closeTo(15, 1.5));
    expect(lastStable.axisLabel, '3D-Kombi');
    expect(lastStable.qualityPercent, greaterThan(50));
  });

  test('keeps IMU breathing quality low for unattached random motion', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    final random = math.Random(12);
    BreathingResult? last;

    for (var i = 0; i < mg24SamplingRate * 38; i++) {
      final t = i / mg24SamplingRate;
      final drift = 0.0004 * math.sin(2 * math.pi * 0.035 * t);
      last = detector.update(
        sampleTimeS: t,
        angleDeg: (random.nextDouble() - 0.5) * 2.6 + drift,
        rollDeg: (random.nextDouble() - 0.5) * 3.2,
        pitchDeg: (random.nextDouble() - 0.5) * 2.9,
        ax: drift + (random.nextDouble() - 0.5) * 0.0015,
        ay: (random.nextDouble() - 0.5) * 0.0015,
        az: 1.0 + (random.nextDouble() - 0.5) * 0.0015,
        gx: null,
        gy: null,
        gz: null,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
    }

    expect(last, isNotNull);
    expect(last!.qualityPercent, lessThan(45));
  });

  test('keeps belly breathing stable through snore-like artifacts', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    final random = math.Random(21);
    BreathingResult? lastStable;
    var breathPeaks = 0;

    for (var i = 0; i < mg24SamplingRate * 48; i++) {
      final t = i / mg24SamplingRate;
      final breath = math.sin(2 * math.pi * 0.25 * t);
      final inSnoreBurst =
          (t > 10 && t < 16) || (t > 24 && t < 30) || (t > 37 && t < 41);
      final snoreVibration = inSnoreBurst
          ? 0.010 * math.sin(2 * math.pi * 7.5 * t) +
              (random.nextDouble() - 0.5) * 0.006
          : 0.0;
      final movement = (t > 32 && t < 33.2)
          ? 0.018 * math.sin(2 * math.pi * 0.9 * (t - 32))
          : 0.0;
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: 0.010 * breath + snoreVibration + movement,
        ay: 0.004 * math.sin(2 * math.pi * 0.25 * t + 0.4) +
            snoreVibration * 0.4,
        az: 1.0 + 0.003 * math.sin(2 * math.pi * 0.25 * t + 0.8),
        gx: inSnoreBurst ? 8.0 * math.sin(2 * math.pi * 7.5 * t) : 0.2,
        gy: inSnoreBurst ? 5.0 * math.sin(2 * math.pi * 6.8 * t) : 0.1,
        gz: movement == 0.0 ? 0.1 : 18.0,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (result?.isBreath == true) breathPeaks++;
      if (t > 34 && result?.breathingRate != null) {
        lastStable = result;
      }
    }

    expect(breathPeaks, greaterThanOrEqualTo(8));
    expect(breathPeaks, lessThanOrEqualTo(14));
    expect(lastStable, isNotNull);
    expect(lastStable!.breathingRate, inInclusiveRange(11, 17));
    expect(lastStable.qualityPercent, greaterThan(45));
  });

  test('rejects small exhale bumps and preserves trough depth', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    final valuesByCycle = <int, List<double>>{};
    var breathPeaks = 0;

    for (var i = 0; i < mg24SamplingRate * 52; i++) {
      final t = i / mg24SamplingRate;
      final phase = (t * 0.25) % 1.0;
      final breath = math.sin(2 * math.pi * 0.25 * t);
      final exhaleBump = phase > 0.30 && phase < 0.72
          ? 0.0026 * math.sin(2 * math.pi * 2.4 * t)
          : 0.0;
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: 0.010 * breath + exhaleBump,
        ay: 0.004 * math.sin(2 * math.pi * 0.25 * t + 0.35),
        az: 1.0 + 0.003 * math.sin(2 * math.pi * 0.25 * t + 0.7),
        gx: exhaleBump == 0 ? 0.1 : 1.6 * math.sin(2 * math.pi * 2.4 * t),
        gy: 0.1,
        gz: 0.1,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (result == null || t < 16) continue;
      if (result.isBreath) breathPeaks++;
      final cycle = (t / 4.0).floor();
      valuesByCycle
          .putIfAbsent(cycle, () => <double>[])
          .add(result.filteredResp);
    }

    final cycleSpans = valuesByCycle.values
        .where((values) => values.length > mg24SamplingRate * 2)
        .map((values) => values.reduce(math.max) - values.reduce(math.min))
        .where((span) => span.isFinite && span > 0)
        .toList(growable: false);
    final typicalSpan = median(cycleSpans);
    final weakCycles =
        cycleSpans.where((span) => span < typicalSpan * 0.55).length;

    expect(breathPeaks, inInclusiveRange(7, 11));
    expect(cycleSpans.length, greaterThanOrEqualTo(7));
    expect(weakCycles, lessThanOrEqualTo(1));
  });

  test('keeps broad breath peaks and rejects small shoulders', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    var breathPeaks = 0;
    BreathingResult? lastStable;

    for (var i = 0; i < mg24SamplingRate * 46; i++) {
      final t = i / mg24SamplingRate;
      final phase = (t * 0.25) % 1.0;
      final sine = math.sin(2 * math.pi * 0.25 * t);
      final broadBreath =
          sine >= 0 ? 0.72 * sine + 0.28 * math.pow(sine, 0.42) : sine;
      final shoulder = phase > 0.42 && phase < 0.72
          ? 0.0020 * math.sin(2 * math.pi * 2.1 * t)
          : 0.0;
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: 0.010 * broadBreath + shoulder,
        ay: 0.0035 * broadBreath,
        az: 1.0 + 0.003 * broadBreath,
        gx: shoulder == 0 ? 0.1 : 1.3 * math.sin(2 * math.pi * 2.1 * t),
        gy: 0.1,
        gz: 0.1,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (result?.isBreath == true) breathPeaks++;
      if (t > 28 && result?.breathingRate != null) {
        lastStable = result;
      }
    }

    expect(breathPeaks, inInclusiveRange(7, 11));
    expect(lastStable, isNotNull);
    expect(lastStable!.breathingRate, closeTo(15, 2.0));
  });

  test('marks flatter plateau-like breath peaks', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    final peakTimes = <double>[];

    for (var i = 0; i < mg24SamplingRate * 48; i++) {
      final t = i / mg24SamplingRate;
      final sine = math.sin(2 * math.pi * 0.25 * t);
      final plateau = sine > 0.55 ? 0.55 + (sine - 0.55) * 0.45 : sine;
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: 0.010 * plateau,
        ay: 0.004 * math.sin(2 * math.pi * 0.25 * t + 0.35),
        az: 1.0 + 0.003 * math.sin(2 * math.pi * 0.25 * t + 0.7),
        gx: 0.1,
        gy: 0.1,
        gz: 0.1,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (t > 14 && result?.isBreath == true) {
        peakTimes.add(result!.breathPeakTime ?? t);
      }
    }

    expect(peakTimes.length, inInclusiveRange(7, 10));
  });

  test('keeps amplitude stable when breathing direction drifts slightly', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    final peakValues = <double>[];

    for (var i = 0; i < mg24SamplingRate * 56; i++) {
      final t = i / mg24SamplingRate;
      final breath = math.sin(2 * math.pi * 0.25 * t);
      final directionDrift = 0.22 * math.sin(2 * math.pi * 0.018 * t);
      final axWeight = math.cos(directionDrift);
      final ayWeight = math.sin(directionDrift);
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: 0.010 * axWeight * breath,
        ay: 0.010 * ayWeight * breath + 0.002,
        az: 1.0 + 0.003 * math.sin(2 * math.pi * 0.25 * t + 0.5),
        gx: 0.15,
        gy: 0.15,
        gz: 0.15,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (t > 20 && result?.isBreath == true) {
        peakValues.add(result!.breathPeakValue ?? result.filteredResp);
      }
    }

    expect(peakValues.length, greaterThanOrEqualTo(7));
    final sorted = [...peakValues]..sort();
    final low = sorted[(sorted.length * 0.15).floor()];
    final high = sorted[(sorted.length * 0.85).floor()];
    expect(low / high, greaterThan(0.62));
  });

  test('keeps signal continuous across rate changes and breath holds', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    final values = <double>[];
    final peakTimes = <double>[];

    var phase = 0.0;
    for (var i = 0; i < mg24SamplingRate * 72; i++) {
      final t = i / mg24SamplingRate;
      final frequency = t < 24
          ? 0.16
          : t < 42
              ? 0.32
              : t < 52
                  ? 0.0
                  : 0.23;
      phase += 2 * math.pi * frequency / mg24SamplingRate;
      final breath = frequency == 0.0 ? 0.0 : math.sin(phase);
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: 0.010 * breath,
        ay: 0.004 * math.sin(phase + 0.35),
        az: 1.0 + 0.003 * math.sin(phase + 0.7),
        gx: 0.12,
        gy: 0.12,
        gz: 0.12,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (result == null || t < 10) continue;
      values.add(result.filteredResp);
      if (result.isBreath) {
        peakTimes.add(result.breathPeakTime ?? t);
      }
    }

    final maxStep = <double>[
      for (var i = 1; i < values.length; i++) (values[i] - values[i - 1]).abs(),
    ].reduce(math.max);
    final fastPeaks = peakTimes.where((time) => time > 27 && time < 42).length;
    final heldPeaks = peakTimes.where((time) => time > 44 && time < 52).length;
    final resumedPeaks =
        peakTimes.where((time) => time > 56 && time < 70).length;

    expect(maxStep, lessThan(0.45));
    expect(fastPeaks, greaterThanOrEqualTo(3));
    expect(heldPeaks, lessThanOrEqualTo(1));
    expect(resumedPeaks, greaterThanOrEqualTo(2));
  });

  test('combines breathing motion distributed over all acceleration axes', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    BreathingResult? lastStable;
    var breathPeaks = 0;

    for (var i = 0; i < mg24SamplingRate * 54; i++) {
      final t = i / mg24SamplingRate;
      final breath = math.sin(2 * math.pi * 0.24 * t);
      final directionPhase = 2 * math.pi * 0.028 * t;
      final dx = math.cos(directionPhase) * 0.78;
      final dy = math.sin(directionPhase) * 0.54;
      final dz = 0.30 * math.sin(directionPhase + 0.7);
      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: 0.009 * dx * breath,
        ay: 0.009 * dy * breath,
        az: 1.0 + 0.009 * dz * breath,
        gx: 0.2,
        gy: 0.2,
        gz: 0.2,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (result?.isBreath == true) breathPeaks++;
      if (t > 30 && result?.breathingRate != null) {
        lastStable = result;
      }
    }

    expect(breathPeaks, greaterThanOrEqualTo(5));
    expect(lastStable, isNotNull);
    expect(lastStable!.breathingRate, closeTo(14.4, 2.0));
    expect(lastStable.axisLabel, '3D-Kombi');
  });

  test('recovers breath peaks quickly after a posture change artifact', () {
    final detector = ImuBreathingRateDetector(mg24SamplingRate);
    final postMotionValues = <double>[];
    final postMotionPeaks = <double>[];

    for (var i = 0; i < mg24SamplingRate * 48; i++) {
      final t = i / mg24SamplingRate;
      final breath = math.sin(2 * math.pi * 0.24 * t);
      final inTurn = t >= 18 && t < 20.2;
      final turnProgress = t < 18
          ? 0.0
          : t > 20.2
              ? 1.0
              : (t - 18) / 2.2;
      final baseAx = 0.18 * turnProgress;
      final baseAy = -0.10 * turnProgress;
      final baseAz = 1.0 - 0.035 * turnProgress;
      final movement =
          inTurn ? 0.05 * math.sin(2 * math.pi * 1.1 * (t - 18)) : 0.0;

      final result = detector.update(
        sampleTimeS: t,
        angleDeg: 0.0,
        rollDeg: null,
        pitchDeg: null,
        ax: baseAx + 0.010 * breath + movement,
        ay: baseAy + 0.004 * math.sin(2 * math.pi * 0.24 * t + 0.35),
        az: baseAz + 0.003 * math.sin(2 * math.pi * 0.24 * t + 0.7),
        gx: inTurn ? 42.0 : 0.15,
        gy: inTurn ? 35.0 : 0.15,
        gz: inTurn ? 28.0 : 0.15,
        qw: null,
        qx: null,
        qy: null,
        qz: null,
      );
      if (result == null || t < 23) continue;
      postMotionValues.add(result.filteredResp);
      if (result.isBreath) {
        postMotionPeaks.add(result.breathPeakTime ?? t);
      }
    }

    final lateValues = postMotionValues.skip(mg24SamplingRate * 8).toList();
    final lateSpan = lateValues.reduce(math.max) - lateValues.reduce(math.min);
    final firstLate = lateValues.take(mg24SamplingRate * 5).toList();
    final lastLate = lateValues
        .skip(math.max(0, lateValues.length - mg24SamplingRate * 5))
        .toList();
    final firstMean = firstLate.reduce((a, b) => a + b) / firstLate.length;
    final lastMean = lastLate.reduce((a, b) => a + b) / lastLate.length;

    expect(postMotionPeaks.where((time) => time > 24 && time < 44).length,
        greaterThanOrEqualTo(3));
    expect(lateSpan, greaterThan(0.05));
    expect(lateSpan, lessThan(2.6));
    expect((lastMean - firstMean).abs(), lessThan(0.45));
  });

  test('IMU snore vibration detector detects a vibration burst', () {
    final detector = ImuSnoreVibrationDetector(mg24SamplingRate);

    for (var i = 0; i < mg24SamplingRate * 34; i++) {
      final t = i / mg24SamplingRate;
      final breath = math.sin(2 * math.pi * 0.24 * t);
      final inSnore = t >= 21.0 && t <= 22.3;
      final vibration = inSnore ? math.sin(2 * math.pi * 7.5 * t) : 0.0;
      detector.update(
        roleKey: 'belly',
        timeS: t,
        ax: 0.010 * breath + 0.0045 * vibration,
        ay: 0.004 * math.sin(2 * math.pi * 0.24 * t + 0.35) +
            0.0020 * vibration,
        az: 1.0 + 0.003 * math.sin(2 * math.pi * 0.24 * t + 0.7),
        gx: 0.12 + 4.8 * vibration,
        gy: 0.10 + 2.6 * vibration,
        gz: 0.10,
      );
    }

    final evidence = detector.evidenceAt(21.65);
    expect(evidence.hasData, isTrue);
    expect(evidence.vibrationScore, greaterThan(0.35));
    expect(evidence.quietScore, lessThan(0.55));
  });

  test('IMU snore vibration detector stays quiet without body vibration', () {
    final detector = ImuSnoreVibrationDetector(mg24SamplingRate);

    for (var i = 0; i < mg24SamplingRate * 34; i++) {
      final t = i / mg24SamplingRate;
      final breath = math.sin(2 * math.pi * 0.24 * t);
      detector.update(
        roleKey: 'belly',
        timeS: t,
        ax: 0.010 * breath,
        ay: 0.004 * math.sin(2 * math.pi * 0.24 * t + 0.35),
        az: 1.0 + 0.003 * math.sin(2 * math.pi * 0.24 * t + 0.7),
        gx: 0.12,
        gy: 0.10,
        gz: 0.10,
      );
    }

    final evidence = detector.evidenceAt(21.65);
    expect(evidence.hasData, isTrue);
    expect(evidence.vibrationScore, lessThan(0.28));
    expect(evidence.quietScore, greaterThan(0.35));
  });
}
