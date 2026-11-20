/// 2D joint geometry on COCO-17 keypoints (normalised, y down).
library;

import 'dart:math' as math;

import '../vision/vision_models.dart';
import '../workout/workout_models.dart';

/// Interior angle at [b] (deg) for the chain a-b-c.
double jointAngleDeg(Keypoint a, Keypoint b, Keypoint c) {
  final ux = a.x - b.x, uy = a.y - b.y, wx = c.x - b.x, wy = c.y - b.y;
  final nu = math.sqrt(ux * ux + uy * uy), nw = math.sqrt(wx * wx + wy * wy);
  if (nu < 1e-9 || nw < 1e-9) return 180;
  final cos = ((ux * wx + uy * wy) / (nu * nw)).clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}

/// (a, b, c) indices of the primary joint per side: flexion = 180 - angle(a, b, c).
({List<int> left, List<int> right}) primaryJoint(Exercise e) => switch (e) {
      Exercise.squat => (left: [Coco17.leftHip, Coco17.leftKnee, Coco17.leftAnkle],
          right: [Coco17.rightHip, Coco17.rightKnee, Coco17.rightAnkle]),
      Exercise.deadlift => (left: [Coco17.leftShoulder, Coco17.leftHip, Coco17.leftKnee],
          right: [Coco17.rightShoulder, Coco17.rightHip, Coco17.rightKnee]),
      Exercise.benchPress || Exercise.pushUp => (left: [Coco17.leftShoulder, Coco17.leftElbow, Coco17.leftWrist],
          right: [Coco17.rightShoulder, Coco17.rightElbow, Coco17.rightWrist]),
    };

/// Keypoint pair whose mean height approximates the bar (vision-derived velocity).
List<int> trackedPoints(Exercise e) => switch (e) {
      Exercise.squat || Exercise.pushUp => [Coco17.leftShoulder, Coco17.rightShoulder],
      Exercise.deadlift || Exercise.benchPress => [Coco17.leftWrist, Coco17.rightWrist],
    };

final class PoseReading {
  const PoseReading({required this.flexL, required this.flexR, required this.kneeAnkleRatio, required this.trunkLeanDeg});
  final double? flexL;
  final double? flexR;
  final double? kneeAnkleRatio;
  final double? trunkLeanDeg;

  double? get flexion {
    final l = flexL, r = flexR;
    if (l != null && r != null) return (l + r) / 2;
    return l ?? r;
  }

  /// |L - R| / mean * 100 (%), null if either side missing.
  double? get symmetryPct {
    final l = flexL, r = flexR;
    if (l == null || r == null) return null;
    final mean = (l + r) / 2;
    return mean.abs() < 1e-6 ? 0 : (l - r).abs() / mean * 100;
  }
}

PoseReading readPose(List<Keypoint> kp, Exercise e, double minConf) {
  bool ok(List<int> idx) => idx.every((i) => i < kp.length && kp[i].confidence >= minConf);
  double? flex(List<int> idx) => ok(idx) ? 180 - jointAngleDeg(kp[idx[0]], kp[idx[1]], kp[idx[2]]) : null;
  final j = primaryJoint(e);

  double? ratio;
  if (ok([Coco17.leftKnee, Coco17.rightKnee, Coco17.leftAnkle, Coco17.rightAnkle])) {
    final ankle = (kp[Coco17.leftAnkle].x - kp[Coco17.rightAnkle].x).abs();
    final knee = (kp[Coco17.leftKnee].x - kp[Coco17.rightKnee].x).abs();
    ratio = ankle < 1e-6 ? null : knee / ankle;
  }

  double? lean;
  if (ok([Coco17.leftShoulder, Coco17.rightShoulder, Coco17.leftHip, Coco17.rightHip])) {
    final sx = (kp[Coco17.leftShoulder].x + kp[Coco17.rightShoulder].x) / 2;
    final sy = (kp[Coco17.leftShoulder].y + kp[Coco17.rightShoulder].y) / 2;
    final hx = (kp[Coco17.leftHip].x + kp[Coco17.rightHip].x) / 2;
    final hy = (kp[Coco17.leftHip].y + kp[Coco17.rightHip].y) / 2;
    lean = math.atan2((sx - hx).abs(), (hy - sy)) * 180 / math.pi; // 0 = upright
  }
  return PoseReading(flexL: flex(j.left), flexR: flex(j.right), kneeAnkleRatio: ratio, trunkLeanDeg: lean);
}
