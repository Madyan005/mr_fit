/// MetricsEngine thresholds and MQS weights. EVERY number here is a placeholder:
/// ASSUMPTION, needs validation (docs/MQS.md). Change values here, not in engine code.
library;

import '../workout/workout_models.dart';

final class MqsWeights {
  const MqsWeights({this.rom = 0.30, this.stability = 0.30, this.tempo = 0.10, this.velocity = 0.15, this.symmetry = 0.15});
  final double rom, stability, tempo, velocity, symmetry;

  Map<String, double> asMap() =>
      {'rom': rom, 'stability': stability, 'tempo': tempo, 'velocity': velocity, 'symmetry': symmetry};
}

final class MetricsConfig {
  const MetricsConfig({
    this.repStartVelocity = 0.10,
    this.repEndVelocity = 0.05,
    this.zeroCrossImu = 0.015,
    this.zeroCrossVision = 0.04,
    this.repCloseTimeoutS = 0.3,
    this.minConcentricS = 0.25,
    this.minRomM = const {Exercise.squat: 0.15, Exercise.deadlift: 0.15, Exercise.benchPress: 0.08, Exercise.pushUp: 0.08},
    this.minDepthDeg = const {Exercise.squat: 85, Exercise.deadlift: 60, Exercise.benchPress: 80, Exercise.pushUp: 80},
    this.targetDepthDeg = const {Exercise.squat: 90, Exercise.deadlift: 75, Exercise.benchPress: 85, Exercise.pushUp: 85},
    this.maxTrunkLeanDeg = const {Exercise.squat: 55, Exercise.deadlift: 75},
    this.valgusKneeAnkleRatio = 0.75,
    this.minKeypointConfidence = 0.3,
    this.visionMetersPerUnit = 2.25,
    this.visionSmoothingFrames = 5,
    this.visionWindowShrinkFrames = 2,
    this.rackedDwellS = 2.0,
    this.zeroMotionSpeed = 0.03,
    this.zeroMotionWindowS = 0.25,
    this.liveEmitIntervalMs = 16,
    this.mqsWeights = const MqsWeights(),
  });

  // ---- rep segmentation on vertical velocity (+ = up) ----
  final double repStartVelocity; // concentric starts above this (m/s)
  final double repEndVelocity; // ...and ends below this
  final double zeroCrossImu; // window extended back/forward to this |v| (IMU)
  final double zeroCrossVision; // same for vision-derived velocity (noisier)
  final double repCloseTimeoutS;
  final double minConcentricS;
  final Map<Exercise, double> minRomM;

  // ---- vision ----
  final Map<Exercise, double> minDepthDeg; // below -> incomplete_rom
  final Map<Exercise, double> targetDepthDeg; // MQS rom = depth / target
  final Map<Exercise, double> maxTrunkLeanDeg; // above -> lumbar_flexion (2D proxy)
  final double valgusKneeAnkleRatio; // knee distance / ankle distance below -> valgus
  final double minKeypointConfidence;
  final double visionMetersPerUnit; // normalised frame units -> meters (camera ~2 m away)
  final int visionSmoothingFrames;

  /// Vision rep mean velocity = raw displacement / time between the segment ends pulled in
  /// by this many frames (undoes the widening caused by smoothing + differencing).
  /// ASSUMPTION: tuned on the mock (bias ~0, worst error ~0.05 m/s at 30 FPS).
  final int visionWindowShrinkFrames;

  // ---- set conclusion (Phase 6) ----
  final double rackedDwellS; // > 2.0 s racked / zero motion
  final double zeroMotionSpeed;
  final double zeroMotionWindowS;

  // ---- live HUD ----
  final int liveEmitIntervalMs; // ~60 Hz

  final MqsWeights mqsWeights;

  /// Which faults can be detected for each exercise from 2D keypoints.
  static bool detectsValgus(Exercise e) => e == Exercise.squat || e == Exercise.deadlift;
  static bool detectsLumbar(Exercise e) => e == Exercise.squat || e == Exercise.deadlift;
}
