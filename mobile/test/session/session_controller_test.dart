import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/app/providers.dart';
import 'package:mr_fit/app/session/session_controller.dart';
import 'package:mr_fit/data/sensors/mock/scenarios.dart';
import 'package:mr_fit/domain/contracts/set_summary_payload.dart';
import 'package:mr_fit/domain/sensors/sensor_models.dart';
import 'package:mr_fit/domain/workout/workout_models.dart';

import '../support/session_fakes.dart';

void main() {
  late RecordingCues cues;
  late RecordingKeepAlive keep;
  late List<SetSummaryPayload> saved;

  setUp(() {
    cues = RecordingCues();
    keep = RecordingKeepAlive();
    saved = [];
  });

  ProviderContainer containerFor(FakeAsync fa, {SourceMode mode = SourceMode.mock, bool quietSensor = false}) {
    final clock = FakeAsyncClock(fa);
    return ProviderContainer(
        retry: noAutoRetry,
        overrides: sessionOverrides(
            clock: clock, cues: cues, keepAlive: keep, saved: saved, mode: mode,
            sensor: quietSensor ? () => QuietSensor(clock) : null));
  }

  /// Phases 1-4 for the current scenario; leaves the session armed in Phase 5.
  void throughCalibration(FakeAsync fa, ProviderContainer c) {
    final ctl = c.read(sessionControllerProvider.notifier);
    SessionState st() => c.read(sessionControllerProvider);
    ctl.start();
    fa.elapse(const Duration(milliseconds: 200));
    expect(st().phase, WorkoutPhase.pair);
    expect(st().device.connected, isTrue);
    ctl.confirmDevice();
    expect(st().phase, WorkoutPhase.exerciseGoal);
    final s = ctl.currentScenario;
    ctl.chooseSetup(exercise: s.exercise, goal: s.goal, loadKg: s.loadKg);
    expect(st().phase, WorkoutPhase.positioning);

    fa.elapse(const Duration(seconds: 2)); // the simulated athlete is still too close
    expect(st().phase, WorkoutPhase.positioning);
    expect(st().framingScore, lessThan(SessionController.framingThreshold));
    fa.elapse(const Duration(seconds: 4)); // stepped back and held for 1 s
    expect(st().phase, WorkoutPhase.calibration);
    expect(st().framed, isTrue);

    for (var i = 0; i < 3; i++) {
      ctl.tap();
      fa.elapse(const Duration(milliseconds: 400));
    }
    expect(st().calibrated, isTrue);
    expect(st().phase, WorkoutPhase.liveSet);
    expect(st().setRunning, isFalse, reason: 'armed, waiting for "Start set"');
  }

  void runSet(FakeAsync fa, ProviderContainer c) {
    c.read(sessionControllerProvider.notifier).startSet();
    fa.flushMicrotasks();
    expect(c.read(sessionControllerProvider).setRunning, isTrue);
    for (var i = 0; i < 90 && c.read(sessionControllerProvider).phase != WorkoutPhase.restAudit; i++) {
      fa.elapse(const Duration(milliseconds: 500));
    }
    expect(c.read(sessionControllerProvider).phase, WorkoutPhase.restAudit);
  }

  test('the three demo sets run through all 7 phases in mock mode', () {
    fakeAsync((fa) {
      final c = containerFor(fa);
      final ctl = c.read(sessionControllerProvider.notifier);
      SessionState st() => c.read(sessionControllerProvider);

      throughCalibration(fa, c);
      expect(keep.running, isTrue);
      expect(keep.simulated, isTrue);
      expect(cues.spoken, containsAll(['Step back about two meters so your whole body is in view.', 'Tap the bar three times.']));

      // Set 1: clean squat.
      runSet(fa, c);
      expect(saved, hasLength(1));
      expect(saved[0].exercise, Exercise.squat);
      expect(saved[0].repsCompleted, Scenarios.clean.reps.length);
      expect(saved[0].dataSource, DataSource.simulated);
      expect(saved[0].setIndex, 1);
      expect(st().summary, same(saved[0]));
      expect(cues.haptics, contains(HapticCommand.interSetSleep));
      expect(st().live!.repCount, Scenarios.clean.reps.length);

      // Set 2: the next demo scenario (fatigue, bench) — positioning and calibration are kept.
      ctl.nextSet();
      fa.elapse(const Duration(milliseconds: 100)); // the mock sensor is swapped for the next scenario
      expect(st().phase, WorkoutPhase.exerciseGoal);
      expect(ctl.currentScenario.id, ScenarioId.fatigue);
      final f = ctl.currentScenario;
      ctl.chooseSetup(exercise: f.exercise, goal: f.goal, loadKg: f.loadKg);
      expect(st().phase, WorkoutPhase.liveSet);
      runSet(fa, c);
      expect(saved[1].exercise, Exercise.benchPress);
      expect(saved[1].setIndex, 2);
      expect(saved[1].vlCapExceeded, isTrue);
      expect(cues.haptics, contains(HapticCommand.fatigueLongBuzz));
      expect(cues.spoken.any((t) => t.contains('Rack the bar')), isTrue);

      // Set 3: valgus fault.
      ctl.nextSet();
      fa.elapse(const Duration(milliseconds: 100));
      final v = ctl.currentScenario;
      expect(v.id, ScenarioId.valgus);
      ctl.chooseSetup(exercise: v.exercise, goal: v.goal, loadKg: v.loadKg);
      runSet(fa, c);
      expect(saved[2].faultCounts.valgus, greaterThan(0));
      expect(cues.haptics, contains(HapticCommand.faultDoubleBuzz));
      expect(cues.spoken, contains('Knees out.'));
      expect(cues.haptics.where((h) => h == HapticCommand.faultDoubleBuzz).length,
          lessThanOrEqualTo(saved[2].repsCompleted), reason: 'at most one fault cue per rep');

      ctl.endSession();
      fa.flushMicrotasks();
      expect(st().phase, isNull);
      expect(keep.running, isFalse);
      c.dispose();
    });
  });

  test('tap calibration measures the mock sensor clock lead (37 ms) with TapTimeSync', () {
    fakeAsync((fa) {
      final c = containerFor(fa);
      throughCalibration(fa, c);
      final offsetMs = c.read(timeSyncProvider).offset.inMilliseconds;
      // The spike lands on the first 100 Hz sample after the tap: 37..47 ms.
      expect(offsetMs, inInclusiveRange(37, 47));
      expect(c.read(sessionControllerProvider).calibrationNote, startsWith('Clock offset $offsetMs ms'));
      c.read(sessionControllerProvider.notifier).endSession();
      fa.flushMicrotasks();
      c.dispose();
    });
  });

  test('a tap the sensor never feels is dropped with a message', () {
    fakeAsync((fa) {
      final c = containerFor(fa, quietSensor: true);
      final ctl = c.read(sessionControllerProvider.notifier);
      ctl.start();
      fa.elapse(const Duration(milliseconds: 200));
      ctl.confirmDevice();
      final s = ctl.currentScenario;
      ctl.chooseSetup(exercise: s.exercise, goal: s.goal);
      fa.elapse(const Duration(seconds: 6));
      expect(c.read(sessionControllerProvider).phase, WorkoutPhase.calibration);
      ctl.tap(); // the quiet sensor never feels it
      expect(c.read(sessionControllerProvider).tapsSent, 1);
      fa.elapse(const Duration(seconds: 1));
      final st = c.read(sessionControllerProvider);
      expect(st.tapsSent, 0);
      expect(st.calibrationNote, 'The sensor did not feel that tap. Tap again.');
      ctl.endSession();
      fa.flushMicrotasks();
      c.dispose();
    });
  });

  test('real mode without hardware: a clear message instead of a crash', () {
    fakeAsync((fa) {
      final c = containerFor(fa, mode: SourceMode.real);
      c.read(sessionControllerProvider.notifier).start();
      fa.flushMicrotasks();
      final st = c.read(sessionControllerProvider);
      expect(st.phase, WorkoutPhase.pair);
      expect(st.device.connected, isFalse);
      expect(st.error, contains('Switch to Mock in Settings'));
      expect(keep.simulated, isFalse);
      c.read(sessionControllerProvider.notifier).endSession();
      fa.flushMicrotasks();
      c.dispose();
    });
  });

  test('fault cue wording, most serious first', () {
    expect(faultCue({FaultFlag.valgus, FaultFlag.lumbarFlexion}), 'Keep your back neutral. Chest up.');
    expect(faultCue({FaultFlag.valgus}), 'Knees out.');
    expect(faultCue({FaultFlag.incompleteRom}), 'Go a little deeper.');
  });
}
