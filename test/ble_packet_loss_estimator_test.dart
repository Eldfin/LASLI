import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/mg24_sensor_client.dart';

void main() {
  test('reports zero loss for a complete 25 Hz MG24 stream', () {
    final estimator = BlePacketLossEstimator();
    final startedAt = DateTime(2026, 1, 1);
    double? result;

    for (var i = 0; i <= 30; i++) {
      result = estimator.update(
        packetSequence: i,
        receivedAt: startedAt.add(Duration(milliseconds: i * 40)),
      );
    }

    expect(result, 0);
  });

  test('counts missing 40 ms packets from sensor timestamps', () {
    final estimator = BlePacketLossEstimator();
    final startedAt = DateTime(2026, 1, 1);
    var packetSequence = 0;
    double? result;

    for (var i = 0; i <= 30; i++) {
      if (i > 0) packetSequence += i == 10 || i == 20 ? 2 : 1;
      result = estimator.update(
        packetSequence: packetSequence,
        receivedAt: startedAt.add(Duration(milliseconds: i * 40)),
      );
    }

    expect(result, closeTo(6.25, 0.01));
  });

  test('does not mistake irregular arrival times for packet loss', () {
    final estimator = BlePacketLossEstimator();
    final startedAt = DateTime(2026, 1, 1);
    double? result;

    for (var i = 0; i <= 30; i++) {
      result = estimator.update(
        packetSequence: i,
        receivedAt: startedAt.add(Duration(milliseconds: i * i + i * 20)),
      );
    }

    expect(result, 0);
  });

  test('reports summary loss inside a 20 second one hertz window', () {
    final estimator = BlePacketLossEstimator(minimumExpectedPackets: 5);
    final startedAt = DateTime(2026, 1, 1);
    double? result;

    for (var i = 0; i <= 6; i++) {
      result = estimator.update(
        packetSequence: i,
        receivedAt: startedAt.add(Duration(seconds: i)),
      );
    }

    expect(result, 0);
  });
}
