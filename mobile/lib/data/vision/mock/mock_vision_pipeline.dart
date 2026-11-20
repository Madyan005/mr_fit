/// SIMULATED. MockVisionPipeline: scripted COCO-17 skeleton per exercise, driven by the
/// same [MockWorld] timeline as MockSensorSource. Injects the scenario's faults (valgus,
/// lumbar flexion, incomplete ROM via the scripted depth), keypoint noise (seeded per
/// frame timestamp -> deterministic), and a framing score for Phase 3.
library;

import 'dart:math' as math;

import '../../../core/seeded_random.dart';
import '../../../domain/vision/vision_models.dart';
import '../../../domain/vision/vision_pipeline.dart';
import '../../../domain/workout/workout_models.dart';
import '../../sensors/mock/mock_body.dart';
import '../../sensors/mock/mock_world.dart';
import '../../sensors/mock/scenario_timeline.dart';

class MockVisionPipeline implements VisionPipeline {
  MockVisionPipeline({required this.world});

  final MockWorld world;
  int _fps = 30;

  static const lumbarExtraLeanDeg = 30.0;

  @override
  VisionCapabilities get capabilities => const VisionCapabilities(pipelineName: 'MockVisionPipeline');

  @override
  void setTargetFps(int fps) => _fps = fps.clamp(1, 60);

  @override
  int get targetFps => _fps;

  @override
  Stream<VisionFrameResult> analyze(CameraFrame f) => Stream.value(frameAt(f.tMonoNs));

  /// Pure: the skeleton at phone time [tMonoNs].
  VisionFrameResult frameAt(int tMonoNs) {
    final s = world.scenario;
    final m = world.motionAt(tMonoNs);
    final f = world.timeline.flexionAt(m);
    final faults = m.rep >= 0 ? s.reps[m.rep].faults : const <FaultFlag>{};
    final inRep = m.rep >= 0 && m.phase != MotionPhase.topPause;
    final depthFrac = inRep ? m.depthFraction : 0.0;
    final asym = s.asymmetryDeg * depthFrac;
    final kp = MockBody.pose(
      s.exercise,
      f + asym / 2,
      f - asym / 2,
      valgus: faults.contains(FaultFlag.valgus) ? depthFrac : 0,
      extraLeanDeg: faults.contains(FaultFlag.lumbarFlexion) ? lumbarExtraLeanDeg * depthFrac : 0,
    );
    final rng = SeededRandom(s.seed * 7919 + (tMonoNs ~/ 1000000));
    final noisy = [
      for (final k in kp)
        Keypoint(k.x + s.keypointNoiseStd * rng.gaussian(), k.y + s.keypointNoiseStd * rng.gaussian(),
            math.min(1.0, k.confidence + 0.02 * rng.gaussian()).clamp(0.0, 1.0).toDouble()),
    ];
    return VisionFrameResult(
      tMonoNs: tMonoNs,
      keypoints: noisy,
      personInFrame: true,
      framingScore: world.framingScore(tMonoNs),
    );
  }

  /// Pure: frames at the target FPS over a whole generated set (tests).
  List<VisionFrameResult> generateSet({required int startNs, required double durationS}) {
    final period = (1e9 / _fps).round();
    final n = (durationS * _fps).ceil();
    return [for (var i = 0; i < n; i++) frameAt(startNs + i * period)];
  }
}
