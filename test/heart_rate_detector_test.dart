import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/processing.dart';

void main() {
  test('rejects short ECG artefact peaks instead of jumping to double rate',
      () {
    final detector = HeartRateDetector(samplingRate);
    final heartRates = <double>[];
    var acceptedPeaks = 0;

    for (var i = 0; i < samplingRate * 14; i++) {
      final t = i / samplingRate;
      final result = detector.update(_syntheticEcgWithTWaveArtefacts(t));
      if (result.isPeak) acceptedPeaks++;
      final heartRate = result.heartRate;
      if (t > 7 && heartRate != null) heartRates.add(heartRate);
    }

    expect(acceptedPeaks, inInclusiveRange(7, 12));
    expect(heartRates, isNotEmpty);
    expect(heartRates.reduce(math.max), lessThan(85));
    expect(heartRates.last, closeTo(60, 5));
  });
}

double _syntheticEcgWithTWaveArtefacts(double t) {
  var signal = 0.02 * math.sin(2 * math.pi * 0.33 * t);
  for (var beat = 1.0; beat < 14; beat += 1.0) {
    signal += _triangle(t - beat, amplitude: 1.20, halfWidth: 0.035);
    signal += _triangle(t - beat - 0.50, amplitude: 0.48, halfWidth: 0.055);
  }
  return signal;
}

double _triangle(
  double dt, {
  required double amplitude,
  required double halfWidth,
}) {
  final distance = dt.abs();
  if (distance >= halfWidth) return 0;
  return amplitude * (1 - distance / halfWidth);
}
