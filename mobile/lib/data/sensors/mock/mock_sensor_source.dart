/// SIMULATED. MockSensorSource: ~100 Hz synthetic bar motion following the shared
/// [MockWorld] scenario. Configurable noise, fatigue drift and fault injection (via the
/// Scenario), seeded RNG (deterministic), battery drain, racked dwell after the last rep,
/// a sensor clock that runs ahead of the phone (Phase 4 recovers it), and tap spikes.
library;

import 'dart:async';

import '../../../core/clock.dart';
import '../../../core/seeded_random.dart';
import '../../../domain/sensors/channels.dart';
import '../../../domain/sensors/sensor_models.dart';
import '../../../domain/sensors/sensor_source.dart';
import '../../../domain/timesync/time_sync.dart';
import 'mock_world.dart';
import 'scenarios.dart';

const _g = 9.81;

class MockSensorSource implements SensorSource {
  MockSensorSource({
    required this.world,
    this.timeSync,
    Set<String>? channels,
    this.sampleRateHz = 100,
    this.onHaptic,
  })  : _channels = channels ?? defaultChannels,
        _rng = SeededRandom(world.scenario.seed);

  /// Everything a bar-mounted IMU could offer. Drop entries to simulate weaker sources
  /// (e.g. no `bar_vel_z` -> the engine must derive velocity from vision).
  static const defaultChannels = {
    Channels.accelX, Channels.accelY, Channels.accelZ, Channels.gyroX, Channels.gyroY, Channels.gyroZ,
    Channels.barVelZ, Channels.barAccelZ, Channels.barTiltRoll, Channels.batteryPct,
  };

  final MockWorld world;
  final TimeSync? timeSync;
  final Set<String> _channels;
  final double sampleRateHz;
  final void Function(HapticCommand)? onHaptic;
  final SeededRandom _rng;

  final _samples = StreamController<SensorSample>.broadcast();
  final _status = StreamController<DeviceStatus>.broadcast();
  final List<HapticCommand> sentCommands = [];
  final List<int> _pendingTapsPhoneNs = [];
  Timer? _timer;
  int _nextSampleIdx = 0;
  int? _epochNs; // phone time of sample index 0
  bool _connected = false;

  Scenario get scenario => world.scenario;
  String get sourceName => 'MockSensorSource';
  int get _periodNs => (1e9 / sampleRateHz).round();
  int get _clockOffsetNs => scenario.sensorClockOffsetMs * 1000000;

  @override
  SensorCapabilities get capabilities =>
      SensorCapabilities(sourceName: sourceName, channels: _channels, nominalSampleRateHz: sampleRateHz);

  @override
  Stream<SensorSample> samples() => _samples.stream;

  @override
  Stream<DeviceStatus> status() => _status.stream;

  @override
  Future<void> connect() async {
    if (_connected) return;
    _connected = true;
    _epochNs = world.clock.nowNs();
    _nextSampleIdx = 0;
    _status.add(_statusAt(_epochNs!));
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _tick());
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    _connected = false;
    _status.add(DeviceStatus.disconnected);
  }

  @override
  Future<void> sendCommand(HapticCommand c) async {
    sentCommands.add(c);
    onHaptic?.call(c);
  }

  /// Phase 4: the athlete taps the bar; the mock sensor "feels" it at the same instant.
  void simulateTap(int phoneMonoNs) => _pendingTapsPhoneNs.add(phoneMonoNs);

  Future<void> dispose() async {
    await disconnect();
    await _samples.close();
    await _status.close();
  }

  // ---------------- generation ----------------

  void _tick() {
    final epoch = _epochNs;
    if (epoch == null) return;
    final now = world.clock.nowNs();
    while (epoch + _nextSampleIdx * _periodNs <= now) {
      final tPhone = epoch + _nextSampleIdx * _periodNs;
      for (final s in sampleAt(tPhone, index: _nextSampleIdx)) {
        _samples.add(s);
      }
      if (_nextSampleIdx % sampleRateHz.round() == 0) _status.add(_statusAt(tPhone));
      _nextSampleIdx++;
    }
  }

  DeviceStatus _statusAt(int tPhone) => DeviceStatus(
        connected: true,
        sourceLabel: '$sourceName (SIMULATED)',
        batteryPct: _batteryAt(tPhone),
        rssi: -55,
        calibrated: timeSync?.isCalibrated ?? false,
        restingDwell: world.isRacked(tPhone),
      );

  double _batteryAt(int tPhone) {
    final elapsed = nsToSeconds(tPhone - (_epochNs ?? tPhone));
    return (scenario.batteryStartPct - elapsed * scenario.batteryDrainPctPerS).clamp(0, 100).toDouble();
  }

  /// All channel samples for one sample instant [tPhone] (true phone time). Timestamps
  /// are what a real source would emit: sensor clock mapped through TimeSync (uncalibrated
  /// -> still [sensorClockOffsetMs] ahead).
  List<SensorSample> sampleAt(int tPhone, {required int index}) {
    final m = world.motionAt(tPhone);
    final tap = _consumeTap(tPhone);
    final sensorNs = tPhone + _clockOffsetNs;
    final stamp = timeSync?.toPhoneMonoNs(sensorNs) ?? sensorNs;
    final out = <SensorSample>[];
    void add(String ch, double v) {
      if (_channels.contains(ch)) out.add(SensorSample(channel: ch, value: v, tMonoNs: stamp, source: sourceName));
    }

    final vn = scenario.velocityNoiseStd, an = scenario.accelNoiseStd;
    // Fixed draw order -> deterministic for a given seed.
    final nv = _rng.gaussian(), na = _rng.gaussian(), nx = _rng.gaussian(), ny = _rng.gaussian();
    final nz = _rng.gaussian(), g1 = _rng.gaussian(), g2 = _rng.gaussian(), g3 = _rng.gaussian();
    final nr = _rng.gaussian();
    add(Channels.barVelZ, m.velocity + vn * nv);
    add(Channels.barAccelZ, m.accel + an * na);
    add(Channels.accelX, an * nx);
    add(Channels.accelY, an * ny);
    add(Channels.accelZ, _g + m.accel + an * nz + (tap ? 25.0 : 0.0));
    add(Channels.gyroX, 0.02 * g1 + 0.3 * m.velocity);
    add(Channels.gyroY, 0.02 * g2);
    add(Channels.gyroZ, 0.02 * g3);
    add(Channels.barTiltRoll, scenario.asymmetryDeg * 0.5 * m.depthFraction + 0.2 * nr);
    if (index % sampleRateHz.round() == 0) add(Channels.batteryPct, _batteryAt(tPhone));
    return out;
  }

  bool _consumeTap(int tPhone) {
    final i = _pendingTapsPhoneNs.indexWhere((t) => t <= tPhone);
    if (i < 0) return false;
    _pendingTapsPhoneNs.removeAt(i);
    return true;
  }

  /// Pure, timer-free generation of a whole set (tests, golden data). Starts the set at
  /// [startNs] and returns every sample until [durationS] seconds later, plus statuses.
  ({List<SensorSample> samples, List<(int, DeviceStatus)> statuses}) generateSet({int startNs = 0, double? durationS}) {
    world.startSet(startNs);
    _epochNs = startNs;
    final dur = durationS ?? world.timeline.rackedFromS + 3.0;
    final n = (dur * sampleRateHz).ceil();
    final samples = <SensorSample>[];
    final statuses = <(int, DeviceStatus)>[];
    for (var i = 0; i < n; i++) {
      final t = startNs + i * _periodNs;
      samples.addAll(sampleAt(t, index: i));
      if (i % 10 == 0) statuses.add((t, _statusAt(t)));
    }
    return (samples: samples, statuses: statuses);
  }
}
