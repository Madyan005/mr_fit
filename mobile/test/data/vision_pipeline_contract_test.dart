// What every VisionPipeline must return, so positioning (Phase 3), the HUD skeleton and
// the engine's fault checks work with it unchanged (docs/INTEGRATION_GUIDE.md). Runs
// against MockVisionPipeline today. A real pipeline is added to `subjects` with a frame
// source of its own (for example recorded camera frames of a person squatting).
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/core/clock.dart';
import 'package:mr_fit/data/sensors/mock/mock_world.dart';
import 'package:mr_fit/data/sensors/mock/scenarios.dart';
import 'package:mr_fit/data/vision/mock/mock_vision_pipeline.dart';
import 'package:mr_fit/domain/vision/vision_models.dart';
import 'package:mr_fit/domain/vision/vision_pipeline.dart';

typedef VisionSubject = ({
  String name,
  VisionPipeline Function() create,

  /// Frames over a few seconds of a person in view (live set).
  List<CameraFrame> Function() frames,
});

final subjects = <VisionSubject>[
  (
    name: 'MockVisionPipeline',
    create: () => MockVisionPipeline(world: MockWorld(scenario: Scenarios.valgus, clock: FakeClock())..startSet(0)),
    frames: () => [
          for (var i = 0; i < 90; i++) CameraFrame(tMonoNs: i * 33333333, width: 0, height: 0), // 3 s at 30 fps
        ],
  ),
];

void main() {
  for (final subject in subjects) {
    group(subject.name, () {
      test('declares a name, COCO-17 keypoints and a frame rate', () {
        final caps = subject.create().capabilities;
        expect(caps.pipelineName, isNotEmpty);
        expect(caps.keypointSet, 'coco17', reason: 'the engine reads COCO-17 indices (Coco17)');
        expect(caps.maxFps, greaterThan(0));
      });

      test('honours the target frame rate (30 live, 10 at rest)', () {
        final p = subject.create();
        p.setTargetFps(10);
        expect(p.targetFps, 10);
        p.setTargetFps(30);
        expect(p.targetFps, 30);
      });

      test('results: capture time, 17 normalised keypoints, framing score', () async {
        final p = subject.create();
        final results = <(CameraFrame, VisionFrameResult)>[];
        for (final f in subject.frames()) {
          await for (final r in p.analyze(f)) {
            results.add((f, r));
          }
        }
        expect(results, isNotEmpty, reason: 'a pipeline may skip frames, not all of them');
        expect(results.where((r) => r.$2.personInFrame), isNotEmpty, reason: 'the person in view is found');
        for (final (frame, r) in results) {
          // Phone clock, capture time. A pipeline that owns the camera answers the
          // session's request with its newest result, so it may be a little older.
          expect(r.tMonoNs, lessThanOrEqualTo(frame.tMonoNs), reason: 'not from the future');
          expect(frame.tMonoNs - r.tMonoNs, lessThanOrEqualTo(200 * 1000000), reason: 'at most 200 ms old');
          if (r.framingScore case final s?) expect(s, inInclusiveRange(0.0, 1.0));
          if (!r.personInFrame) continue;
          expect(r.keypoints, hasLength(Coco17.count));
          for (final k in r.keypoints) {
            expect(k.x, inInclusiveRange(0.0, 1.0), reason: 'x normalised, 0 = left');
            expect(k.y, inInclusiveRange(0.0, 1.0), reason: 'y normalised, 0 = top');
            expect(k.confidence, inInclusiveRange(0.0, 1.0));
          }
          // y grows downwards: the ankles are below the shoulders of a standing lifter.
          final ankles = (r.keypoints[Coco17.leftAnkle].y + r.keypoints[Coco17.rightAnkle].y) / 2;
          final shoulders = (r.keypoints[Coco17.leftShoulder].y + r.keypoints[Coco17.rightShoulder].y) / 2;
          expect(ankles, greaterThan(shoulders));
        }
      });
    });
  }
}
