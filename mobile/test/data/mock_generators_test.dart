// Mock generators: seeded + deterministic, honour capabilities and DeviceStatus.
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/core/clock.dart';
import 'package:mr_fit/data/sensors/mock/mock_body.dart';
import 'package:mr_fit/data/sensors/mock/mock_sensor_source.dart';
import 'package:mr_fit/data/sensors/mock/mock_world.dart';
import 'package:mr_fit/data/sensors/mock/scenario_timeline.dart';
import 'package:mr_fit/data/sensors/mock/scenarios.dart';
import 'package:mr_fit/data/timesync/mock_time_sync.dart';
import 'package:mr_fit/data/timesync/tap_time_sync.dart';
import 'package:mr_fit/data/vision/mock/mock_vision_pipeline.dart';
import 'package:mr_fit/domain/metrics/pose_geometry.dart';
import 'package:mr_fit/domain/sensors/channels.dart';
import 'package:mr_fit/domain/sensors/sensor_models.dart';
import 'package:mr_fit/domain/timesync/time_sync.dart';
import 'package:mr_fit/domain/workout/workout_models.dart';

MockSensorSource sensor(Scenario s, {Set<String>? channels, TimeSync? sync}) =>
    MockSensorSource(world: MockWorld(scenario: s, clock: FakeClock()), channels: channels, timeSync: sync);

void main() {
  test('same seed -> identical samples; different seed -> different', () {
    final a = sensor(Scenarios.clean).generateSet(durationS: 5).samples;
    final b = sensor(Scenarios.clean).generateSet(durationS: 5).samples;
    final c = sensor(Scenarios.clean.copyWith(seed: 7)).generateSet(durationS: 5).samples;
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      expect(a[i].value, b[i].value);
      expect(a[i].tMonoNs, b[i].tMonoNs);
    }
    expect([for (final s in a) s.value], isNot(equals([for (final s in c) s.value])));
  });

  test('vision frames are deterministic per timestamp', () {
    final w1 = MockWorld(scenario: Scenarios.valgus, clock: FakeClock())..startSet(0);
    final w2 = MockWorld(scenario: Scenarios.valgus, clock: FakeClock())..startSet(0);
    final f1 = MockVisionPipeline(world: w1).frameAt(2500000000);
    final f2 = MockVisionPipeline(world: w2).frameAt(2500000000);
    for (var i = 0; i < 17; i++) {
      expect(f1.keypoints[i].x, f2.keypoints[i].x);
      expect(f1.keypoints[i].y, f2.keypoints[i].y);
    }
  });

  test('honours capabilities: dropped channels are never emitted', () {
    final src = sensor(Scenarios.clean, channels: {Channels.accelX, Channels.accelZ});
    final chans = {for (final s in src.generateSet(durationS: 2).samples) s.channel};
    expect(chans, {Channels.accelX, Channels.accelZ});
    expect(src.capabilities.measuresVelocity, isFalse);
  });

  test('~100 Hz, battery drains, racked dwell only after the last rep', () {
    final src = sensor(Scenarios.clean, sync: MockTimeSync.calibrated());
    final gen = src.generateSet();
    final vel = gen.samples.where((s) => s.channel == Channels.barVelZ).toList();
    final dt = (vel[1].tMonoNs - vel[0].tMonoNs) / 1e6;
    expect(dt, closeTo(10, 1e-6));
    final racked = gen.statuses.where((s) => s.$2.restingDwell).map((s) => s.$1).toList();
    final repsEndNs = secondsToNs(src.world.timeline.repsEndS);
    expect(racked, isNotEmpty);
    expect(racked.first, greaterThanOrEqualTo(repsEndNs));
    final battery = gen.statuses.map((s) => s.$2.batteryPct!).toList();
    expect(battery.last, lessThan(battery.first));
  });

  test('scripted mean concentric velocity is exact in the noise-free timeline', () {
    final tl = ScenarioTimeline(Scenarios.fatigue);
    // integrate the noise-free velocity over each concentric phase
    final perRep = <int, (double, double)>{};
    for (var t = 0.0; t < tl.repsEndS; t += 0.0005) {
      final m = tl.at(t);
      if (m.phase == MotionPhase.concentric) {
        final (s, n) = perRep[m.rep] ?? (0.0, 0.0);
        perRep[m.rep] = (s + m.velocity, n + 1);
      }
    }
    for (var i = 0; i < Scenarios.fatigue.reps.length; i++) {
      final (s, n) = perRep[i]!;
      expect(s / n, closeTo(Scenarios.fatigue.reps[i].mpv, 0.002));
    }
  });

  test('mock pose geometry: 2D joint angle == scripted flexion, valgus narrows the knees', () {
    for (final ex in Exercise.values) {
      final r = readPose(MockBody.pose(ex, 90, 90), ex, 0.3);
      expect(r.flexion, closeTo(90, 0.01), reason: ex.name);
    }
    final clean = readPose(MockBody.pose(Exercise.squat, 95, 95), Exercise.squat, 0.3);
    final valgus = readPose(MockBody.pose(Exercise.squat, 95, 95, valgus: 1), Exercise.squat, 0.3);
    expect(clean.kneeAnkleRatio, closeTo(1.0, 0.05));
    expect(valgus.kneeAnkleRatio, lessThan(0.6));
    expect(valgus.flexion, closeTo(95, 0.01)); // valgus does not distort depth
  });

  test('framing score: fails at first, passes after stepping back (Phase 3)', () {
    final w = MockWorld(scenario: Scenarios.clean, clock: FakeClock())..startPositioning(0);
    final v = MockVisionPipeline(world: w);
    expect(v.frameAt(secondsToNs(1)).framingScore, lessThan(0.6));
    expect(v.frameAt(secondsToNs(5)).framingScore, greaterThan(0.9));
  });

  test('sensor clock runs ahead until calibrated; TapTimeSync recovers the offset', () async {
    final src = sensor(Scenarios.clean);
    final s = src.sampleAt(1000000000, index: 0).first;
    expect(s.tMonoNs - 1000000000, 37 * 1000000); // uncalibrated: 37 ms ahead
    final sync = TapTimeSync();
    await sync.calibrate([
      for (final (p, jitterMs) in [(1000000000, 0), (2000000000, 4), (3000000000, -3)])
        TapEvent(phoneMonoNs: p, sensorNs: p + (37 + jitterMs) * 1000000),
    ]);
    expect(sync.offset.inMilliseconds, 37);
    expect(sync.jitter!.inMilliseconds, 7);
    expect(() => TapTimeSync().calibrate([]), throwsStateError);
  });

  test('haptic commands are recorded (and forwarded)', () async {
    final got = <HapticCommand>[];
    final src = MockSensorSource(world: MockWorld(scenario: Scenarios.clean, clock: FakeClock()), onHaptic: got.add);
    await src.sendCommand(HapticCommand.faultDoubleBuzz);
    expect(src.sentCommands, [HapticCommand.faultDoubleBuzz]);
    expect(got, [HapticCommand.faultDoubleBuzz]);
  });
}
