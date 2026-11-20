/// Movement Quality Score — PLACEHOLDER formula (ASSUMPTION, needs validation; docs/MQS.md).
library;

import 'dart:math' as math;

import '../workout/workout_models.dart';
import 'live_metrics.dart';
import 'metrics_config.dart';

double _clamp100(double v) => v.clamp(0.0, 100.0);

/// Returns (score, breakdown). Sub-scores that cannot be computed are null and excluded;
/// the remaining weights are renormalised. Score is null if nothing can be computed.
({double? score, Map<String, double?> breakdown}) computeMqs({
  required List<RepResult> reps,
  required Exercise exercise,
  required double? velocityLossPct,
  required double vlCapPct,
  required double? symmetryIndex,
  required bool visionAvailable,
  required MetricsConfig config,
}) {
  final n = reps.length;
  final depths = [for (final r in reps) if (r.peakDepthDeg != null) r.peakDepthDeg!];

  final rom = depths.isEmpty
      ? null
      : _clamp100(depths.map((d) => math.min(1.0, d / config.targetDepthDeg[exercise]!) * 100).reduce((a, b) => a + b) /
          depths.length);

  double? stability;
  if (visionAvailable && n > 0) {
    final valgusReps = reps.where((r) => r.faults.contains(FaultFlag.valgus)).length;
    final lumbarReps = reps.where((r) => r.faults.contains(FaultFlag.lumbarFlexion)).length;
    stability = _clamp100(100 * (1 - (0.6 * valgusReps + 1.0 * lumbarReps) / n));
  }

  double? tempo;
  if (n >= 2) {
    final d = [for (final r in reps) r.durationS];
    final mean = d.reduce((a, b) => a + b) / n;
    final sd = math.sqrt(d.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / n);
    // Concentric duration naturally grows with fatigue; CV of 0.25 costs 50 points.
    tempo = mean <= 0 ? null : _clamp100(100 - sd / mean * 200);
  }

  final velocity = velocityLossPct == null ? null : _clamp100(100 - math.max(0.0, velocityLossPct) / vlCapPct * 50);
  final symmetry = symmetryIndex == null ? null : _clamp100(100 - symmetryIndex * 5);

  final parts = <String, double?>{
    'rom': rom, 'stability': stability, 'tempo': tempo, 'velocity': velocity, 'symmetry': symmetry,
  };
  final w = config.mqsWeights.asMap();
  var wSum = 0.0, acc = 0.0;
  parts.forEach((k, v) {
    if (v != null) {
      wSum += w[k]!;
      acc += w[k]! * v;
    }
  });
  double r1(double x) => (x * 10).roundToDouble() / 10;
  return (
    score: wSum == 0 ? null : r1(acc / wSum),
    breakdown: {for (final e in parts.entries) e.key: e.value == null ? null : r1(e.value!)},
  );
}
