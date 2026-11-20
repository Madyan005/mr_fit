/// What the engine publishes to the UI (throttled ~60 Hz) and the discrete events that
/// drive Phase 5/6 cues.
library;

import '../workout/workout_models.dart';

enum SkeletonColor { green, yellow, red } // clean / incomplete ROM / valgus or lumbar fault

final class RepResult {
  const RepResult({
    required this.index,
    required this.startNs,
    required this.endNs,
    required this.meanVelocity,
    required this.displacementM,
    this.peakDepthDeg,
    this.symmetryPct,
    this.faults = const {},
  });

  final int index; // 1-based
  final int startNs;
  final int endNs;
  final double meanVelocity;
  final double displacementM;
  final double? peakDepthDeg;
  final double? symmetryPct;
  final Set<FaultFlag> faults;

  double get durationS => (endNs - startNs) / 1e9;

  RepResult withVision({double? peakDepthDeg, double? symmetryPct, required Set<FaultFlag> faults}) => RepResult(
        index: index, startNs: startNs, endNs: endNs, meanVelocity: meanVelocity, displacementM: displacementM,
        peakDepthDeg: peakDepthDeg, symmetryPct: symmetryPct, faults: faults);
}

sealed class EngineEvent {
  const EngineEvent(this.tMonoNs);
  final int tMonoNs;
}

final class RepCompleted extends EngineEvent {
  const RepCompleted(super.tMonoNs, this.rep);
  final RepResult rep;
}

/// Phase 5: audible tone + HapticCommand.faultDoubleBuzz.
final class FaultDetected extends EngineEvent {
  const FaultDetected(super.tMonoNs, this.repIndex, this.faults);
  final int repIndex;
  final Set<FaultFlag> faults;
}

/// Phase 5: velocity loss reached the goal's cap -> tone + HapticCommand.fatigueLongBuzz. Emitted once.
final class FatigueCapReached extends EngineEvent {
  const FatigueCapReached(super.tMonoNs, this.velocityLossPct, this.capPct);
  final double velocityLossPct;
  final double capPct;
}

enum ConclusionReason { sensorRacked, zeroMotion }

/// Phase 6: racked / zero-motion dwell > 2.0 s -> interSetSleep, vision 10 FPS, persist set.
final class SetConcluded extends EngineEvent {
  const SetConcluded(super.tMonoNs, this.reason);
  final ConclusionReason reason;
}

final class LiveMetrics {
  const LiveMetrics({
    this.repCount = 0,
    this.lastPeakDepthDeg,
    this.currentFlexionDeg,
    this.liveConcentricMps,
    this.lastRepMps,
    this.velocityLossPct,
    this.vlCapPct = 30,
    this.skeletonColor = SkeletonColor.green,
    this.velocityConfidenceLow = false,
    this.concluded = false,
  });

  final int repCount;
  final double? lastPeakDepthDeg;
  final double? currentFlexionDeg;

  /// Running mean of the concentric phase in progress (null between reps).
  final double? liveConcentricMps;
  final double? lastRepMps;
  final double? velocityLossPct;
  final double vlCapPct;
  final SkeletonColor skeletonColor;

  /// True when velocity comes from vision (no IMU velocity channel).
  final bool velocityConfidenceLow;
  final bool concluded;

  /// 0..1+ fill of the velocity-loss bar (1.0 = cap reached).
  double get vlBarFraction => velocityLossPct == null ? 0 : (velocityLossPct! / vlCapPct).clamp(0.0, 1.5);
}
