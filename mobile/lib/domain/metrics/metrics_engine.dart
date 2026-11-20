/// Deterministic MetricsEngine (pure Dart; runs inside an Isolate via MetricsWorker).
/// Input: sensor samples + vision frames (phone monotonic ns). Output: rep segmentation,
/// per-rep mean concentric velocity, peak depth, faults, velocity loss, symmetry, MQS,
/// live HUD state, Phase 5/6 events, and the SetSummaryPayload.
///
/// The LLM never computes any of this.
///
/// Velocity source, in order: `bar_vel_z` (IMU) -> vision-derived (tracked keypoints,
/// flagged lower confidence) -> none (all velocity metrics null).
library;

import 'dart:math' as math;

import '../contracts/set_summary_payload.dart';
import '../sensors/channels.dart';
import '../sensors/sensor_models.dart';
import '../vision/vision_models.dart';
import '../workout/workout_models.dart';
import 'live_metrics.dart';
import 'metrics_config.dart';
import 'mqs.dart';
import 'pose_geometry.dart';

final class SetContext {
  const SetContext({
    required this.setId,
    required this.exercise,
    required this.goal,
    required this.setIndex,
    required this.dataSource,
    required this.deviceLabels,
    this.loadKg,
    double? vlCapPct,
  }) : vlCapPct = vlCapPct ?? 0;

  final String setId;
  final Exercise exercise;
  final Goal goal;
  final int setIndex;
  final DataSource dataSource;
  final List<String> deviceLabels;
  final double? loadKg;
  final double vlCapPct;

  double get cap => vlCapPct > 0 ? vlCapPct : goal.vlCapPct;
}

final class _V {
  const _V(this.t, this.v, [this.frame]);
  final int t;
  final double v;
  final int? frame; // index into _trackedY for vision-derived points
}

class MetricsEngine {
  MetricsEngine({required this.ctx, required this.capabilities, this.config = const MetricsConfig()})
      : _useImuVelocity = capabilities.has(Channels.barVelZ);

  final SetContext ctx;
  final SensorCapabilities capabilities;
  final MetricsConfig config;
  final bool _useImuVelocity;

  // velocity series + segmentation state
  final List<_V> _vel = [];
  bool _inConcentric = false;
  int _segStartIdx = 0;
  int? _belowEndSinceNs;
  final List<RepResult> _reps = [];

  // vision
  final List<VisionFrameResult> _frames = [];
  final List<(int, double)> _trackedY = []; // (t, mean normalised y of tracked points)
  PoseReading? _lastPose;

  // conclusion
  int? _rackedSinceNs;
  int? _stillSinceNs;
  bool _concluded = false;
  bool _fatigueSent = false;
  int? _lastNs;

  final List<EngineEvent> _events = [];

  bool get concluded => _concluded;
  List<RepResult> get reps => List.unmodifiable(_reps);
  VelocitySource? get velocitySource =>
      _useImuVelocity ? VelocitySource.imu : (_frames.isNotEmpty ? VelocitySource.vision : null);

  /// Events since the last drain (fault / fatigue / rep / conclusion).
  List<EngineEvent> drainEvents() {
    final out = List<EngineEvent>.of(_events);
    _events.clear();
    return out;
  }

  // ---------------- inputs ----------------

  void addSamples(Iterable<SensorSample> samples) {
    for (final s in samples) {
      _lastNs = math.max(_lastNs ?? s.tMonoNs, s.tMonoNs);
      if (_useImuVelocity && s.channel == Channels.barVelZ) _onVelocity(_V(s.tMonoNs, s.value), config.zeroCrossImu);
    }
  }

  void addFrames(Iterable<VisionFrameResult> frames) {
    for (final f in frames) {
      if (!f.personInFrame || f.keypoints.length < Coco17.count) continue;
      _frames.add(f);
      _lastPose = readPose(f.keypoints, ctx.exercise, config.minKeypointConfidence);
      _lastNs = math.max(_lastNs ?? f.tMonoNs, f.tMonoNs);
      if (!_useImuVelocity) _onVisionFrame(f);
    }
  }

  void updateStatus(DeviceStatus status, int tMonoNs) {
    if (status.restingDwell) {
      _rackedSinceNs ??= tMonoNs;
      _checkConclusion(tMonoNs);
    } else {
      _rackedSinceNs = null;
    }
  }

  // ---------------- segmentation ----------------

  void _onVisionFrame(VisionFrameResult f) {
    final idx = trackedPoints(ctx.exercise);
    if (idx.any((i) => f.keypoints[i].confidence < config.minKeypointConfidence)) return;
    _trackedY.add((f.tMonoNs, idx.map((i) => f.keypoints[i].y).reduce((a, b) => a + b) / idx.length));
    final w = config.visionSmoothingFrames;
    if (_trackedY.length < w + 4) return;
    // Smoothed position (moving average of w), then central difference over +-2 samples.
    double smooth(int end) {
      var s = 0.0;
      for (var i = end - w + 1; i <= end; i++) {
        s += _trackedY[i].$2;
      }
      return s / w;
    }

    final n = _trackedY.length - 1;
    final yA = smooth(n - 4), yB = smooth(n);
    final tA = _trackedY[n - 4 - w ~/ 2].$1, tB = _trackedY[n - w ~/ 2].$1;
    final dt = (tB - tA) / 1e9;
    if (dt <= 0) return;
    final v = -(yB - yA) * config.visionMetersPerUnit / dt; // y down -> up is positive
    final mid = n - 2 - w ~/ 2;
    _onVelocity(_V(_trackedY[mid].$1, v, mid), config.zeroCrossVision);
  }

  void _onVelocity(_V p, double zeroCross) {
    _vel.add(p);
    _trackStillness(p);
    if (_concluded) return;
    if (!_inConcentric) {
      if (p.v > config.repStartVelocity) {
        // Extend back to the last zero crossing so the mean is not biased by the threshold.
        var i = _vel.length - 1;
        while (i > 0 && _vel[i - 1].v > zeroCross) {
          i--;
        }
        _segStartIdx = i > 0 ? i - 1 : 0;
        _inConcentric = true;
        _belowEndSinceNs = null;
      }
      return;
    }
    if (p.v < config.repEndVelocity) {
      _belowEndSinceNs ??= p.t;
      final timedOut = (p.t - _belowEndSinceNs!) / 1e9 >= config.repCloseTimeoutS;
      if (p.v <= zeroCross || timedOut) _closeRep(_vel.length - 1);
    } else {
      _belowEndSinceNs = null;
    }
  }

  void _closeRep(int endIdx) {
    _inConcentric = false;
    _belowEndSinceNs = null;
    final seg = _vel.sublist(_segStartIdx, endIdx + 1);
    if (seg.length < 2) return;
    var disp = 0.0;
    for (var i = 1; i < seg.length; i++) {
      disp += (seg[i].v + seg[i - 1].v) / 2 * (seg[i].t - seg[i - 1].t) / 1e9;
    }
    final dur = (seg.last.t - seg.first.t) / 1e9;
    double mean;
    if (seg.first.frame != null && seg.last.frame != null) {
      // Vision: raw displacement between the (shrunk) window ends / time between them.
      final k = config.visionWindowShrinkFrames;
      final a = seg.first.frame! + k, b = seg.last.frame! - k;
      if (b - a < 2) return;
      double yAt(int i) {
        final lo = math.max(0, i - 1), hi = math.min(_trackedY.length - 1, i + 1);
        var s = 0.0;
        for (var j = lo; j <= hi; j++) {
          s += _trackedY[j].$2;
        }
        return s / (hi - lo + 1);
      }

      disp = (yAt(a) - yAt(b)) * config.visionMetersPerUnit; // y down: rising bar -> y decreases
      final span = (_trackedY[b].$1 - _trackedY[a].$1) / 1e9;
      mean = span <= 0 ? 0 : disp / span;
    } else {
      mean = _propulsiveMean(seg);
    }
    if (dur < config.minConcentricS || disp < config.minRomM[ctx.exercise]!) return; // noise, not a rep
    final windowStart = _reps.isEmpty ? (_frames.isEmpty ? seg.first.t : _frames.first.tMonoNs) : _reps.last.endNs;
    var rep = RepResult(
      index: _reps.length + 1,
      startNs: seg.first.t,
      endNs: seg.last.t,
      meanVelocity: mean,
      displacementM: disp,
    );
    rep = _withVision(rep, windowStart);
    _reps.add(rep);
    _events.add(RepCompleted(rep.endNs, rep));
    if (rep.faults.isNotEmpty) _events.add(FaultDetected(rep.endNs, rep.index, rep.faults));
    final vl = _velocityLoss();
    if (!_fatigueSent && vl != null && vl >= ctx.cap) {
      _fatigueSent = true;
      _events.add(FatigueCapReached(rep.endNs, vl, ctx.cap));
    }
  }

  /// Mean propulsive velocity: mean over the concentric phase up to the point where the bar
  /// decelerates faster than gravity (braking phase). ASSUMPTION: acceleration from a
  /// finite difference over >= 50 ms (sample-to-sample differences are too noisy).
  double _propulsiveMean(List<_V> seg) {
    var end = seg.length - 1;
    var peak = 0;
    for (var i = 1; i < seg.length; i++) {
      if (seg[i].v > seg[peak].v) peak = i;
    }
    var k = 1;
    while (k < seg.length - 1 && seg[k].t - seg[0].t < 50000000) {
      k++;
    }
    for (var i = peak + k; i < seg.length; i++) {
      final a = (seg[i].v - seg[i - k].v) / ((seg[i].t - seg[i - k].t) / 1e9);
      if (a < -9.81) {
        end = i - 1;
        break;
      }
    }
    var area = 0.0;
    for (var i = 1; i <= end; i++) {
      area += (seg[i].v + seg[i - 1].v) / 2 * (seg[i].t - seg[i - 1].t);
    }
    final span = seg[end].t - seg.first.t;
    return span <= 0 ? seg.first.v : area / span;
  }

  RepResult _withVision(RepResult rep, int windowStartNs) {
    final window = [for (final f in _frames) if (f.tMonoNs >= windowStartNs && f.tMonoNs <= rep.endNs) f];
    if (window.isEmpty) return rep;
    PoseReading? deepest;
    for (final f in window) {
      final r = readPose(f.keypoints, ctx.exercise, config.minKeypointConfidence);
      final fl = r.flexion;
      if (fl != null && (deepest?.flexion == null || fl > deepest!.flexion!)) deepest = r;
    }
    if (deepest == null) return rep;
    final faults = <FaultFlag>{};
    final e = ctx.exercise;
    if (MetricsConfig.detectsValgus(e) && (deepest.kneeAnkleRatio ?? 1) < config.valgusKneeAnkleRatio) {
      faults.add(FaultFlag.valgus);
    }
    if (MetricsConfig.detectsLumbar(e) && (deepest.trunkLeanDeg ?? 0) > config.maxTrunkLeanDeg[e]!) {
      faults.add(FaultFlag.lumbarFlexion);
    }
    if (deepest.flexion! < config.minDepthDeg[e]!) faults.add(FaultFlag.incompleteRom);
    return rep.withVision(peakDepthDeg: deepest.flexion, symmetryPct: deepest.symmetryPct, faults: faults);
  }

  // ---------------- derived metrics ----------------

  double? get _mpvInitial =>
      _reps.isEmpty ? null : _reps.take(2).map((r) => r.meanVelocity).reduce(math.max);
  double? get _mpvFinal => _reps.isEmpty ? null : _reps.last.meanVelocity;

  /// (fastest of the first two reps - last rep) / fastest * 100. ASSUMPTION (docs/MQS.md).
  double? _velocityLoss() {
    final a = _mpvInitial, b = _mpvFinal;
    if (a == null || b == null || a <= 0) return null;
    return _r((a - b) / a * 100, 1);
  }

  double? get _symmetryIndex {
    final s = [for (final r in _reps) if (r.symmetryPct != null) r.symmetryPct!];
    return s.isEmpty ? null : _r(s.reduce((a, b) => a + b) / s.length, 1);
  }

  // ---------------- set conclusion ----------------

  void _trackStillness(_V p) {
    if (_inConcentric || _reps.isEmpty) {
      _stillSinceNs = null;
      return;
    }
    final from = p.t - (config.zeroMotionWindowS * 1e9).round();
    var sum = 0.0, n = 0;
    for (var i = _vel.length - 1; i >= 0 && _vel[i].t >= from; i--) {
      sum += _vel[i].v.abs();
      n++;
    }
    if (n > 0 && sum / n < config.zeroMotionSpeed) {
      _stillSinceNs ??= p.t;
    } else {
      _stillSinceNs = null;
    }
    _checkConclusion(p.t);
  }

  void _checkConclusion(int now) {
    if (_concluded || _reps.isEmpty || _inConcentric) return;
    final dwellNs = (config.rackedDwellS * 1e9).round();
    final racked = _rackedSinceNs != null && now - _rackedSinceNs! > dwellNs;
    final still = _stillSinceNs != null && now - _stillSinceNs! > dwellNs;
    if (racked || still) {
      _concluded = true;
      _events.add(SetConcluded(now, racked ? ConclusionReason.sensorRacked : ConclusionReason.zeroMotion));
    }
  }

  // ---------------- outputs ----------------

  LiveMetrics live() {
    double? liveMean;
    if (_inConcentric && _vel.length - _segStartIdx >= 2) {
      final seg = _vel.sublist(_segStartIdx);
      liveMean = seg.map((p) => p.v).reduce((a, b) => a + b) / seg.length;
    }
    final last = _reps.isEmpty ? null : _reps.last;
    return LiveMetrics(
      repCount: _reps.length,
      lastPeakDepthDeg: last?.peakDepthDeg,
      currentFlexionDeg: _lastPose?.flexion,
      liveConcentricMps: liveMean,
      lastRepMps: last?.meanVelocity,
      velocityLossPct: _velocityLoss(),
      vlCapPct: ctx.cap,
      skeletonColor: _skeletonColor(last),
      velocityConfidenceLow: !_useImuVelocity,
      concluded: _concluded,
    );
  }

  SkeletonColor _skeletonColor(RepResult? last) {
    final p = _lastPose;
    final e = ctx.exercise;
    final deepEnough = (p?.flexion ?? 0) > 0.5 * config.minDepthDeg[e]!;
    final liveValgus = MetricsConfig.detectsValgus(e) && deepEnough && (p?.kneeAnkleRatio ?? 1) < config.valgusKneeAnkleRatio;
    final liveLumbar = MetricsConfig.detectsLumbar(e) && (p?.trunkLeanDeg ?? 0) > config.maxTrunkLeanDeg[e]!;
    if (liveValgus || liveLumbar) return SkeletonColor.red;
    if (last == null) return SkeletonColor.green;
    if (last.faults.contains(FaultFlag.valgus) || last.faults.contains(FaultFlag.lumbarFlexion)) return SkeletonColor.red;
    if (last.faults.contains(FaultFlag.incompleteRom)) return SkeletonColor.yellow;
    return SkeletonColor.green;
  }

  /// Build the contract payload. Re-evaluates every rep against ALL frames received
  /// (late frames included), so the payload is the authoritative result.
  SetSummaryPayload finish({DateTime? startedAt, DateTime? endedAt}) {
    if (_inConcentric) _closeRep(_vel.length - 1);
    for (var i = 0; i < _reps.length; i++) {
      final start = i == 0 ? (_frames.isEmpty ? _reps[0].startNs : _frames.first.tMonoNs) : _reps[i - 1].endNs;
      _reps[i] = _withVision(_reps[i], start);
    }
    final hasVelocity = velocitySource != null && _reps.isNotEmpty;
    final vl = hasVelocity ? _velocityLoss() : null;
    final perRep = [
      for (final r in _reps)
        RepMetrics(
          repIndex: r.index,
          peakDepthDeg: r.peakDepthDeg == null ? null : _r(r.peakDepthDeg!, 1),
          meanVelocityMS: hasVelocity ? _r(r.meanVelocity, 3) : null,
          faultFlags: [for (final f in FaultFlag.values) if (r.faults.contains(f)) f],
        ),
    ];
    final si = _symmetryIndex;
    final mqs = computeMqs(
      reps: _reps, exercise: ctx.exercise, velocityLossPct: vl, vlCapPct: ctx.cap,
      symmetryIndex: si, visionAvailable: _frames.isNotEmpty, config: config,
    );
    final payload = SetSummaryPayload(
      setId: ctx.setId,
      exercise: ctx.exercise,
      goal: ctx.goal,
      vlCapPct: ctx.cap,
      setIndex: ctx.setIndex,
      repsCompleted: _reps.length,
      loadKg: ctx.loadKg,
      perRep: perRep,
      mpvInitial: hasVelocity ? _r(_mpvInitial!, 3) : null,
      mpvFinal: hasVelocity ? _r(_mpvFinal!, 3) : null,
      velocityLossPct: vl,
      vlCapExceeded: vl != null && vl >= ctx.cap,
      velocitySource: hasVelocity ? velocitySource : null,
      mqsScore: mqs.score,
      mqsBreakdown: mqs.score == null ? null : mqs.breakdown,
      symmetryIndex: si,
      faultCounts: FaultCounts.tally(perRep),
      dataSource: ctx.dataSource,
      deviceLabels: ctx.deviceLabels,
      startedAt: startedAt,
      endedAt: endedAt,
    );
    payload.validate();
    return payload;
  }

  static double _r(double v, int d) {
    final p = math.pow(10, d);
    return (v * p).roundToDouble() / p;
  }
}
