/// SIMULATED kinematics shared by the sensor and vision mocks: given seconds since set
/// start, where is the bar, how fast is it moving, how deep is the joint, which rep is it?
///
/// Velocity per phase is a half-sine, so a concentric phase lasting T with range R has
/// mean velocity exactly R / T = the scripted MPV.
library;

import 'dart:math' as math;

import '../../../domain/workout/workout_models.dart';
import 'mock_body.dart';
import 'scenarios.dart';

enum MotionPhase { preRoll, eccentric, bottomPause, concentric, topPause, racked }

final class _Seg {
  const _Seg(this.rep, this.phase, this.start, this.dur, this.rom);
  final int rep; // 0-based, -1 outside reps
  final MotionPhase phase;
  final double start;
  final double dur;
  final double rom; // meters for this rep
  double get end => start + dur;
}

final class MotionState {
  const MotionState({
    required this.t,
    required this.rep,
    required this.phase,
    required this.downM,
    required this.velocity,
    required this.accel,
    required this.romM,
  });

  final double t;
  final int rep;
  final MotionPhase phase;

  /// Distance below lockout (m), 0..romM.
  final double downM;

  /// Vertical velocity, + = up (m/s).
  final double velocity;
  final double accel;
  final double romM;

  double get depthFraction => romM <= 0 ? 0 : (downM / romM).clamp(0.0, 1.0);
}

class ScenarioTimeline {
  ScenarioTimeline(this.scenario) {
    final s = scenario;
    final bottomStart = s.exercise == Exercise.deadlift; // bar starts on the floor
    var t = s.preRollS;
    for (var i = 0; i < s.reps.length; i++) {
      final rom = MockBody.romMeters(s.exercise, s.reps[i].depthDeg);
      final con = rom / s.mpvOf(i);
      if (bottomStart) {
        _segs.add(_Seg(i, MotionPhase.concentric, t, con, rom));
        t += con;
        _segs.add(_Seg(i, MotionPhase.topPause, t, s.topPauseS, rom));
        t += s.topPauseS;
        _segs.add(_Seg(i, MotionPhase.eccentric, t, s.eccentricS, rom));
        t += s.eccentricS;
        _segs.add(_Seg(i, MotionPhase.bottomPause, t, s.bottomPauseS, rom));
        t += s.bottomPauseS;
      } else {
        _segs.add(_Seg(i, MotionPhase.eccentric, t, s.eccentricS, rom));
        t += s.eccentricS;
        _segs.add(_Seg(i, MotionPhase.bottomPause, t, s.bottomPauseS, rom));
        t += s.bottomPauseS;
        _segs.add(_Seg(i, MotionPhase.concentric, t, con, rom));
        t += con;
        _segs.add(_Seg(i, MotionPhase.topPause, t, s.topPauseS, rom));
        t += s.topPauseS;
      }
    }
    repsEndS = t;
  }

  final Scenario scenario;
  final List<_Seg> _segs = [];
  late final double repsEndS;

  bool get startsAtBottom => scenario.exercise == Exercise.deadlift;
  double get rackedFromS => repsEndS + scenario.rackDelayS;

  /// Scripted flexion (deg) for the current state (same on both sides before asymmetry).
  double flexionAt(MotionState m) {
    if (m.rep < 0) {
      // Deadlift: the bar rests on the floor before the first and after the last rep.
      if (!startsAtBottom) return 0;
      return m.phase == MotionPhase.preRoll ? scenario.reps.first.depthDeg : scenario.reps.last.depthDeg;
    }
    return MockBody.flexionForDisplacement(scenario.exercise, m.downM, scenario.reps[m.rep].depthDeg + 5);
  }

  MotionState at(double t) {
    if (t < scenario.preRollS || _segs.isEmpty) {
      final rom = _segs.isEmpty ? 0.0 : _segs.first.rom;
      return MotionState(t: t, rep: -1, phase: MotionPhase.preRoll, downM: startsAtBottom ? rom : 0,
          velocity: 0, accel: 0, romM: rom);
    }
    if (t >= repsEndS) {
      final rom = _segs.last.rom;
      return MotionState(t: t, rep: -1, phase: MotionPhase.racked, downM: startsAtBottom ? rom : 0,
          velocity: 0, accel: 0, romM: rom);
    }
    final seg = _segs.lastWhere((s) => s.start <= t);
    final tau = t - seg.start;
    final w = math.pi / seg.dur;
    switch (seg.phase) {
      case MotionPhase.concentric:
        final a = math.pi * seg.rom / (2 * seg.dur);
        final up = a / w * (1 - math.cos(w * tau));
        return MotionState(t: t, rep: seg.rep, phase: seg.phase, downM: seg.rom - up,
            velocity: a * math.sin(w * tau), accel: a * w * math.cos(w * tau), romM: seg.rom);
      case MotionPhase.eccentric:
        final a = math.pi * seg.rom / (2 * seg.dur);
        final down = a / w * (1 - math.cos(w * tau));
        return MotionState(t: t, rep: seg.rep, phase: seg.phase, downM: down,
            velocity: -a * math.sin(w * tau), accel: -a * w * math.cos(w * tau), romM: seg.rom);
      case MotionPhase.bottomPause:
        return MotionState(t: t, rep: seg.rep, phase: seg.phase, downM: seg.rom, velocity: 0, accel: 0, romM: seg.rom);
      case MotionPhase.topPause:
      case MotionPhase.preRoll:
      case MotionPhase.racked:
        return MotionState(t: t, rep: seg.rep, phase: seg.phase, downM: 0, velocity: 0, accel: 0, romM: seg.rom);
    }
  }
}
