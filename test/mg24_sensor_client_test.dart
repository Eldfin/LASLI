import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/mg24_sensor_client.dart';
import 'package:lasli_flutter/src/models.dart';

void main() {
  test('parses compact JSON MG24 notification', () {
    final sample = Mg24SensorSample.parse(
      utf8.encode(
        '{"r":"belly","a":[0.12,0.02,0.98],"pitch":7.5,'
        '"ro":1.2,"pi":7.5,"yaw":12.3,"hr":71.2,"spo2":98.4,'
        '"bat":87,"bv":3.91}',
      ),
      fallbackRole: Mg24SensorRole.forehead,
    );

    expect(sample, isNotNull);
    expect(sample!.role, Mg24SensorRole.belly);
    expect(sample.ax, closeTo(0.12, 0.001));
    expect(sample.resolvedAngleDeg, closeTo(7.5, 0.001));
    expect(sample.rollDeg, closeTo(1.2, 0.001));
    expect(sample.pitchDeg, closeTo(7.5, 0.001));
    expect(sample.yawDeg, closeTo(12.3, 0.001));
    expect(sample.heartRateBpm, closeTo(71.2, 0.001));
    expect(sample.spo2Percent, closeTo(98.4, 0.001));
    expect(sample.batteryPercent, closeTo(87, 0.001));
    expect(sample.batteryVoltage, closeTo(3.91, 0.001));
  });

  test('parses delimited MG24 notification', () {
    final sample = Mg24SensorSample.parse(
      utf8.encode('forehead,1234,0.1,0.2,0.9,1,2,3,4,5,6,72,97,88'),
      fallbackRole: Mg24SensorRole.belly,
    );

    expect(sample, isNotNull);
    expect(sample!.role, Mg24SensorRole.forehead);
    expect(sample.sensorTimeS, closeTo(1.234, 0.001));
    expect(sample.angleDeg, closeTo(6, 0.001));
    expect(sample.heartRateBpm, closeTo(72, 0.001));
    expect(sample.spo2Percent, closeTo(97, 0.001));
  });

  test('parses extended compact MG24 notification with acceleration', () {
    final sample = Mg24SensorSample.parse(
      utf8.encode(
        'belly,1234,0.0100,0.0200,0.9980,1.1,2.2,3.3,'
        '4.4,5.5,6.6,7.7,72,73,98,99,87,3.910,'
        '123456,54321,64,1.23,1,1,1',
      ),
      fallbackRole: Mg24SensorRole.forehead,
    );

    expect(sample, isNotNull);
    expect(sample!.role, Mg24SensorRole.belly);
    expect(sample.ax, closeTo(0.01, 0.0001));
    expect(sample.ay, closeTo(0.02, 0.0001));
    expect(sample.az, closeTo(0.998, 0.0001));
    expect(sample.rollDeg, closeTo(4.4, 0.001));
    expect(sample.pitchDeg, closeTo(5.5, 0.001));
    expect(sample.yawDeg, closeTo(6.6, 0.001));
    expect(sample.angleDeg, closeTo(7.7, 0.001));
    expect(sample.ppgIr, closeTo(123456, 0.001));
    expect(sample.ppgRed, closeTo(54321, 0.001));
    expect(sample.ppgPeak, isTrue);
    expect(sample.max30102Connected, isTrue);
    expect(sample.max30102Bus, 1);
  });
}
