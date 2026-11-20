// MetricsEngine golden tests: mock scenarios (seeded) -> engine -> payload, compared with
// the scripted targets that mirror contracts/fixtures/set_summary_*.json.
//
// Tolerances were chosen from docs/validation/engine_reference.py (a Python mirror of
// this pipeline) over several seeds. Worst observed: MPV 0.014 m/s, depth 3.5 deg,
// VL 2.6 pts with IMU; vision-only MPV 0.045 m/s. See docs/MQS.md "Validation".
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/core/clock.dart';
import 'package:mr_fit/data/sensors/mock/mock_sensor_source.dart';
import 'package:mr_fit/data/sensors/mock/mock_world.dart';
import 'package:mr_fit/data/sensors/mock/scenarios.dart';
import 'package:mr_fit/data/timesync/mock_time_sync.dart';
import 'package:mr_fit/data/vision/mock/mock_vision_pipeline.dart';
import 'package:mr_fit/domain/contracts/set_summary_payload.dart';
import 'package:mr_fit/domain/metrics/live_metrics.dart';
import 'package:mr_fit/domain/metrics/metrics_engine.dart';
import 'package:mr_fit/domain/metrics/metrics_worker.dart';
import 'package:mr_fit/domain/sensors/channels.dart';
import 'package:mr_fit/domain/sensors/sensor_models.dart';
import 'package:mr_fit/domain/vision/vision_models.dart';
import 'package:mr_fit/domain/workout/workout_models.dart';

const mpvTol = 0.02, depthTol = 4.5, vlTol = 3.0, visionMpvTol = 0.07;

final class Run {
  Run(this.payload, this.events, this.engine);
  final SetSummaryPayload payload;
  final List<EngineEvent> events;
  final MetricsEngine engine;
}

/// Feeds a whole generated set through the engine in ~16 ms batches, in time order.
Run runScenario(Scenario s, {Set<String>? channels, bool withVision = true}) {
  final world = MockWorld(scenario: s, clock: FakeClock());
  final src = MockSensorSource(world: world, channels: channels, timeSync: MockTimeSync.calibrated());
  final gen = src.generateSet(startNs: 0);
  final dur = world.timeline.rackedFromS + 3.0;
  final frames = withVision
      ? MockVisionPipeline(world: world).generateSet(startNs: 0, durationS: dur)
      : const <VisionFrameResult>[];
  final engine = MetricsEngine(
    ctx: SetContext(
      setId: '0b6f7c1e-8a52-4c1d-9a3e-3f1f0a0000ff', exercise: s.exercise, goal: s.goal,
      setIndex: s.setIndex, dataSource: DataSource.simulated,
      deviceLabels: ['MockSensorSource', if (withVision) 'MockVisionPipeline'], loadKg: s.loadKg,
    ),
    capabilities: src.capabilities,
  );
  final events = <EngineEvent>[];
  var si = 0, fi = 0, st = 0;
  for (var t = 0; t <= secondsToNs(dur); t += 16000000) {
    final batch = <SensorSample>[];
    while (si < gen.samples.length && gen.samples[si].tMonoNs <= t) {
      batch.add(gen.samples[si++]);
    }
    engine.addSamples(batch);
    final fb = <VisionFrameResult>[];
    while (fi < frames.length && frames[fi].tMonoNs <= t) {
      fb.add(frames[fi++]);
    }
    engine.addFrames(fb);
    while (st < gen.statuses.length && gen.statuses[st].$1 <= t) {
      engine.updateStatus(gen.statuses[st].$2, gen.statuses[st].$1);
      st++;
    }
    events.addAll(engine.drainEvents());
  }
  final payload = engine.finish(startedAt: DateTime.utc(2026, 11, 20, 10), endedAt: DateTime.utc(2026, 11, 20, 10, 1));
  return Run(payload, events, engine);
}

Map<String, Object?> fixture(String name) =>
    jsonDecode(File('../contracts/fixtures/set_summary_$name.json').readAsStringSync()) as Map<String, Object?>;

void expectMatchesScript(Run r, Scenario s, String fixtureName) {
  final p = r.payload;
  final fx = SetSummaryPayload.fromJson(fixture(fixtureName));
  expect(p.repsCompleted, s.reps.length, reason: 'rep count');
  for (var i = 0; i < s.reps.length; i++) {
    expect(p.perRep[i].meanVelocityMS, closeTo(s.reps[i].mpv, mpvTol), reason: 'rep ${i + 1} MPV');
    expect(p.perRep[i].peakDepthDeg, closeTo(s.reps[i].depthDeg, depthTol), reason: 'rep ${i + 1} depth');
    expect(p.perRep[i].faultFlags.toSet(), s.reps[i].faults, reason: 'rep ${i + 1} faults');
  }
  expect(p.velocityLossPct, closeTo(fx.velocityLossPct!, vlTol));
  expect(p.vlCapExceeded, fx.vlCapExceeded);
  expect(p.faultCounts, fx.faultCounts);
  expect(p.velocitySource, VelocitySource.imu);
  expect(p.symmetryIndex, isNotNull);
  expect(p.symmetryIndex!, lessThan(10));
  // The engine's payload must itself satisfy the contract (same checks as the server).
  expect(SetSummaryPayload.fromJson(jsonDecode(jsonEncode(p.toJson()))).repsCompleted, s.reps.length);
}

void main() {
  test('clean set: 5 reps, no faults, VL under the 30 % cap', () {
    final r = runScenario(Scenarios.clean);
    expectMatchesScript(r, Scenarios.clean, 'clean');
    expect(r.events.whereType<FaultDetected>(), isEmpty);
    expect(r.events.whereType<FatigueCapReached>(), isEmpty);
    expect(r.events.whereType<RepCompleted>().length, 5);
  });

  test('fatigue set: crosses the 20 % cap, incomplete ROM on the last rep', () {
    final r = runScenario(Scenarios.fatigue);
    expectMatchesScript(r, Scenarios.fatigue, 'fatigue');
    final fatigue = r.events.whereType<FatigueCapReached>().toList();
    expect(fatigue, hasLength(1), reason: 'emitted exactly once');
    expect(fatigue.single.velocityLossPct, greaterThanOrEqualTo(20));
    final faults = r.events.whereType<FaultDetected>().toList();
    expect(faults.map((f) => f.repIndex), [6]);
    expect(faults.single.faults, {FaultFlag.incompleteRom});
  });

  test('valgus set: valgus on reps 3 and 4, red skeleton', () {
    final r = runScenario(Scenarios.valgus);
    expectMatchesScript(r, Scenarios.valgus, 'valgus');
    expect(r.events.whereType<FaultDetected>().map((f) => f.repIndex), [3, 4]);
    expect(r.engine.live().skeletonColor, SkeletonColor.red); // last rep had valgus
  });

  test('set conclusion: dwell > 2.0 s after the last rep, exactly once', () {
    for (final s in Scenarios.all) {
      final r = runScenario(s);
      final c = r.events.whereType<SetConcluded>().toList();
      expect(c, hasLength(1), reason: s.label);
      final lastRepEnd = r.events.whereType<RepCompleted>().last.tMonoNs;
      expect(c.single.tMonoNs - lastRepEnd, greaterThan(secondsToNs(2.0)));
      expect(r.engine.live().concluded, isTrue);
    }
  });

  test('MQS: bounded, ordered clean > fatigue and clean > valgus', () {
    final clean = runScenario(Scenarios.clean).payload;
    final fatigue = runScenario(Scenarios.fatigue).payload;
    final valgus = runScenario(Scenarios.valgus).payload;
    for (final p in [clean, fatigue, valgus]) {
      expect(p.mqsScore, inInclusiveRange(0, 100));
      expect(p.mqsBreakdown!.keys.toSet(), {'rom', 'stability', 'tempo', 'velocity', 'symmetry'});
    }
    expect(clean.mqsScore!, greaterThan(fatigue.mqsScore!));
    expect(clean.mqsScore!, greaterThan(valgus.mqsScore!));
    expect(valgus.mqsBreakdown!['stability']!, lessThan(clean.mqsBreakdown!['stability']!));
  });

  test('engine is deterministic: same input -> identical payload', () {
    final a = runScenario(Scenarios.fatigue).payload.toJson();
    final b = runScenario(Scenarios.fatigue).payload.toJson();
    expect(jsonEncode(a), jsonEncode(b));
  });

  group('degrades gracefully', () {
    test('no IMU velocity channel -> vision-derived velocity, flagged', () {
      final imuLess = {Channels.accelX, Channels.accelY, Channels.accelZ, Channels.batteryPct};
      final clean = runScenario(Scenarios.clean, channels: imuLess);
      expect(clean.payload.velocitySource, VelocitySource.vision);
      expect(clean.engine.live().velocityConfidenceLow, isTrue);
      expect(clean.payload.repsCompleted, 5);
      for (var i = 0; i < 5; i++) {
        expect(clean.payload.perRep[i].meanVelocityMS, closeTo(Scenarios.clean.reps[i].mpv, visionMpvTol));
      }
      expect(clean.payload.vlCapExceeded, isFalse);
      // Vision-only velocity loss is too noisy to promise the cap is detected (the Python
      // mirror crossed it in 4 of 6 seeds) - that is exactly why it is flagged low-confidence.
      final fatigue = runScenario(Scenarios.fatigue, channels: imuLess).payload;
      expect(fatigue.repsCompleted, 6);
      expect(fatigue.velocityLossPct, isNotNull);
      expect(fatigue.perRep.last.faultFlags, [FaultFlag.incompleteRom]);
    });

    test('no vision -> velocity metrics only; depth, faults, symmetry are null/empty', () {
      final r = runScenario(Scenarios.valgus, withVision: false);
      final p = r.payload;
      expect(p.repsCompleted, 4);
      expect(p.perRep.every((rep) => rep.peakDepthDeg == null && rep.faultFlags.isEmpty), isTrue);
      expect(p.symmetryIndex, isNull);
      expect(p.mqsBreakdown!['stability'], isNull); // cannot judge stability without pose
      expect(p.mqsBreakdown!['rom'], isNull);
      expect(p.velocityLossPct, isNotNull);
    });

    test('no IMU and no vision -> zero reps, all velocity metrics null, still valid', () {
      final r = runScenario(Scenarios.clean, channels: {Channels.batteryPct}, withVision: false);
      final p = r.payload;
      expect(p.repsCompleted, 0);
      expect(p.mpvInitial, isNull);
      expect(p.velocityLossPct, isNull);
      expect(p.vlCapExceeded, isFalse);
      expect(p.velocitySource, isNull);
    });
  });

  test('other exercises: deadlift (bottom start, lumbar fault) and push-up', () {
    final dl = Scenarios.clean.copyWith(exercise: Exercise.deadlift, reps: const [
      RepScript(mpv: 0.55, depthDeg: 85),
      RepScript(mpv: 0.50, depthDeg: 84),
      RepScript(mpv: 0.45, depthDeg: 85, faults: {FaultFlag.lumbarFlexion}),
    ]);
    final d = runScenario(dl).payload;
    expect(d.repsCompleted, 3);
    expect(d.perRep.map((r) => r.faultFlags.toSet()).toList(), [<FaultFlag>{}, <FaultFlag>{}, {FaultFlag.lumbarFlexion}]);
    for (var i = 0; i < 3; i++) {
      expect(d.perRep[i].meanVelocityMS, closeTo(dl.reps[i].mpv, mpvTol));
    }

    final pu = Scenarios.clean.copyWith(exercise: Exercise.pushUp, reps: const [
      RepScript(mpv: 0.40, depthDeg: 90),
      RepScript(mpv: 0.38, depthDeg: 88),
      RepScript(mpv: 0.36, depthDeg: 70, faults: {FaultFlag.incompleteRom}),
    ]);
    final p = runScenario(pu).payload;
    expect(p.repsCompleted, 3);
    expect(p.perRep.last.faultFlags, [FaultFlag.incompleteRom]);
  });

  test('MetricsWorker runs the engine in an Isolate and returns the same payload', () async {
    final s = Scenarios.clean;
    final world = MockWorld(scenario: s, clock: FakeClock());
    final src = MockSensorSource(world: world, timeSync: MockTimeSync.calibrated());
    final gen = src.generateSet(startNs: 0);
    final frames = MockVisionPipeline(world: world).generateSet(startNs: 0, durationS: world.timeline.rackedFromS + 3);
    final ctx = SetContext(setId: '0b6f7c1e-8a52-4c1d-9a3e-3f1f0a0000ee', exercise: s.exercise, goal: s.goal,
        setIndex: 1, dataSource: DataSource.simulated, deviceLabels: const ['MockSensorSource']);
    final worker = await MetricsWorker.start(ctx, src.capabilities);
    final reps = <RepCompleted>[];
    final sub = worker.events.listen((e) {
      if (e is RepCompleted) reps.add(e);
    });
    // Interleave in time order, in batches (as the app does).
    var fi = 0;
    for (var i = 0; i < gen.samples.length; i += 200) {
      final batch = gen.samples.sublist(i, (i + 200).clamp(0, gen.samples.length));
      worker.addSamples(batch);
      final upTo = batch.last.tMonoNs;
      final fb = <VisionFrameResult>[];
      while (fi < frames.length && frames[fi].tMonoNs <= upTo) {
        fb.add(frames[fi++]);
      }
      worker.addFrames(fb);
    }
    final p = await worker.finish();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(p.repsCompleted, 5);
    expect(reps.length, 5);
    await sub.cancel();
    worker.dispose();
  });
}
