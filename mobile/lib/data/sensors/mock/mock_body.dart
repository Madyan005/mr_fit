/// SIMULATED 2D stick figure (COCO-17, normalised 0..1, y down) used by MockVisionPipeline
/// and, for range-of-motion, by MockSensorSource — so IMU and vision describe the SAME
/// movement. Geometry is built so the 2D joint angle of each side equals the scripted
/// flexion exactly (valgus moves the knee along its arc around the ankle).
library;

import 'dart:math' as math;

import '../../../domain/vision/vision_models.dart';
import '../../../domain/workout/workout_models.dart';

const _deg = math.pi / 180;

abstract final class MockBody {
  /// Same constant as MetricsConfig.visionMetersPerUnit (camera ~2 m away; ASSUMPTION).
  static const metersPerUnit = 2.25;

  static const shin = 0.2, thigh = 0.2, torso = 0.25, upperArm = 0.15, forearm = 0.15;
  static const ankleY = 0.9, ankleHalfWidth = 0.08, shoulderHalfWidth = 0.1;
  static const valgusMaxShift = 0.045;

  /// Normalised y of the point the IMU is assumed to follow (bar / shoulders / wrists).
  static double trackedY(Exercise ex, double f) {
    final kp = pose(ex, f, f);
    return switch (ex) {
      Exercise.squat || Exercise.pushUp => (kp[5].y + kp[6].y) / 2, // shoulders
      Exercise.deadlift || Exercise.benchPress => (kp[9].y + kp[10].y) / 2, // wrists
    };
  }

  /// Bar displacement (m) between standing/lockout (f=0) and flexion [f].
  static double romMeters(Exercise ex, double f) => (trackedY(ex, f) - trackedY(ex, 0)).abs() * metersPerUnit;

  /// Inverse of [romMeters] by bisection (monotonic on 0..maxF).
  static double flexionForDisplacement(Exercise ex, double dMeters, double maxF) {
    var lo = 0.0, hi = maxF;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      if (romMeters(ex, mid) < dMeters) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// Keypoints for left/right flexion [fL]/[fR] (deg). [valgus] 0..1, [extraLeanDeg] for lumbar faults.
  static List<Keypoint> pose(Exercise ex, double fL, double fR, {double valgus = 0, double extraLeanDeg = 0}) {
    final p = List<(double, double)>.filled(Coco17.count, (0.5, 0.5));
    switch (ex) {
      case Exercise.squat:
      case Exercise.deadlift:
        _standingLift(ex, p, fL, fR, valgus, extraLeanDeg);
      case Exercise.benchPress:
        _bench(p, fL, fR);
      case Exercise.pushUp:
        _pushUp(p, fL, fR);
    }
    return [for (final (x, y) in p) Keypoint(x, y, 0.95)];
  }

  // ---- squat (knee flexion) / deadlift (hip flexion), front-oblique view ----
  static void _standingLift(Exercise ex, List<(double, double)> p, double fL, double fR, double valgus, double extraLean) {
    final hips = <(double, double)>[];
    double lean = 0;
    for (final (side, f) in [(-1, fL), (1, fR)]) {
      final ankle = (0.5 + side * ankleHalfWidth, ankleY);
      // knee flexion k; squat: k = f; deadlift: k = 0.4 f (hip is the primary joint)
      final k = ex == Exercise.squat ? f : 0.4 * f;
      final shinBase = (ex == Exercise.squat ? 0.35 : 0.5) * k * _deg;
      var dx = shin * math.sin(shinBase) - side * valgus * valgusMaxShift; // inward = toward x=0.5
      dx = dx.clamp(-0.95 * shin, 0.95 * shin);
      final shinAng = math.asin(dx / shin);
      final knee = (ankle.$1 + dx, ankle.$2 - math.sqrt(shin * shin - dx * dx));
      final thighAng = k * _deg - shinAng; // keeps 2D knee angle = 180 - k
      final hip = (knee.$1 - thigh * math.sin(thighAng), knee.$2 - thigh * math.cos(thighAng));
      p[side < 0 ? Coco17.leftAnkle : Coco17.rightAnkle] = ankle;
      p[side < 0 ? Coco17.leftKnee : Coco17.rightKnee] = knee;
      p[side < 0 ? Coco17.leftHip : Coco17.rightHip] = hip;
      hips.add(hip);
      // squat: lean = 0.35 f; deadlift: hip flexion f = lean + thigh angle -> lean = f - thighAng
      lean += ex == Exercise.squat ? 0.35 * f : f - thighAng / _deg;
    }
    lean = lean / 2 + extraLean;
    final hm = ((hips[0].$1 + hips[1].$1) / 2, (hips[0].$2 + hips[1].$2) / 2);
    final up = (math.sin(lean * _deg), -math.cos(lean * _deg));
    final sm = (hm.$1 + torso * up.$1, hm.$2 + torso * up.$2);
    for (final side in [-1, 1]) {
      // Each shoulder sits on its own hip's trunk line so the per-side hip angle
      // (shoulder-hip-knee, the deadlift's primary joint) stays exact.
      final h = hips[side < 0 ? 0 : 1];
      final widen = ex == Exercise.squat ? side * (shoulderHalfWidth - ankleHalfWidth) : 0.0;
      final s = (h.$1 + torso * up.$1 + widen, h.$2 + torso * up.$2);
      p[side < 0 ? Coco17.leftShoulder : Coco17.rightShoulder] = s;
      if (ex == Exercise.deadlift) {
        // arms hang straight down holding the bar
        p[side < 0 ? Coco17.leftElbow : Coco17.rightElbow] = (s.$1, s.$2 + upperArm);
        p[side < 0 ? Coco17.leftWrist : Coco17.rightWrist] = (s.$1, s.$2 + upperArm + forearm);
      } else {
        // bar on the back: hands near the shoulders
        p[side < 0 ? Coco17.leftElbow : Coco17.rightElbow] = (s.$1 + side * 0.05, s.$2 + 0.06);
        p[side < 0 ? Coco17.leftWrist : Coco17.rightWrist] = (s.$1 + side * 0.03, s.$2 - 0.01);
      }
    }
    _head(p, sm, up);
  }

  // ---- bench press (elbow flexion), camera at the head end ----
  static void _bench(List<(double, double)> p, double fL, double fR) {
    for (final (side, f) in [(-1, fL), (1, fR)]) {
      final s = (0.5 + side * shoulderHalfWidth, 0.6);
      final a = f / 2 * _deg;
      final elbow = (s.$1 + side * upperArm * math.sin(a), s.$2 - upperArm * math.cos(a));
      final wrist = (elbow.$1 - side * forearm * math.sin(a), elbow.$2 - forearm * math.cos(a));
      _arm(p, side, s, elbow, wrist);
      p[side < 0 ? Coco17.leftHip : Coco17.rightHip] = (0.5 + side * 0.07, 0.45);
      p[side < 0 ? Coco17.leftKnee : Coco17.rightKnee] = (0.5 + side * 0.09, 0.36);
      p[side < 0 ? Coco17.leftAnkle : Coco17.rightAnkle] = (0.5 + side * 0.1, 0.3);
    }
    _head(p, (0.5, 0.6), (0, 1));
  }

  // ---- push-up (elbow flexion), camera at the head end; wrists fixed on the floor ----
  static void _pushUp(List<(double, double)> p, double fL, double fR) {
    var sy = 0.0;
    for (final (side, f) in [(-1, fL), (1, fR)]) {
      final a = f / 2 * _deg;
      final wrist = (0.5 + side * 0.12, 0.85);
      final s = (wrist.$1, wrist.$2 - (upperArm + forearm) * math.cos(a));
      final elbow = (s.$1 + side * upperArm * math.sin(a), s.$2 + upperArm * math.cos(a));
      _arm(p, side, s, elbow, wrist);
      sy += s.$2 / 2;
    }
    for (final side in [-1, 1]) {
      p[side < 0 ? Coco17.leftHip : Coco17.rightHip] = (0.5 + side * 0.06, sy - 0.05);
      p[side < 0 ? Coco17.leftKnee : Coco17.rightKnee] = (0.5 + side * 0.06, sy - 0.09);
      p[side < 0 ? Coco17.leftAnkle : Coco17.rightAnkle] = (0.5 + side * 0.06, sy - 0.12);
    }
    _head(p, (0.5, sy), (0, 1));
  }

  static void _arm(List<(double, double)> p, int side, (double, double) s, (double, double) e, (double, double) w) {
    p[side < 0 ? Coco17.leftShoulder : Coco17.rightShoulder] = s;
    p[side < 0 ? Coco17.leftElbow : Coco17.rightElbow] = e;
    p[side < 0 ? Coco17.leftWrist : Coco17.rightWrist] = w;
  }

  static void _head(List<(double, double)> p, (double, double) shoulderMid, (double, double) up) {
    final n = (shoulderMid.$1 + 0.09 * up.$1, shoulderMid.$2 + 0.09 * up.$2);
    p[Coco17.nose] = n;
    p[Coco17.leftEye] = (n.$1 - 0.015, n.$2 - 0.01);
    p[Coco17.rightEye] = (n.$1 + 0.015, n.$2 - 0.01);
    p[Coco17.leftEar] = (n.$1 - 0.03, n.$2);
    p[Coco17.rightEar] = (n.$1 + 0.03, n.$2);
  }
}
