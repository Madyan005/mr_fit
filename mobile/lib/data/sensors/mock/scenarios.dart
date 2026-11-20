/// SIMULATED demo scenarios. Per-rep targets mirror contracts/fixtures/set_summary_*.json
/// so the MetricsEngine golden tests can check that the engine recovers them.
library;

import '../../../domain/workout/workout_models.dart';

enum ScenarioId { clean, fatigue, valgus }

final class RepScript {
  const RepScript({required this.mpv, required this.depthDeg, this.faults = const {}});

  /// Target mean concentric velocity (m/s).
  final double mpv;

  /// Peak flexion of the exercise's primary joint (deg).
  final double depthDeg;
  final Set<FaultFlag> faults;
}

final class Scenario {
  const Scenario({
    required this.id,
    required this.label,
    required this.exercise,
    required this.goal,
    required this.loadKg,
    required this.reps,
    this.setIndex = 1,
    this.seed = 42,
    this.velocityNoiseStd = 0.01,
    this.accelNoiseStd = 0.05,
    this.keypointNoiseStd = 0.002,
    this.asymmetryDeg = 2.0,
    this.fatigueDriftPerRep = 0.0,
    this.eccentricS = 1.0,
    this.bottomPauseS = 0.15,
    this.topPauseS = 0.8,
    this.preRollS = 1.0,
    this.rackDelayS = 0.5,
    this.batteryStartPct = 87.0,
    this.batteryDrainPctPerS = 0.01,
    this.sensorClockOffsetMs = 37,
  });

  final ScenarioId id;
  final String label;
  final Exercise exercise;
  final Goal goal;
  final double loadKg;
  final List<RepScript> reps;
  final int setIndex;
  final int seed;
  final double velocityNoiseStd;
  final double accelNoiseStd;
  final double keypointNoiseStd;
  final double asymmetryDeg;

  /// Extra multiplicative velocity loss per rep on top of the scripted values (fault injection knob).
  final double fatigueDriftPerRep;
  final double eccentricS;
  final double bottomPauseS;
  final double topPauseS;
  final double preRollS;

  /// Delay after the last rep before the mock reports `restingDwell` (bar racked).
  final double rackDelayS;
  final double batteryStartPct;
  final double batteryDrainPctPerS;

  /// The mock sensor's clock runs this far ahead of the phone clock (Phase 4 recovers it).
  final int sensorClockOffsetMs;

  Scenario copyWith({int? seed, double? velocityNoiseStd, double? fatigueDriftPerRep, List<RepScript>? reps,
          Exercise? exercise, int? setIndex}) =>
      Scenario(
        id: id, label: label, exercise: exercise ?? this.exercise, goal: goal, loadKg: loadKg,
        reps: reps ?? this.reps, setIndex: setIndex ?? this.setIndex, seed: seed ?? this.seed,
        velocityNoiseStd: velocityNoiseStd ?? this.velocityNoiseStd, accelNoiseStd: accelNoiseStd,
        keypointNoiseStd: keypointNoiseStd, asymmetryDeg: asymmetryDeg,
        fatigueDriftPerRep: fatigueDriftPerRep ?? this.fatigueDriftPerRep, eccentricS: eccentricS,
        bottomPauseS: bottomPauseS, topPauseS: topPauseS, preRollS: preRollS, rackDelayS: rackDelayS,
        batteryStartPct: batteryStartPct, batteryDrainPctPerS: batteryDrainPctPerS,
        sensorClockOffsetMs: sensorClockOffsetMs,
      );

  double mpvOf(int repIdx0) {
    var v = reps[repIdx0].mpv;
    for (var i = 0; i < repIdx0; i++) {
      v *= 1 - fatigueDriftPerRep;
    }
    return v;
  }
}

abstract final class Scenarios {
  static const clean = Scenario(
    id: ScenarioId.clean,
    label: 'Clean set (squat, hypertrophy)',
    exercise: Exercise.squat,
    goal: Goal.hypertrophy,
    loadKg: 80,
    setIndex: 1,
    reps: [
      RepScript(mpv: 0.62, depthDeg: 96.0),
      RepScript(mpv: 0.60, depthDeg: 95.5),
      RepScript(mpv: 0.59, depthDeg: 95.0),
      RepScript(mpv: 0.57, depthDeg: 94.5),
      RepScript(mpv: 0.55, depthDeg: 94.0),
    ],
  );

  static const fatigue = Scenario(
    id: ScenarioId.fatigue,
    label: 'Fatigue set (bench, max strength) - crosses the 20 % cap',
    exercise: Exercise.benchPress,
    goal: Goal.maxStrength,
    loadKg: 60,
    setIndex: 2,
    reps: [
      RepScript(mpv: 0.45, depthDeg: 88.0),
      RepScript(mpv: 0.43, depthDeg: 87.5),
      RepScript(mpv: 0.41, depthDeg: 87.0),
      RepScript(mpv: 0.38, depthDeg: 86.0),
      RepScript(mpv: 0.36, depthDeg: 84.0),
      RepScript(mpv: 0.34, depthDeg: 76.0, faults: {FaultFlag.incompleteRom}),
    ],
  );

  static const valgus = Scenario(
    id: ScenarioId.valgus,
    label: 'Valgus fault set (squat, max strength)',
    exercise: Exercise.squat,
    goal: Goal.maxStrength,
    loadKg: 100,
    setIndex: 3,
    reps: [
      RepScript(mpv: 0.50, depthDeg: 93.0),
      RepScript(mpv: 0.49, depthDeg: 92.0),
      RepScript(mpv: 0.47, depthDeg: 92.5, faults: {FaultFlag.valgus}),
      RepScript(mpv: 0.46, depthDeg: 91.0, faults: {FaultFlag.valgus}),
    ],
  );

  static const all = [clean, fatigue, valgus];

  static Scenario byId(ScenarioId id) => all.firstWhere((s) => s.id == id);
}
