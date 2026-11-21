import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sensors/mock/scenarios.dart';
import '../../domain/workout/workout_models.dart';
import '../bindings.dart';
import 'session_controller.dart';

/// Segment budgets of the scripted demo (D-017, D-083). The runner acts at segment
/// deadlines counted from the start of the demo; phases the simulation drives by itself
/// (positioning, the live set, the conclusion) take their simulated time and the runner
/// waits out the rest of the segment at its next step. A late phase still gets
/// [minRest] and pushes the rest of the demo back. Default total: 30 + 20 + 50 + 3 × 90 + 30 s = 6:40.
final class DemoTimeline {
  const DemoTimeline({
    this.pair = const Duration(seconds: 30),
    this.goal = const Duration(seconds: 20),
    this.positioningAndCalibration = const Duration(seconds: 50),
    this.setBlock = const Duration(seconds: 90),
    this.closing = const Duration(seconds: 30),
    this.setupHold = const Duration(seconds: 5),
    this.armedHold = const Duration(seconds: 3),
    this.minRest = const Duration(seconds: 10),
    this.tapInterval = const Duration(milliseconds: 1500),
    this.maxTaps = 12,
    this.phaseTimeout = const Duration(minutes: 2),
  });

  final Duration pair;
  final Duration goal;
  final Duration positioningAndCalibration;

  /// Set setup (sets 2 and 3) + armed + live + conclusion + rest.
  final Duration setBlock;
  final Duration closing;
  final Duration setupHold;
  final Duration armedHold;

  /// The rest view is shown at least this long, even after a long set.
  final Duration minRest;
  final Duration tapInterval;
  final int maxTaps;

  /// A phase the simulation should reach by itself; the demo stops if it does not.
  final Duration phaseTimeout;

  Duration get planned => pair + goal + positioningAndCalibration + setBlock * demoSets.length + closing;
}

/// The three demo sets, in order.
const demoSets = [ScenarioId.clean, ScenarioId.fatigue, ScenarioId.valgus];

final class DemoMark {
  const DemoMark(this.label, this.at);
  final String label;

  /// Since the start of the demo.
  final Duration at;

  @override
  String toString() => '$label@${at.inMilliseconds / 1000}s';
}

final class DemoState {
  const DemoState({
    this.running = false,
    this.finished = false,
    this.narration,
    this.setNumber = 0,
    this.startedNs,
    this.planned = Duration.zero,
    this.stoppedReason,
    this.marks = const [],
  });

  final bool running;
  final bool finished;
  final String? narration;
  final int setNumber;
  final int? startedNs;
  final Duration planned;
  final String? stoppedReason;
  final List<DemoMark> marks;

  DemoState copyWith({bool? running, bool? finished, String? narration, int? setNumber, String? stoppedReason,
          List<DemoMark>? marks}) =>
      DemoState(
        running: running ?? this.running,
        finished: finished ?? this.finished,
        narration: narration ?? this.narration,
        setNumber: setNumber ?? this.setNumber,
        startedNs: startedNs,
        planned: planned,
        stoppedReason: stoppedReason ?? this.stoppedReason,
        marks: marks ?? this.marks,
      );
}

final demoTimelineProvider = Provider<DemoTimeline>((ref) => const DemoTimeline());

final demoRunnerProvider = NotifierProvider<DemoRunner, DemoState>(DemoRunner.new);

final class _Stopped implements Exception {
  const _Stopped();
}

/// Plays the 7-phase session with the three demo sets (step 6). Mock mode only. It uses
/// the same controller calls as the buttons, so the screens show exactly what a user sees;
/// it only adds the on-screen narration.
class DemoRunner extends Notifier<DemoState> {
  Completer<void>? _wake;
  Timer? _timer;
  bool Function(SessionState)? _until;
  bool _sessionStarted = false;

  @override
  DemoState build() {
    ref.listen(sessionControllerProvider, (_, s) => _onSession(s));
    ref.onDispose(() => _cancelWait());
    return const DemoState();
  }

  int get _now => ref.read(monotonicClockProvider).nowNs();
  SessionState get _session => ref.read(sessionControllerProvider);

  /// The user ended the session, or the session hit an error: stop driving it.
  void _onSession(SessionState s) {
    if (!state.running) return;
    if (_sessionStarted && s.phase == null) return stop('The session was ended.');
    if (s.error case final e?) return stop(e);
    final until = _until;
    if (until != null && until(s)) _release();
  }

  /// Stops the script; the session stays open for manual use (or is already ended).
  void stop([String reason = 'Demo stopped. The session continues by hand.']) {
    if (!state.running) return;
    state = state.copyWith(running: false, stoppedReason: reason, narration: reason);
    debugPrint('demo: stopped: $reason');
    _cancelWait();
  }

  Future<void> run() async {
    if (state.running) return;
    final tl = ref.read(demoTimelineProvider);
    final ctl = ref.read(sessionControllerProvider.notifier);
    if (ref.read(sourceModeProvider) != SourceMode.mock) {
      state = const DemoState(stoppedReason: 'The scripted demo runs in Mock mode only.');
      return;
    }
    if (_session.phase != null) {
      state = const DemoState(stoppedReason: 'A session is already running.');
      return;
    }
    final t0 = _now;
    _sessionStarted = false;
    state = DemoState(running: true, startedNs: t0, planned: tl.planned);
    int at(Duration d) => t0 + d.inMicroseconds * 1000;

    try {
      // 1 · connect
      _narrate('pair', 'Phase 1 · Connect. The phone pairs with the motion sensor and shows its battery and '
          'signal. In this demo the sensor is simulated.');
      await ctl.start();
      _sessionStarted = true;
      await _waitFor((s) => s.device.connected, tl.phaseTimeout, 'the sensor to connect');
      await _sleepUntil(at(tl.pair));
      ctl.confirmDevice();

      // 2 · exercise and goal
      await ctl.selectScenario(demoSets.first);
      _narrate('goal', 'Phase 2 · Exercise and goal. ${_setLine(1)} The goal sets the velocity-loss cap '
          'at which the set should stop.');
      await _sleepUntil(at(tl.pair + tl.goal));
      _chooseCurrent(ctl);

      // 3 · positioning (the simulated athlete steps back by itself)
      _narrate('positioning', 'Phase 3 · Camera position. The pose model checks that the whole body is in '
          'view; the simulated athlete starts too close and steps back.');
      await _waitFor((s) => s.phase == WorkoutPhase.calibration || s.calibrated, tl.phaseTimeout, 'framing');

      // 4 · calibration: taps timed to finish at the end of the segment
      _narrate('calibration', 'Phase 4 · Calibration. Three taps on the bar: the phone and the sensor both '
          'register each tap, which lines up their clocks.');
      final tapsTake = tl.tapInterval * (SessionController.tapsNeeded + 1);
      final setsStart = tl.pair + tl.goal + tl.positioningAndCalibration;
      await _sleepUntil(at(setsStart - tapsTake));
      await _calibrate(ctl, tl);
      _narrate('calibrated', 'Calibrated: ${_session.calibrationNote ?? ''}.');

      // 5-7 · three sets
      for (var i = 0; i < demoSets.length; i++) {
        final n = i + 1;
        state = state.copyWith(setNumber: n);
        if (i > 0) {
          await ctl.selectScenario(demoSets[i]);
          _narrate('set$n.setup', 'Set $n · Phase 2 again. ${_setLine(n)} Positioning and calibration are kept.');
          await _sleep(tl.setupHold);
          _chooseCurrent(ctl);
        }
        await _waitFor((s) => s.phase == WorkoutPhase.liveSet && !s.setRunning, tl.phaseTimeout, 'set $n to arm');
        _narrate('set$n.live', 'Set $n · Phase 5 · Live set. ${_liveLine(demoSets[i])}');
        await _sleep(tl.armedHold);
        await ctl.startSet();
        await _waitFor((s) => s.phase == WorkoutPhase.setConclusion || s.phase == WorkoutPhase.restAudit,
            tl.phaseTimeout, 'set $n to end');
        _narrate('set$n.conclusion', 'Set $n · Phase 6 · Set complete. The bar is racked; the summary is '
            'saved on the phone first.');
        await _waitFor((s) => s.phase == WorkoutPhase.restAudit, tl.phaseTimeout, 'set $n to be saved');
        _narrate('set$n.rest', 'Set $n · Phase 7 · Rest and review. The set is uploaded and the coach answers '
            'with a card; its next-set advice comes from the rules table. The demo shortens the rest.');
        await _sleepUntil(max(at(setsStart + tl.setBlock * n), _now + tl.minRest.inMicroseconds * 1000));
        if (n < demoSets.length) await ctl.nextSet();
      }

      _narrate('closing', 'Closing. Three sets were measured, saved and coached. The Coach tab lists their '
          'cards; Stats and the heatmap include them.');
      await _sleep(tl.closing);
      _narrate('done', 'Demo complete. Tap End session when you are done.');
      if (ref.mounted) state = state.copyWith(running: false, finished: true);
    } on _Stopped {
      // stop() already set the reason
    } on TimeoutException catch (e) {
      if (ref.mounted) stop('Demo stopped: ${e.message}.');
    }
  }

  String _setLine(int n) {
    final s = Scenarios.byId(demoSets[n - 1]);
    return 'Set $n: ${s.exercise.displayName}, ${s.goal.displayName}, ${_num(s.loadKg)} kg, '
        'velocity-loss cap ${_num(s.goal.vlCapPct)} %.';
  }

  static String _liveLine(ScenarioId id) => switch (id) {
        ScenarioId.clean => 'Reps and bar speed are counted live. A clean set stays well under the cap.',
        ScenarioId.fatigue => 'The bar slows rep by rep. When velocity loss passes the cap the phone '
            'buzzes long and says to rack the bar.',
        ScenarioId.valgus => 'The knees cave in on some reps: the skeleton turns red and the cue '
            '"Knees out" is spoken, at most once per rep.',
      };

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  void _chooseCurrent(SessionController ctl) {
    final s = ctl.currentScenario;
    ctl.chooseSetup(exercise: s.exercise, goal: s.goal, loadKg: s.loadKg);
  }

  /// Taps until the sensor has felt three; a tap it missed is repeated.
  Future<void> _calibrate(SessionController ctl, DemoTimeline tl) async {
    for (var i = 0; i < tl.maxTaps && !_session.calibrated; i++) {
      if (_session.tapsSent < SessionController.tapsNeeded) ctl.tap();
      await _sleep(tl.tapInterval);
    }
    if (!_session.calibrated) throw TimeoutException('the sensor did not feel the calibration taps');
  }

  void _narrate(String label, String text) {
    if (!state.running) throw const _Stopped();
    final at = Duration(microseconds: (_now - state.startedNs!) ~/ 1000);
    state = state.copyWith(narration: text, marks: [...state.marks, DemoMark(label, at)]);
    debugPrint('demo: ${at.inMilliseconds / 1000}s $label');
  }

  // ---------------------------------------------------------------- waiting

  Future<void> _sleep(Duration d) => _wait(d, null, null);

  Future<void> _sleepUntil(int ns) => _wait(Duration(microseconds: max(0, (ns - _now) ~/ 1000)), null, null);

  Future<void> _waitFor(bool Function(SessionState) until, Duration timeout, String what) =>
      _wait(timeout, until, what);

  /// One wait at a time: a plain sleep, or a session condition with a timeout.
  Future<void> _wait(Duration d, bool Function(SessionState)? until, String? what) {
    if (!state.running) throw const _Stopped();
    if (until != null && until(_session)) return Future.value();
    final c = _wake = Completer<void>();
    _until = until;
    _timer = Timer(d, () {
      if (until == null) {
        _release();
      } else {
        _release(TimeoutException('timed out waiting for $what', d));
      }
    });
    return c.future;
  }

  void _release([Object? error]) {
    final c = _wake;
    _timer?.cancel();
    _timer = null;
    _wake = null;
    _until = null;
    if (c == null || c.isCompleted) return;
    if (error == null) {
      c.complete();
    } else {
      c.completeError(error);
    }
  }

  void _cancelWait() => _release(const _Stopped());
}
