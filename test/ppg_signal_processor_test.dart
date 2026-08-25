import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/processing.dart';

void main() {
  test('filters drifting PPG and finds stable pulse peaks', () {
    final processor = PpgSignalProcessor(sampleRateHz: 25, maximumSamples: 150);
    final random = math.Random(41);
    PpgProcessingResult? result;
    final rawValues = <double>[];

    for (var i = 0; i < 25 * 24; i++) {
      final t = i / 25.0;
      final pulse = _pulseAt(t, bpm: 72);
      final raw = 118000 +
          2400 * pulse +
          1600 * math.sin(2 * math.pi * 0.035 * t) +
          (random.nextDouble() - 0.5) * 360;
      rawValues.add(raw);
      result = processor.update(raw);
    }

    expect(result, isNotNull);
    expect(result!.heartRateBpm, isNotNull);
    expect(result.heartRateBpm!, closeTo(72, 4));
    expect(result.peaks.where((peak) => peak).length, inInclusiveRange(5, 9));
    expect(result.waveform.length, 150);
    expect(result.rawWaveform, rawValues.sublist(rawValues.length - 150));

    final rawRecent = rawValues.sublist(rawValues.length - 150);
    expect(_medianStep(result.waveform), lessThan(_medianStep(rawRecent)));
  });

  test('detects inverted and broad PPG pulses without moving to troughs', () {
    final processor = PpgSignalProcessor(sampleRateHz: 25, maximumSamples: 150);
    final random = math.Random(7);
    PpgProcessingResult? result;

    for (var i = 0; i < 25 * 26; i++) {
      final t = i / 25.0;
      final pulse = math.pow(_pulseAt(t, bpm: 66), 0.42).toDouble();
      final raw = 132000 -
          3000 * pulse +
          900 * math.sin(2 * math.pi * 0.025 * t) +
          (random.nextDouble() - 0.5) * 260;
      result = processor.update(raw);
    }

    expect(result, isNotNull);
    expect(result!.heartRateBpm, isNotNull);
    expect(result.heartRateBpm!, closeTo(66, 4));
    final peakIndices = <int>[
      for (var i = 0; i < result.peaks.length; i++)
        if (result.peaks[i]) i,
    ];
    expect(peakIndices.length, inInclusiveRange(5, 8));
    for (final index in peakIndices) {
      final start = math.max(0, index - 2);
      final end = math.min(result.waveform.length, index + 3);
      final local = result.waveform.sublist(start, end);
      expect(
          result.waveform[index], greaterThanOrEqualTo(percentile(local, 75)));
    }
  });

  test('resets the visible signal after a large skin-contact level step', () {
    final processor = PpgSignalProcessor(sampleRateHz: 25, maximumSamples: 150);
    PpgProcessingResult? result;

    for (var i = 0; i < 25 * 7; i++) {
      final t = i / 25.0;
      result = processor.update(62000 + 900 * _pulseAt(t, bpm: 72));
    }
    expect(result!.waveform.length, 150);

    result = processor.update(128000);
    expect(result.waveform.length, 1);
    expect(result.peaks.where((peak) => peak), isEmpty);
    expect(result.heartRateBpm, isNull);

    for (var i = 1; i < 25 * 10; i++) {
      final t = i / 25.0;
      result = processor.update(128000 + 2600 * _pulseAt(t, bpm: 72));
    }
    expect(result!.heartRateBpm, closeTo(72, 4));
  });

  test('rejects narrow mini spikes between real pulse waves', () {
    final processor = PpgSignalProcessor(sampleRateHz: 25, maximumSamples: 150);
    final random = math.Random(19);
    PpgProcessingResult? result;

    for (var i = 0; i < 25 * 28; i++) {
      final t = i / 25.0;
      final period = 60 / 75.0;
      final phase = (t % period) / period;
      final miniSpike = phase > 0.64 && phase < 0.68 ? 650.0 : 0.0;
      final raw = 122000 +
          2700 * _pulseAt(t, bpm: 75) +
          miniSpike +
          (random.nextDouble() - 0.5) * 240;
      result = processor.update(raw);
    }

    expect(result, isNotNull);
    expect(result!.heartRateBpm, closeTo(75, 4));
    expect(result.peaks.where((peak) => peak).length, inInclusiveRange(6, 9));
  });

  test('smooths strong high-frequency PPG jitter without inventing beats', () {
    final processor = PpgSignalProcessor(sampleRateHz: 25, maximumSamples: 150);
    final random = math.Random(83);
    PpgProcessingResult? result;
    final rawRecent = <double>[];

    for (var i = 0; i < 25 * 28; i++) {
      final t = i / 25.0;
      final alternatingNoise = i.isEven ? 720.0 : -720.0;
      final raw = 126000 +
          3200 * _pulseAt(t, bpm: 78) +
          alternatingNoise +
          (random.nextDouble() - 0.5) * 620;
      rawRecent.add(raw);
      if (rawRecent.length > 150) rawRecent.removeAt(0);
      result = processor.update(raw);
    }

    expect(result, isNotNull);
    expect(result!.heartRateBpm, closeTo(78, 5));
    expect(result.peaks.where((peak) => peak).length, inInclusiveRange(6, 9));
    expect(
        _medianStep(result.waveform), lessThan(_medianStep(rawRecent) * 0.18));
  });

  test('shared physiological filter turns promptly after a deep inhale', () {
    final filter = PhysiologicalSignalFilter(
      sampleRateHz: 25,
      baselineSeconds: 10,
      lowPassCutoffHz: 0.75,
      medianWindowSize: 3,
    );
    final filteredAfterWarmup = <({double time, double value})>[];

    for (var i = 0; i < 25 * 16; i++) {
      final t = i / 25.0;
      final value = t < 8
          ? 0.0
          : t < 10
              ? (t - 8) / 2
              : t < 12
                  ? 1 - (t - 10) / 2
                  : 0.0;
      final filtered = filter.update(value);
      if (t >= 8) filteredAfterWarmup.add((time: t, value: filtered));
    }

    final peak = filteredAfterWarmup.reduce(
      (a, b) => a.value >= b.value ? a : b,
    );
    expect(peak.time, lessThanOrEqualTo(10.40));
    final shortlyAfterPeak = filteredAfterWarmup
        .firstWhere((sample) => sample.time >= peak.time + 0.32);
    expect(shortlyAfterPeak.value, lessThan(peak.value));
  });
}

double _pulseAt(double timeS, {required double bpm}) {
  final period = 60 / bpm;
  final phase = (timeS % period) / period;
  final main = math.exp(-0.5 * math.pow((phase - 0.28) / 0.075, 2));
  final shoulder = 0.16 * math.exp(-0.5 * math.pow((phase - 0.48) / 0.055, 2));
  return main + shoulder;
}

double _medianStep(List<double> values) {
  return median(<double>[
    for (var i = 1; i < values.length; i++) (values[i] - values[i - 1]).abs(),
  ]);
}
