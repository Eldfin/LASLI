import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/snore_teacher_sync.dart';

void main() {
  test('audio correlation removes constant BLE transport latency', () {
    final synchronizer = SnoreTeacherSynchronizer();
    const originUs = 2000000;
    const framePeriodUs = 10000;
    const transportDelayUs = 90000;

    int energyFor(int frame) {
      final pulse = frame % 137 >= 12 && frame % 137 <= 27 ? 24.0 : 0.0;
      return (20 + pulse + 6 * math.sin(frame * 0.071)).round();
    }

    for (var frame = 0; frame < 900; frame++) {
      synchronizer.addPhoneEnergy(
        centerMonotonicUs: originUs + frame * framePeriodUs,
        rmsDb: energyFor(frame).toDouble(),
      );
    }

    for (var first = 0; first < 900; first += 5) {
      final slices = List<List<int>>.generate(
        5,
        (slice) => List<int>.filled(32, energyFor(first + slice)),
      );
      final jitterUs = (first ~/ 5) % 7 * 3000;
      synchronizer.addBoardPacket(
        firstFrameSequence: first,
        framePeriodUs: framePeriodUs,
        receivedMonotonicUs: originUs +
            (first + 4) * framePeriodUs +
            transportDelayUs +
            jitterUs,
        slices: slices,
      );
    }
    synchronizer.recompute();

    expect(synchronizer.estimate.method, 'Audioabgleich');
    expect(synchronizer.estimate.correlation, greaterThan(0.8));
    expect(
      synchronizer.frameMonotonicUs(500),
      closeTo(originUs + 500 * framePeriodUs, 20000),
    );
  });

  test('transport timeline remains stable when audio is quiet', () {
    final synchronizer = SnoreTeacherSynchronizer();
    const originUs = 1000000;
    for (var first = 0; first < 50; first += 5) {
      synchronizer.addBoardPacket(
        firstFrameSequence: first,
        framePeriodUs: 10000,
        receivedMonotonicUs: originUs + (first + 4) * 10000 + 70000,
        slices: List<List<int>>.generate(5, (_) => List<int>.filled(32, 4)),
      );
    }

    expect(synchronizer.estimate.ready, isTrue);
    expect(synchronizer.estimate.method, 'BLE-Zeitbasis');
    expect(
      synchronizer.frameMonotonicUs(40)! - synchronizer.frameMonotonicUs(10)!,
      300000,
    );
  });
}
