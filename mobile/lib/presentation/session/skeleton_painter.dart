import 'package:material_ui/material_ui.dart';

import '../../domain/metrics/live_metrics.dart';
import '../../domain/vision/vision_models.dart';

/// COCO-17 bones.
const cocoBones = [
  (Coco17.leftShoulder, Coco17.rightShoulder), (Coco17.leftHip, Coco17.rightHip),
  (Coco17.leftShoulder, Coco17.leftHip), (Coco17.rightShoulder, Coco17.rightHip),
  (Coco17.leftShoulder, Coco17.leftElbow), (Coco17.leftElbow, Coco17.leftWrist),
  (Coco17.rightShoulder, Coco17.rightElbow), (Coco17.rightElbow, Coco17.rightWrist),
  (Coco17.leftHip, Coco17.leftKnee), (Coco17.leftKnee, Coco17.leftAnkle),
  (Coco17.rightHip, Coco17.rightKnee), (Coco17.rightKnee, Coco17.rightAnkle),
  (Coco17.leftShoulder, Coco17.nose), (Coco17.rightShoulder, Coco17.nose),
];

Color skeletonColorOf(SkeletonColor? c) => switch (c) {
      SkeletonColor.red => Colors.redAccent,
      SkeletonColor.yellow => Colors.amberAccent,
      _ => Colors.lightGreenAccent,
    };

/// Draws normalised (0..1, y down) keypoints into a square area. Low-confidence points
/// and their bones are skipped.
class SkeletonPainter extends CustomPainter {
  SkeletonPainter(this.keypoints, this.color, {this.minConfidence = 0.3});
  final List<Keypoint> keypoints;
  final Color color;
  final double minConfidence;

  @override
  void paint(Canvas canvas, Size size) {
    if (keypoints.length < Coco17.count) return;
    final side = size.shortestSide;
    final dx = (size.width - side) / 2, dy = (size.height - side) / 2;
    Offset at(Keypoint k) => Offset(dx + k.x * side, dy + k.y * side);
    final bone = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in cocoBones) {
      final ka = keypoints[a], kb = keypoints[b];
      if (ka.confidence < minConfidence || kb.confidence < minConfidence) continue;
      canvas.drawLine(at(ka), at(kb), bone);
    }
    final joint = Paint()..color = color;
    for (final k in keypoints) {
      if (k.confidence >= minConfidence) canvas.drawCircle(at(k), 4, joint);
    }
  }

  @override
  bool shouldRepaint(SkeletonPainter old) => old.keypoints != keypoints || old.color != color;
}

/// Dark "camera" area with the skeleton. In mock mode there is no camera preview, only
/// the simulated pose, and it is labelled as such.
class SkeletonView extends StatelessWidget {
  const SkeletonView({super.key, required this.pose, this.color, this.simulated = true, this.height = 240});
  final List<Keypoint>? pose;
  final SkeletonColor? color;
  final bool simulated;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = pose;
    return Container(
      key: const Key('session.skeleton'),
      height: height,
      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
      child: Stack(children: [
        Positioned.fill(
          child: p == null
              ? const Center(child: Text('No person in view', style: TextStyle(color: Colors.white70)))
              : CustomPaint(painter: SkeletonPainter(p, skeletonColorOf(color))),
        ),
        if (simulated)
          const Positioned(
            left: 8,
            top: 8,
            child: Text('SIMULATED POSE', style: TextStyle(color: Colors.amber, fontSize: 11, letterSpacing: 1)),
          ),
      ]),
    );
  }
}
