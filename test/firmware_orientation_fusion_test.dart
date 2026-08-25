import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all three gravity-error components restore tilt at 90 degrees', () {
    final withoutBodyZCorrection = _settledGravityErrorDeg(includeEz: false);
    final withBodyZCorrection = _settledGravityErrorDeg(includeEz: true);

    expect(withoutBodyZCorrection, greaterThan(15));
    expect(withBodyZCorrection, lessThan(0.5));
  });
}

double _settledGravityErrorDeg({required bool includeEz}) {
  const dt = 0.04;
  const kp = 2.2;
  final truePose = _Q.axisAngle(1, 0, 0, math.pi / 2);
  var estimate =
      (truePose * _Q.axisAngle(0, 0, 1, 20 * math.pi / 180)).normalized();
  final measured = truePose.gravityInBody();

  for (var sample = 0; sample < 250; sample++) {
    final predicted = estimate.gravityInBody();
    final ex = measured.$2 * predicted.$3 - measured.$3 * predicted.$2;
    final ey = measured.$3 * predicted.$1 - measured.$1 * predicted.$3;
    final ez = measured.$1 * predicted.$2 - measured.$2 * predicted.$1;
    estimate = estimate
        .integrated(
          kp * ex,
          kp * ey,
          includeEz ? kp * ez : 0,
          dt,
        )
        .normalized();
  }

  final predicted = estimate.gravityInBody();
  final dot = (measured.$1 * predicted.$1 +
          measured.$2 * predicted.$2 +
          measured.$3 * predicted.$3)
      .clamp(-1.0, 1.0);
  return math.acos(dot) * 180 / math.pi;
}

class _Q {
  const _Q(this.w, this.x, this.y, this.z);

  factory _Q.axisAngle(double x, double y, double z, double angle) {
    final length = math.sqrt(x * x + y * y + z * z);
    final scale = math.sin(angle / 2) / length;
    return _Q(math.cos(angle / 2), x * scale, y * scale, z * scale);
  }

  final double w;
  final double x;
  final double y;
  final double z;

  _Q operator *(_Q other) => _Q(
        w * other.w - x * other.x - y * other.y - z * other.z,
        w * other.x + x * other.w + y * other.z - z * other.y,
        w * other.y - x * other.z + y * other.w + z * other.x,
        w * other.z + x * other.y - y * other.x + z * other.w,
      );

  _Q normalized() {
    final length = math.sqrt(w * w + x * x + y * y + z * z);
    return _Q(w / length, x / length, y / length, z / length);
  }

  (double, double, double) gravityInBody() => (
        2 * (x * z - w * y),
        2 * (w * x + y * z),
        w * w - x * x - y * y + z * z,
      );

  _Q integrated(double gx, double gy, double gz, double dt) {
    return _Q(
      w + 0.5 * (-x * gx - y * gy - z * gz) * dt,
      x + 0.5 * (w * gx + y * gz - z * gy) * dt,
      y + 0.5 * (w * gy - x * gz + z * gx) * dt,
      z + 0.5 * (w * gz + x * gy - y * gx) * dt,
    );
  }
}
