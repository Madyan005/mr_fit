/// Pose models. Coordinates are normalised to the frame: x right, y DOWN, both 0..1.
library;

final class Keypoint {
  const Keypoint(this.x, this.y, this.confidence);
  final double x;
  final double y;
  final double confidence;

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'confidence': confidence};
}

/// COCO-17 keypoint order (default keypoint set).
abstract final class Coco17 {
  static const nose = 0, leftEye = 1, rightEye = 2, leftEar = 3, rightEar = 4;
  static const leftShoulder = 5, rightShoulder = 6, leftElbow = 7, rightElbow = 8;
  static const leftWrist = 9, rightWrist = 10, leftHip = 11, rightHip = 12;
  static const leftKnee = 13, rightKnee = 14, leftAnkle = 15, rightAnkle = 16;
  static const count = 17;
}

final class VisionCapabilities {
  const VisionCapabilities({required this.pipelineName, this.keypointSet = 'coco17', this.maxFps = 30});
  final String pipelineName;
  final String keypointSet;
  final int maxFps;
}

final class VisionFrameResult {
  const VisionFrameResult({
    required this.tMonoNs,
    required this.keypoints,
    required this.personInFrame,
    this.framingScore,
  });

  final int tMonoNs;
  final List<Keypoint> keypoints;
  final bool personInFrame;

  /// 0..1: how well the whole body is framed (Phase 3 pass/fail). Null if unknown.
  final double? framingScore;
}

/// A camera frame handed to a pipeline. Pixel data is opaque here; real pipelines
/// interpret [planes] (e.g. YUV420 from the camera plugin).
final class CameraFrame {
  const CameraFrame({required this.tMonoNs, required this.width, required this.height, this.planes = const []});
  final int tMonoNs;
  final int width;
  final int height;
  final List<List<int>> planes;
}
