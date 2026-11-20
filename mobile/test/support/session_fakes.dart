import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/app/session/session_providers.dart';
import 'package:mr_fit/core/clock.dart';
import 'package:mr_fit/data/timesync/tap_time_sync.dart';
import 'package:mr_fit/data/vision/mock/mock_vision_pipeline.dart';
import 'package:mr_fit/domain/contracts/set_summary_payload.dart';
import 'package:mr_fit/domain/metrics/metrics_session.dart';
import 'package:mr_fit/domain/sensors/channels.dart';
import 'package:mr_fit/domain/sensors/sensor_models.dart';
import 'package:mr_fit/domain/sensors/sensor_source.dart';
import 'package:mr_fit/domain/session/session_ports.dart';

/// Phone clock that follows fake time.
class FakeAsyncClock implements MonotonicClock {
  FakeAsyncClock(this.fa);
  final FakeAsync fa;
  @override
  int nowNs() => fa.elapsed.inMicroseconds * 1000;
}

class RecordingCues implements CueOutput {
  final spoken = <String>[];
  final haptics = <HapticCommand>[];
  @override
  Future<void> haptic(HapticCommand c) async => haptics.add(c);
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  Future<void> stopSpeaking() async {}
}

class RecordingKeepAlive implements KeepAlive {
  bool? simulated;
  bool running = false;
  @override
  Future<void> start({required bool simulated}) async {
    this.simulated = simulated;
    running = true;
  }

  @override
  Future<void> stop() async => running = false;
}

/// Overrides for a session on fake time: inline metrics, recorded cues, a set sink.
List<Override> sessionOverrides({
  required MonotonicClock clock,
  required RecordingCues cues,
  required RecordingKeepAlive keepAlive,
  required List<SetSummaryPayload> saved,
  SourceMode mode = SourceMode.mock,
  SensorSource Function()? sensor,
}) =>
    [
      // A custom sensor replaces only the sensor of the mock binding.
      if (sensor == null)
        ...sourceOverrides(mode)
      else ...[
        sourceModeProvider.overrideWithValue(SourceMode.mock),
        timeSyncProvider.overrideWith((ref) => TapTimeSync()),
        sensorSourceProvider.overrideWith((ref) => sensor()),
        visionPipelineProvider.overrideWith((ref) => MockVisionPipeline(world: ref.watch(mockWorldProvider))),
        simulationHooksProvider.overrideWith((ref) => ref.watch(mockWorldProvider)),
      ],
      monotonicClockProvider.overrideWithValue(clock),
      cueOutputProvider.overrideWithValue(cues),
      keepAliveProvider.overrideWithValue(keepAlive),
      metricsSessionFactoryProvider.overrideWithValue(InlineMetricsSession.start),
      completedSetSinkProvider.overrideWithValue((p) async => saved.add(p)),
    ];

/// A connected sensor that streams a still bar at 100 Hz and never feels a tap.
class QuietSensor implements SensorSource {
  QuietSensor(this.clock);
  final MonotonicClock clock;
  final _samples = StreamController<SensorSample>.broadcast();
  final _status = StreamController<DeviceStatus>.broadcast();
  Timer? _timer;

  @override
  SensorCapabilities get capabilities =>
      const SensorCapabilities(sourceName: 'QuietSensor', channels: {Channels.accelZ}, nominalSampleRateHz: 100);
  @override
  Stream<SensorSample> samples() => _samples.stream;
  @override
  Stream<DeviceStatus> status() => _status.stream;
  @override
  Future<void> connect() async {
    _status.add(const DeviceStatus(connected: true, sourceLabel: 'QuietSensor'));
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _samples
        .add(SensorSample(channel: Channels.accelZ, value: 9.81, tMonoNs: clock.nowNs(), source: 'QuietSensor')));
  }

  @override
  Future<void> disconnect() async => _timer?.cancel();
  @override
  Future<void> sendCommand(HapticCommand c) async {}
}
