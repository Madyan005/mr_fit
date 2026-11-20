import 'vision_models.dart';

/// Pose analysis. Implementations: `data/vision/mock/` (MockVisionPipeline) and
/// `data/vision/real/` (REAL SLOT, e.g. TFLite MoveNet or MediaPipe — undecided, O-3).
abstract class VisionPipeline {
  VisionCapabilities get capabilities;

  /// Analyse one frame. A stream because some runtimes emit asynchronously or skip frames.
  Stream<VisionFrameResult> analyze(CameraFrame f);

  /// 30 during a live set, 10 during rest (Phase 6).
  void setTargetFps(int fps);

  int get targetFps;
}
