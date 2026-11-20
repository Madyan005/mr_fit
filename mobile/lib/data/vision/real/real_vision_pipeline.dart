// REAL SLOT — concrete pose runtime goes here (TFLite MoveNet, MediaPipe Pose, ...).
// Undecided (docs/DECISIONS.md O-2/O-3). See docs/INTEGRATION_GUIDE.md.
//
// To implement:
//  1. Convert CameraFrame.planes (YUV420 from the camera plugin) to the model input.
//  2. Run inference OFF the UI thread (isolate / platform thread).
//  3. Return COCO-17 keypoints normalised to 0..1 (x right, y down) with confidences,
//     personInFrame, and a framingScore (whole body visible) for Phase 3.
//  4. Honour setTargetFps (30 live, 10 at rest) by dropping frames.
//  5. Bind it in lib/app/bindings.dart and run test/data/vision_pipeline_contract_test.dart.

import '../../../domain/vision/vision_models.dart';
import '../../../domain/vision/vision_pipeline.dart';

class RealVisionPipeline implements VisionPipeline {
  int _fps = 30;

  @override
  VisionCapabilities get capabilities => const VisionCapabilities(pipelineName: 'unimplemented');

  @override
  Stream<VisionFrameResult> analyze(CameraFrame f) =>
      throw UnimplementedError('REAL SLOT: no pose model chosen yet (O-3)');

  @override
  void setTargetFps(int fps) => _fps = fps;

  @override
  int get targetFps => _fps;
}
