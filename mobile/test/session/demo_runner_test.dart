import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/app/providers.dart';
import 'package:mr_fit/app/session/demo_runner.dart';
import 'package:mr_fit/app/session/session_controller.dart';
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

  Duration markAt(DemoState d, String label) => d.marks.firstWhere((m) => m.label == label).at;

  test('the scripted demo plays the three sets through all 7 phases on the D-017 timeline', () {
    fakeAsync((fa) {
      final c = containerFor(fa);
      const tl = DemoTimeline();
      expect(tl.planned, const Duration(minutes: 6, seconds: 40));
      c.read(demoRunnerProvider.notifier).run();
      final seen = <WorkoutPhase>{};
      c.listen(sessionControllerProvider, (_, s) {
        if (s.phase case final p?) seen.add(p);
      });
      for (var i = 0; i < 9 * 60 && !c.read(demoRunnerProvider).finished; i++) {
        fa.elapse(const Duration(seconds: 1));
      }
      final d = c.read(demoRunnerProvider);
      expect(d.stoppedReason, isNull);
      expect(d.finished, isTrue);
      expect(seen, WorkoutPhase.values.toSet());

      // The three demo sets, in order, with what each one is meant to show.
      expect(saved.map((p) => (p.setIndex, p.exercise)),
          [(1, Exercise.squat), (2, Exercise.benchPress), (3, Exercise.squat)]);
      expect(saved.every((p) => p.dataSource == DataSource.simulated), isTrue);
      expect(saved[0].vlCapExceeded, isFalse);
      expect(saved[1].vlCapExceeded, isTrue);
      expect(saved[2].faultCounts.valgus, greaterThan(0));
      expect(cues.haptics, contains(HapticCommand.fatigueLongBuzz));
      expect(cues.spoken, contains('Knees out.'));

      // Timeline: the runner acts at the segment deadlines.
      expect(markAt(d, 'goal').inMilliseconds, within(distance: 100, from: tl.pair.inMilliseconds));
      expect(markAt(d, 'positioning').inMilliseconds, within(distance: 100, from: (tl.pair + tl.goal).inMilliseconds));
      final calibrated = markAt(d, 'calibrated');
      expect(calibrated, greaterThanOrEqualTo(tl.pair + tl.goal + tl.positioningAndCalibration - tl.tapInterval * 4));
      expect(calibrated, lessThanOrEqualTo(tl.pair + tl.goal + tl.positioningAndCalibration));
      for (final n in [1, 2, 3]) {
        final rest = markAt(d, 'set$n.rest');
        final next = n < 3 ? markAt(d, 'set${n + 1}.setup') : markAt(d, 'closing');
        expect(next - rest, greaterThanOrEqualTo(tl.minRest), reason: 'set $n rest is shown');
      }
      final total = markAt(d, 'done');
      expect(total, greaterThanOrEqualTo(tl.planned));
      expect(total, lessThan(const Duration(minutes: 7, seconds: 30)), reason: 'about 7 minutes');
      printOnFailure('${d.marks}');

      // Left on the last rest view for the presenter; the session is still open.
      expect(c.read(sessionControllerProvider).phase, WorkoutPhase.restAudit);
      c.read(sessionControllerProvider.notifier).endSession();
      fa.flushMicrotasks();
      expect(keep.running, isFalse);
      c.dispose();
    });
  });

  test('ending the session mid-demo stops the script; nothing else happens', () {
    fakeAsync((fa) {
      final c = containerFor(fa);
      c.read(demoRunnerProvider.notifier).run();
      fa.elapse(const Duration(seconds: 40)); // in Phase 2
      expect(c.read(sessionControllerProvider).phase, WorkoutPhase.exerciseGoal);
      c.read(sessionControllerProvider.notifier).endSession();
      fa.flushMicrotasks();
      final d = c.read(demoRunnerProvider);
      expect(d.running, isFalse);
      expect(d.stoppedReason, 'The session was ended.');
      fa.elapse(const Duration(minutes: 3));
      expect(c.read(sessionControllerProvider).phase, isNull, reason: 'the runner did not restart it');
      expect(saved, isEmpty);
      c.dispose();
    });
  });

  test('"Take over" stops the script and leaves the session where it is', () {
    fakeAsync((fa) {
      final c = containerFor(fa);
      c.read(demoRunnerProvider.notifier).run();
      fa.elapse(const Duration(seconds: 10));
      c.read(demoRunnerProvider.notifier).stop();
      fa.elapse(const Duration(seconds: 60));
      expect(c.read(sessionControllerProvider).phase, WorkoutPhase.pair, reason: 'no automatic Continue');
      expect(c.read(demoRunnerProvider).running, isFalse);
      c.read(sessionControllerProvider.notifier).confirmDevice(); // by hand
      expect(c.read(sessionControllerProvider).phase, WorkoutPhase.exerciseGoal);
      c.read(sessionControllerProvider.notifier).endSession();
      fa.flushMicrotasks();
      c.dispose();
    });
  });

  test('real mode: the demo refuses to start', () {
    fakeAsync((fa) {
      final c = containerFor(fa, mode: SourceMode.real);
      c.read(demoRunnerProvider.notifier).run();
      fa.flushMicrotasks();
      expect(c.read(demoRunnerProvider).stoppedReason, contains('Mock mode only'));
      expect(c.read(sessionControllerProvider).phase, isNull);
      c.dispose();
    });
  });

  test('if the sensor never feels the taps, the demo stops with the reason instead of hanging', () {
    fakeAsync((fa) {
      final c = containerFor(fa, quietSensor: true);
      c.read(demoRunnerProvider.notifier).run();
      fa.elapse(const Duration(minutes: 3));
      final d = c.read(demoRunnerProvider);
      expect(d.running, isFalse);
      expect(d.stoppedReason, contains('did not feel the calibration taps'));
      expect(c.read(sessionControllerProvider).phase, WorkoutPhase.calibration, reason: 'left for manual use');
      c.read(sessionControllerProvider.notifier).endSession();
      fa.flushMicrotasks();
      c.dispose();
    });
  });
}
