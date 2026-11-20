/// Runs [MetricsEngine] in a background Isolate so parsing, segmentation and pose math
/// never touch the UI thread. Inputs are batched by the caller; the worker publishes
/// [LiveMetrics] at most every `config.liveEmitIntervalMs` (~60 Hz) plus engine events.
library;

import 'dart:async';
import 'dart:isolate';

import '../contracts/set_summary_payload.dart';
import '../sensors/sensor_models.dart';
import '../vision/vision_models.dart';
import 'live_metrics.dart';
import 'metrics_config.dart';
import 'metrics_engine.dart';

sealed class _Msg {
  const _Msg();
}

final class _Samples extends _Msg {
  const _Samples(this.items);
  final List<SensorSample> items;
}

final class _Frames extends _Msg {
  const _Frames(this.items);
  final List<VisionFrameResult> items;
}

final class _Status extends _Msg {
  const _Status(this.status, this.tMonoNs);
  final DeviceStatus status;
  final int tMonoNs;
}

final class _Finish extends _Msg {
  const _Finish(this.reply, this.startedAt, this.endedAt);
  final SendPort reply;
  final DateTime? startedAt;
  final DateTime? endedAt;
}

final class _Init {
  const _Init(this.ctx, this.caps, this.config, this.out);
  final SetContext ctx;
  final SensorCapabilities caps;
  final MetricsConfig config;
  final SendPort out;
}

class MetricsWorker {
  MetricsWorker._(this._isolate, this._toWorker, this._fromWorker, this.live, this.events);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;

  /// Throttled HUD state (~60 Hz).
  final Stream<LiveMetrics> live;
  final Stream<EngineEvent> events;

  static Future<MetricsWorker> start(SetContext ctx, SensorCapabilities caps,
      {MetricsConfig config = const MetricsConfig()}) async {
    final fromWorker = ReceivePort();
    final liveCtl = StreamController<LiveMetrics>.broadcast();
    final eventCtl = StreamController<EngineEvent>.broadcast();
    final ready = Completer<SendPort>();
    fromWorker.listen((m) {
      switch (m) {
        case final SendPort p:
          ready.complete(p);
        case final LiveMetrics l:
          liveCtl.add(l);
        case final EngineEvent e:
          eventCtl.add(e);
      }
    });
    final iso = await Isolate.spawn(_main, _Init(ctx, caps, config, fromWorker.sendPort),
        debugName: 'MetricsWorker');
    return MetricsWorker._(iso, await ready.future, fromWorker, liveCtl.stream, eventCtl.stream);
  }

  void addSamples(List<SensorSample> batch) => _toWorker.send(_Samples(batch));
  void addFrames(List<VisionFrameResult> batch) => _toWorker.send(_Frames(batch));
  void updateStatus(DeviceStatus s, int tMonoNs) => _toWorker.send(_Status(s, tMonoNs));

  Future<SetSummaryPayload> finish({DateTime? startedAt, DateTime? endedAt}) async {
    final reply = ReceivePort();
    _toWorker.send(_Finish(reply.sendPort, startedAt, endedAt));
    final result = await reply.first;
    reply.close();
    if (result is SetSummaryPayload) return result;
    throw StateError('MetricsWorker.finish failed: $result');
  }

  void dispose() {
    _fromWorker.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _main(_Init init) {
    final engine = MetricsEngine(ctx: init.ctx, capabilities: init.caps, config: init.config);
    final inbox = ReceivePort();
    init.out.send(inbox.sendPort);
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    void flush({bool force = false}) {
      for (final e in engine.drainEvents()) {
        init.out.send(e);
      }
      final now = DateTime.now();
      if (force || now.difference(lastEmit).inMilliseconds >= init.config.liveEmitIntervalMs) {
        lastEmit = now;
        init.out.send(engine.live());
      }
    }

    inbox.listen((m) {
      switch (m) {
        case _Samples(:final items):
          engine.addSamples(items);
          flush();
        case _Frames(:final items):
          engine.addFrames(items);
          flush();
        case _Status(:final status, :final tMonoNs):
          engine.updateStatus(status, tMonoNs);
          flush();
        case _Finish(:final reply, :final startedAt, :final endedAt):
          try {
            reply.send(engine.finish(startedAt: startedAt, endedAt: endedAt));
          } catch (e) {
            reply.send('error: $e');
          }
          flush(force: true);
      }
    });
  }
}
