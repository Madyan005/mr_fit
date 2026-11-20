import 'dart:async';

import '../contracts/set_summary_payload.dart';
import '../sensors/sensor_models.dart';
import '../vision/vision_models.dart';
import 'live_metrics.dart';
import 'metrics_config.dart';
import 'metrics_engine.dart';

/// One running set's metrics. The app uses [MetricsWorker] (engine in an Isolate);
/// tests and fake-time runs use [InlineMetricsSession] (same engine, same thread).
abstract interface class LiveMetricsSession {
  Stream<LiveMetrics> get live;
  Stream<EngineEvent> get events;
  void addSamples(List<SensorSample> batch);
  void addFrames(List<VisionFrameResult> batch);
  void updateStatus(DeviceStatus s, int tMonoNs);
  Future<SetSummaryPayload> finish({DateTime? startedAt, DateTime? endedAt});
  void dispose();
}

typedef MetricsSessionFactory = Future<LiveMetricsSession> Function(SetContext ctx, SensorCapabilities caps);

class InlineMetricsSession implements LiveMetricsSession {
  InlineMetricsSession(SetContext ctx, SensorCapabilities caps, {MetricsConfig config = const MetricsConfig()})
      : _engine = MetricsEngine(ctx: ctx, capabilities: caps, config: config);

  final MetricsEngine _engine;
  final _live = StreamController<LiveMetrics>.broadcast(sync: true);
  final _events = StreamController<EngineEvent>.broadcast(sync: true);

  static Future<LiveMetricsSession> start(SetContext ctx, SensorCapabilities caps) async =>
      InlineMetricsSession(ctx, caps);

  @override
  Stream<LiveMetrics> get live => _live.stream;
  @override
  Stream<EngineEvent> get events => _events.stream;

  void _flush() {
    for (final e in _engine.drainEvents()) {
      _events.add(e);
    }
    _live.add(_engine.live());
  }

  @override
  void addSamples(List<SensorSample> batch) {
    _engine.addSamples(batch);
    _flush();
  }

  @override
  void addFrames(List<VisionFrameResult> batch) {
    _engine.addFrames(batch);
    _flush();
  }

  @override
  void updateStatus(DeviceStatus s, int tMonoNs) {
    _engine.updateStatus(s, tMonoNs);
    _flush();
  }

  @override
  Future<SetSummaryPayload> finish({DateTime? startedAt, DateTime? endedAt}) async {
    final p = _engine.finish(startedAt: startedAt, endedAt: endedAt);
    _flush();
    return p;
  }

  @override
  void dispose() {
    _live.close();
    _events.close();
  }
}
