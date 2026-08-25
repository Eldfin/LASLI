import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/processing.dart';
import 'package:lasli_flutter/src/widgets.dart';

void main() {
  test('display mapping inverts rotation but preserves inclination', () {
    final pureRotation = visualAxisInversionForTest(
      rotationDeg: 42,
      tiltDeg: 0,
    );
    expect(pureRotation.rotationDeg, closeTo(-42, 1e-9));
    expect(pureRotation.tiltDeg, closeTo(0, 1e-9));

    final pureInclination = visualAxisInversionForTest(
      rotationDeg: 0,
      tiltDeg: 57,
    );
    expect(pureInclination.rotationDeg, closeTo(0, 1e-9));
    expect(pureInclination.tiltDeg, closeTo(57, 1e-9));
  });

  test('orientation display flips sign for forehead and belly rotations', () {
    final state = OrientationEstimator().update([510, 510]);
    expect(state.foreheadAngleDeg, -90.0);
    expect(state.chestAngleDeg, -90.0);
    expect(state.relativeAngleDeg, 0.0);
  });

  test('forehead mounting follows belly tilt path at steep angles', () {
    for (final tiltDeg in [0.0, 40.0, 70.0, 80.0, 85.0]) {
      for (final rotationDeg in [0.0, 20.0, 40.0, 60.0, 80.0]) {
        final result = visualTiltMountingComparisonForTest(
          rotationDeg: rotationDeg,
          tiltDeg: tiltDeg,
        );
        expect(
          result.foreheadRotationDeg,
          closeTo(result.bellyRotationDeg, 1e-7),
          reason: 'rotation at tilt=$tiltDeg rotation=$rotationDeg',
        );
        expect(
          result.foreheadTiltDeg,
          closeTo(result.bellyTiltDeg, 1e-7),
          reason: 'tilt at tilt=$tiltDeg rotation=$rotationDeg',
        );
      }
    }
  });

  test('pure rotation follows the fixed head-facing branch', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[];
    for (var rotation = 0; rotation <= 180; rotation += 2) {
      samples.add((
        worldYawDeg: 0,
        rotationDeg: rotation.toDouble(),
        tiltDeg: 0,
      ));
    }

    final result = visualGravityFilteredTrajectoryForTest(samples);
    expect(result.last.rotationDeg.abs(), lessThan(0.05));
    expect(result.last.tiltDeg.abs(), closeTo(180, 0.05));
    _expectHeadAxisYawLocked(result);
  });

  test('rotation with existing inclination remains yaw locked', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var rotation = 0; rotation <= 180; rotation += 2)
        (
          worldYawDeg: -11,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 8,
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    for (final pose in result) {
      expect(pose.rotationDeg.isFinite, isTrue);
      expect(pose.tiltDeg.isFinite, isTrue);
    }
    _expectHeadAxisYawLocked(result);
  });

  test('inclination with existing rotation stays smooth', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 180; tilt += 2)
        (
          worldYawDeg: -11,
          rotationDeg: 8,
          tiltDeg: tilt.toDouble(),
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    for (final pose in result) {
      expect(pose.rotationDeg.isFinite, isTrue);
      expect(pose.tiltDeg.isFinite, isTrue);
    }
    _expectQuaternionPathContinuous(result);
  });

  test('noisy rotation through 90 degrees returns to the same pose', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[];
    for (var rotation = 0; rotation <= 100; rotation++) {
      samples.add((
        worldYawDeg: 18 + 1.8 * math.sin(rotation * 0.31),
        rotationDeg: rotation.toDouble(),
        tiltDeg: 1.2 * math.sin(rotation * 0.47),
      ));
    }
    for (var rotation = 99; rotation >= 0; rotation--) {
      samples.add((
        worldYawDeg: 20 + 1.6 * math.sin(rotation * 0.29 + 0.8),
        rotationDeg: rotation.toDouble(),
        tiltDeg: rotation == 0 ? 0 : 1.1 * math.sin(rotation * 0.43 + 0.4),
      ));
    }

    final result = visualGravityFilteredTrajectoryForTest(samples);
    expect(result.last.rotationDeg.abs(), lessThan(0.1));
    expect(result.last.tiltDeg.abs(), lessThan(0.1));
    expect(
      _quaternionDistanceDeg(result.first, result.last),
      lessThan(0.1),
    );
    _expectHeadAxisYawLocked(result);
  });

  test('motion while crossing the 90 degree branch returns to neutral', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[];
    for (var rotation = 0; rotation <= 88; rotation++) {
      samples.add((
        worldYawDeg: rotation * 0.2,
        rotationDeg: rotation.toDouble(),
        tiltDeg: 0,
      ));
    }
    for (var step = 0; step <= 24; step++) {
      samples.add((
        worldYawDeg: 18 + step * 0.2,
        rotationDeg: 88 + step / 6,
        tiltDeg: step * 1.5,
      ));
    }
    for (var step = 24; step >= 0; step--) {
      samples.add((
        worldYawDeg: 18 + step * 0.2,
        rotationDeg: 88 + step / 6,
        tiltDeg: step * 1.5,
      ));
    }
    for (var rotation = 87; rotation >= 0; rotation--) {
      samples.add((
        worldYawDeg: rotation * 0.2,
        rotationDeg: rotation.toDouble(),
        tiltDeg: 0,
      ));
    }

    final result = visualGravityFilteredTrajectoryForTest(samples);
    expect(result.last.rotationDeg.abs(), lessThan(0.1));
    expect(result.last.tiltDeg.abs(), lessThan(0.1));
    expect(_quaternionDistanceDeg(result.first, result.last), lessThan(0.1));
    _expectHeadAxisYawLocked(result);
  });

  test('BLE quaternion rounding cannot trap the 90 degree branch', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var rotation = 0; rotation <= 1000; rotation++)
        (
          worldYawDeg: 12 + 0.8 * math.sin(rotation * 0.037),
          rotationDeg: rotation / 10,
          tiltDeg: 8 * math.sin(rotation * 0.021),
        ),
      for (var rotation = 999; rotation >= 0; rotation--)
        (
          worldYawDeg: 12 + 0.8 * math.sin(rotation * 0.041 + 0.3),
          rotationDeg: rotation / 10,
          tiltDeg: rotation == 0 ? 0 : 8 * math.sin(rotation * 0.021),
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(
      samples,
      quantizeLikeBle: true,
    );
    expect(result.last.rotationDeg.abs(), lessThan(0.1));
    expect(result.last.tiltDeg.abs(), lessThan(0.1));
    expect(_quaternionDistanceDeg(result.first, result.last), lessThan(0.1));
    _expectHeadAxisYawLocked(result);
  });

  test('gravity-axis motion at 90 degrees cannot invert the returned pose', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var rotation = 0; rotation <= 90; rotation++)
        (
          worldYawDeg: 0,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 0,
        ),
      for (var yaw = 1; yaw <= 180; yaw++)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 90,
          tiltDeg: 0,
        ),
      for (var rotation = 89; rotation >= 0; rotation--)
        (
          worldYawDeg: 180,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 0,
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(
      samples,
      quantizeLikeBle: true,
    );
    expect(result.last.rotationDeg.abs(), lessThan(0.1));
    expect(result.last.tiltDeg.abs(), lessThan(0.1));
    expect(_quaternionDistanceDeg(result.first, result.last), lessThan(0.1));
    _expectQuaternionPathContinuous(result);
  });

  test('closed noisy paths cannot leave the visual pose inverted', () {
    final random = math.Random(0x4c41534c);
    for (var trial = 0; trial < 80; trial++) {
      final outward = <({
        double worldYawDeg,
        double rotationDeg,
        double tiltDeg,
      })>[];
      var yaw = 0.0;
      var tilt = 0.0;
      final targetRotation = 75 + random.nextDouble() * 70;
      for (var step = 0; step <= 160; step++) {
        final progress = step / 160;
        yaw += (random.nextDouble() - 0.5) * 3.0;
        tilt = (tilt + (random.nextDouble() - 0.5) * 2.0).clamp(-65, 65);
        outward.add((
          worldYawDeg: yaw,
          rotationDeg: targetRotation * progress,
          tiltDeg: tilt,
        ));
      }
      final samples = <({
        double worldYawDeg,
        double rotationDeg,
        double tiltDeg,
      })>[
        (worldYawDeg: 0, rotationDeg: 0, tiltDeg: 0),
        ...outward,
        ...outward.reversed,
        (worldYawDeg: 0, rotationDeg: 0, tiltDeg: 0),
      ];

      final result = visualGravityFilteredTrajectoryForTest(
        samples,
        quantizeLikeBle: true,
      );
      expect(
        _quaternionDistanceDeg(result.first, result.last),
        lessThan(0.1),
        reason: 'closed path did not return in trial $trial',
      );
      expect(result.last.rotationDeg.abs(), lessThan(0.1));
      expect(result.last.tiltDeg.abs(), lessThan(0.1));
    }
  });

  test('different outward and return paths cannot retain yaw', () {
    final random = math.Random(0x534c4545);
    for (var trial = 0; trial < 400; trial++) {
      final samples = <({
        double worldYawDeg,
        double rotationDeg,
        double tiltDeg,
      })>[(worldYawDeg: 0, rotationDeg: 0, tiltDeg: 0)];
      final targetRotation = 80 + random.nextDouble() * 120;
      final targetTilt = -80 + random.nextDouble() * 160;
      final targetYaw = -180 + random.nextDouble() * 360;
      for (var step = 1; step <= 120; step++) {
        final progress = step / 120;
        samples.add((
          worldYawDeg: targetYaw * progress +
              3 * math.sin(step * (0.08 + random.nextDouble() * 0.02)),
          rotationDeg: targetRotation * progress,
          tiltDeg: targetTilt * progress + 2 * math.sin(step * 0.11),
        ));
      }
      final endYaw = -180 + random.nextDouble() * 360;
      for (var step = 119; step >= 0; step--) {
        final progress = step / 120;
        samples.add((
          worldYawDeg: endYaw +
              (targetYaw - endYaw) * progress +
              2 * math.sin(step * 0.09 + 0.7),
          rotationDeg: targetRotation * progress,
          tiltDeg: targetTilt * progress + 1.5 * math.sin(step * 0.13),
        ));
      }
      samples.add((worldYawDeg: endYaw, rotationDeg: 0, tiltDeg: 0));

      final result = visualGravityFilteredTrajectoryForTest(
        samples,
        quantizeLikeBle: true,
      );
      expect(
        _quaternionDistanceDeg(result.first, result.last),
        lessThan(0.1),
        reason: 'closed path retained yaw in trial $trial',
      );
      _expectHeadAxisYawLocked(result);
    }
  });

  test('neutral pose overrides a previously trapped inverted branch', () {
    final recovered = visualGravityFilterNeutralRecoveryForTest();

    expect(recovered.rotationDeg.abs(), lessThan(0.1));
    expect(recovered.tiltDeg.abs(), lessThan(0.1));
    expect(
      _quaternionDistanceDeg(
        recovered,
        (
          w: 1,
          x: 0,
          y: 0,
          z: 0,
          rotationDeg: 0,
          tiltDeg: 0,
        ),
      ),
      lessThan(0.1),
    );
  });

  test('pure tilt remains isolated while crossing 180 degrees', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[];
    for (var tilt = 0; tilt <= 180; tilt += 2) {
      samples.add((
        worldYawDeg: 0,
        rotationDeg: 0,
        tiltDeg: tilt.toDouble(),
      ));
    }

    final result = visualGravityFilteredTrajectoryForTest(samples);
    expect(result.last.tiltDeg, closeTo(180, 0.05));
    expect(result.last.rotationDeg.abs(), lessThan(0.05));
    _expectQuaternionPathContinuous(result);
  });

  test('world gravity rotation stays hidden at steep combined tilt', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var yaw = 0; yaw <= 360; yaw += 2)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 70,
          tiltDeg: 80,
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    for (final pose in result.skip(1)) {
      expect(_quaternionDistanceDeg(result.first, pose), lessThan(0.05));
    }
    _expectQuaternionPathContinuous(result);
  });

  test('hidden yaw does not remap a later local rotation axis', () {
    final baseline = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 90; tilt += 2)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (var rotation = 2; rotation <= 90; rotation += 2)
        (
          worldYawDeg: 0,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 90,
        ),
      for (var yaw = 2; yaw <= 120; yaw += 2)
        (
          worldYawDeg: 0,
          rotationDeg: 90,
          tiltDeg: 90,
        ),
      for (var rotation = 92; rotation <= 150; rotation += 2)
        (
          worldYawDeg: 0,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 90,
        ),
    ];
    final withHiddenYaw = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 90; tilt += 2)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (var rotation = 2; rotation <= 90; rotation += 2)
        (
          worldYawDeg: 0,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 90,
        ),
      for (var yaw = 2; yaw <= 120; yaw += 2)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 90,
          tiltDeg: 90,
        ),
      for (var rotation = 92; rotation <= 150; rotation += 2)
        (
          worldYawDeg: 120,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 90,
        ),
    ];

    final expected = visualGravityFilteredTrajectoryForTest(baseline);
    final actual = visualGravityFilteredTrajectoryForTest(withHiddenYaw);
    expect(actual, hasLength(expected.length));
    for (var index = 0; index < actual.length; index += 1) {
      expect(
        _quaternionDistanceDeg(expected[index], actual[index]),
        lessThan(0.05),
        reason: 'hidden yaw changed the visible pose at sample $index',
      );
    }
    _expectHeadAxisYawLocked(actual);
  });

  test('hidden yaw does not remap the local rotation return path', () {
    List<
        ({
          double worldYawDeg,
          double rotationDeg,
          double tiltDeg,
        })> trajectory({required bool withHiddenYaw}) => [
          for (var tilt = 0; tilt <= 90; tilt += 1)
            (
              worldYawDeg: 0,
              rotationDeg: 0,
              tiltDeg: tilt.toDouble(),
            ),
          for (var rotation = 1; rotation <= 90; rotation += 1)
            (
              worldYawDeg: 0,
              rotationDeg: rotation.toDouble(),
              tiltDeg: 90,
            ),
          for (var yaw = 1; yaw <= 90; yaw += 1)
            (
              worldYawDeg: withHiddenYaw ? yaw.toDouble() : 0,
              rotationDeg: 90,
              tiltDeg: 90,
            ),
          for (var rotation = 89; rotation >= 0; rotation -= 1)
            (
              worldYawDeg: withHiddenYaw ? 90 : 0,
              rotationDeg: rotation.toDouble(),
              tiltDeg: 90,
            ),
        ];

    final expected = visualGravityFilteredTrajectoryForTest(
      trajectory(withHiddenYaw: false),
      quantizeLikeBle: true,
    );
    final actual = visualGravityFilteredTrajectoryForTest(
      trajectory(withHiddenYaw: true),
      quantizeLikeBle: true,
    );
    for (var index = 0; index < actual.length; index += 1) {
      expect(
        _quaternionDistanceDeg(expected[index], actual[index]),
        lessThan(0.05),
        reason: 'hidden yaw remapped the return path at sample $index',
      );
    }
    _expectHeadAxisYawLocked(actual);
  });

  test('yaw at a tilted pose cannot survive the return to neutral', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 70; tilt += 1)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (var rotation = 1; rotation <= 65; rotation += 1)
        (
          worldYawDeg: 0,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 70,
        ),
      for (var yaw = 1; yaw <= 135; yaw += 1)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 65,
          tiltDeg: 70,
        ),
      for (var rotation = 64; rotation >= 0; rotation -= 1)
        (
          worldYawDeg: 135,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 70,
        ),
      for (var tilt = 69; tilt >= 0; tilt -= 1)
        (
          worldYawDeg: 135,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(
      samples,
      quantizeLikeBle: true,
    );
    expect(result.last.rotationDeg.abs(), lessThan(0.1));
    expect(result.last.tiltDeg.abs(), lessThan(0.1));
    expect(_quaternionDistanceDeg(result.first, result.last), lessThan(0.1));
    _expectHeadAxisYawLocked(result);
  });

  test('sparse BLE updates preserve the hidden-yaw return direction', () {
    for (final step in [5, 10, 15, 30]) {
      List<
          ({
            double worldYawDeg,
            double rotationDeg,
            double tiltDeg,
          })> trajectory({required bool withHiddenYaw}) => [
            for (var tilt = 0; tilt <= 90; tilt += step)
              (
                worldYawDeg: 0,
                rotationDeg: 0,
                tiltDeg: tilt.toDouble(),
              ),
            for (var rotation = step; rotation <= 90; rotation += step)
              (
                worldYawDeg: 0,
                rotationDeg: rotation.toDouble(),
                tiltDeg: 90,
              ),
            for (var yaw = step; yaw <= 90; yaw += step)
              (
                worldYawDeg: withHiddenYaw ? yaw.toDouble() : 0,
                rotationDeg: 90,
                tiltDeg: 90,
              ),
            for (var rotation = 90 - step; rotation >= 0; rotation -= step)
              (
                worldYawDeg: withHiddenYaw ? 90 : 0,
                rotationDeg: rotation.toDouble(),
                tiltDeg: 90,
              ),
          ];

      final expected = visualGravityFilteredTrajectoryForTest(
        trajectory(withHiddenYaw: false),
        quantizeLikeBle: true,
      );
      final actual = visualGravityFilteredTrajectoryForTest(
        trajectory(withHiddenYaw: true),
        quantizeLikeBle: true,
      );
      for (var index = 0; index < actual.length; index += 1) {
        expect(
          _quaternionDistanceDeg(expected[index], actual[index]),
          lessThan(0.05),
          reason: 'wrong return direction at BLE step $step, sample $index',
        );
      }
    }
  });

  test('closed combined motion returns to the neutral visual pose', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[];
    for (var yaw = 0; yaw <= 90; yaw += 2) {
      samples.add((
        worldYawDeg: yaw.toDouble(),
        rotationDeg: 0,
        tiltDeg: 0,
      ));
    }
    for (var tilt = 2; tilt <= 100; tilt += 2) {
      samples.add((
        worldYawDeg: 90,
        rotationDeg: 0,
        tiltDeg: tilt.toDouble(),
      ));
    }
    for (var rotation = 2; rotation <= 60; rotation += 2) {
      samples.add((
        worldYawDeg: 90,
        rotationDeg: rotation.toDouble(),
        tiltDeg: 100,
      ));
    }
    for (var rotation = 58; rotation >= 0; rotation -= 2) {
      samples.add((
        worldYawDeg: 90,
        rotationDeg: rotation.toDouble(),
        tiltDeg: 100,
      ));
    }
    for (var tilt = 98; tilt >= 0; tilt -= 2) {
      samples.add((
        worldYawDeg: 90,
        rotationDeg: 0,
        tiltDeg: tilt.toDouble(),
      ));
    }
    for (var yaw = 88; yaw >= 0; yaw -= 2) {
      samples.add((
        worldYawDeg: yaw.toDouble(),
        rotationDeg: 0,
        tiltDeg: 0,
      ));
    }

    final result = visualGravityFilteredTrajectoryForTest(samples);
    expect(_quaternionDistanceDeg(result.first, result.last), lessThan(0.05));
    expect(result.last.rotationDeg.abs(), lessThan(0.05));
    expect(result.last.tiltDeg.abs(), lessThan(0.05));
    _expectQuaternionPathContinuous(result);
  });

  test('pure tilt near 180 degrees does not create visual rotation', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 180; tilt += 2)
        (
          worldYawDeg: 45,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    expect(result.last.tiltDeg.abs(), closeTo(180, 0.05));
    expect(result.last.rotationDeg.abs(), lessThan(0.05));
    _expectQuaternionPathContinuous(result);
  });

  test('world yaw stays hidden at the inverted pose', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 180; tilt += 1)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (var yaw = 1; yaw <= 45; yaw += 1)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 0,
          tiltDeg: 180,
        ),
      for (var yaw = 44; yaw >= -45; yaw -= 1)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 0,
          tiltDeg: 180,
        ),
      for (var yaw = -44; yaw <= 0; yaw += 1)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 0,
          tiltDeg: 180,
        ),
      for (var tilt = 179; tilt >= 0; tilt -= 1)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    for (var tilt = 0; tilt <= 180; tilt += 1) {
      expect(result[tilt].rotationDeg.abs(), lessThan(0.05));
      expect(result[tilt].tiltDeg, closeTo(tilt.toDouble(), 0.05));
    }
    final inverted = result[180];
    for (final pose in result.skip(181).take(179)) {
      expect(_quaternionDistanceDeg(inverted, pose), lessThan(0.05));
      expect(pose.rotationDeg.abs(), lessThan(0.05));
      expect(pose.tiltDeg.abs(), closeTo(180, 0.05));
    }
    expect(_quaternionDistanceDeg(result.first, result.last), lessThan(0.05));
    _expectQuaternionPathContinuous(result);
  });

  test('fixed head branch leaves no visible gravity yaw residue', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 180; tilt += 1)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (var rotation = 1; rotation <= 180; rotation += 1)
        (
          worldYawDeg: 0,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 180,
        ),
    ];
    final result = visualGravityFilteredTrajectoryForTest(
      samples,
      quantizeLikeBle: true,
    );

    _expectHeadAxisYawLocked(result);
  });

  test('combined motion close to inversion stays yaw locked', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 178; tilt += 1)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (var rotation = 1; rotation <= 180; rotation += 1)
        (
          worldYawDeg: 45,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 178,
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    for (final pose in result) {
      expect(pose.rotationDeg.isFinite, isTrue);
      expect(pose.tiltDeg.isFinite, isTrue);
    }
    _expectHeadAxisYawLocked(result);
  });

  test('near-inverted rotation sweeps stay yaw locked', () {
    for (final tiltTarget in [150.0, 170.0, 178.0, 179.0, 180.0]) {
      for (final direction in [-1.0, 1.0]) {
        final samples = <({
          double worldYawDeg,
          double rotationDeg,
          double tiltDeg,
        })>[
          for (var tilt = 0; tilt <= tiltTarget; tilt += 1)
            (
              worldYawDeg: 37,
              rotationDeg: 0,
              tiltDeg: math.min(tilt.toDouble(), tiltTarget),
            ),
          for (var rotation = 1; rotation <= 180; rotation += 1)
            (
              worldYawDeg: 37,
              rotationDeg: direction * rotation,
              tiltDeg: tiltTarget,
            ),
        ];

        final result = visualGravityFilteredTrajectoryForTest(samples);
        for (final pose in result) {
          expect(pose.rotationDeg.isFinite, isTrue);
          expect(pose.tiltDeg.isFinite, isTrue);
        }
        _expectHeadAxisYawLocked(result);
      }
    }
  });

  test('small motion near the inverted pose stays continuous', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 178; tilt += 2)
        (
          worldYawDeg: 45,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (final rotation in [1.0, -1.0, 0.5, -0.5, 0.0])
        (
          worldYawDeg: 45,
          rotationDeg: rotation,
          tiltDeg: 179,
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    for (final pose in result) {
      expect(pose.rotationDeg.isFinite, isTrue);
      expect(pose.tiltDeg.isFinite, isTrue);
    }
    _expectQuaternionPathContinuous(result);
  });

  test('world yaw stays hidden after near-inverted combined rotation', () {
    final samples = <({
      double worldYawDeg,
      double rotationDeg,
      double tiltDeg,
    })>[
      for (var tilt = 0; tilt <= 178; tilt += 1)
        (
          worldYawDeg: 0,
          rotationDeg: 0,
          tiltDeg: tilt.toDouble(),
        ),
      for (var rotation = 1; rotation <= 60; rotation += 1)
        (
          worldYawDeg: 0,
          rotationDeg: rotation.toDouble(),
          tiltDeg: 178,
        ),
      for (var yaw = 1; yaw <= 360; yaw += 1)
        (
          worldYawDeg: yaw.toDouble(),
          rotationDeg: 60,
          tiltDeg: 178,
        ),
    ];

    final result = visualGravityFilteredTrajectoryForTest(samples);
    final reference = result[238];
    for (final pose in result.skip(239)) {
      expect(_quaternionDistanceDeg(reference, pose), lessThan(0.05));
    }
    _expectQuaternionPathContinuous(result);
  });

  test('model-viewer Euler conversion preserves the visual quaternion', () {
    for (final worldYaw in [0.0, 45.0, 90.0, 180.0]) {
      for (final rotation in [0.0, 45.0, 90.0, 170.0, 180.0]) {
        for (final tilt in [0.0, 45.0, 90.0, 170.0, 180.0]) {
          expect(
            modelViewerOrientationRoundTripErrorDegForTest(
              worldYawDeg: worldYaw,
              rotationDeg: rotation,
              tiltDeg: tilt,
            ),
            lessThan(1e-5),
            reason: 'worldYaw=$worldYaw rotation=$rotation tilt=$tilt',
          );
        }
      }
    }
  });

  test('archived pose is deterministic and bounded', () {
    final first = visualArchivedPoseForTest(
      rollDeg: 175,
      pitchDeg: -165,
      yawDeg: 132,
      isForehead: true,
    );
    visualArchivedPoseForTest(
      rollDeg: -40,
      pitchDeg: 75,
      yawDeg: -170,
      isForehead: false,
    );
    final repeated = visualArchivedPoseForTest(
      rollDeg: 175,
      pitchDeg: -165,
      yawDeg: 132,
      isForehead: true,
    );

    expect(repeated, first);
    expect(first.rotationDeg.abs(), lessThanOrEqualTo(180));
    expect(first.tiltDeg.abs(), lessThanOrEqualTo(180));
  });
}

void _expectHeadAxisYawLocked(
  List<
          ({
            double w,
            double x,
            double y,
            double z,
            double rotationDeg,
            double tiltDeg,
          })>
      path,
) {
  for (var index = 0; index < path.length; index += 1) {
    final q = path[index];
    final headX = 1 - 2 * (q.y * q.y + q.z * q.z);
    final headZ = 2 * (q.x * q.z - q.w * q.y);
    final horizontal = math.sqrt(headX * headX + headZ * headZ);
    if (horizontal <= math.sin(5 * math.pi / 180) + 1e-5) continue;
    expect(
      headZ.abs(),
      lessThan(1e-5),
      reason: 'head axis retained world yaw at sample $index',
    );
    expect(
      headX,
      greaterThan(0),
      reason: 'torso points away from head at sample $index',
    );
  }
}

void _expectQuaternionPathContinuous(
  List<
          ({
            double w,
            double x,
            double y,
            double z,
            double rotationDeg,
            double tiltDeg,
          })>
      path,
) {
  for (var index = 1; index < path.length; index += 1) {
    expect(
      _quaternionDistanceDeg(path[index - 1], path[index]),
      lessThan(4),
      reason: 'orientation jump at sample $index',
    );
  }
}

double _quaternionDistanceDeg(
  ({
    double w,
    double x,
    double y,
    double z,
    double rotationDeg,
    double tiltDeg,
  }) a,
  ({
    double w,
    double x,
    double y,
    double z,
    double rotationDeg,
    double tiltDeg,
  }) b,
) {
  final dot =
      (a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z).abs().clamp(0.0, 1.0);
  return 2 * 57.29577951308232 * math.acos(dot);
}
