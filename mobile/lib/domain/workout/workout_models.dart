/// Closed vocabularies shared with the backend (backend/app/models/constants.py).
/// `wire` values are the JSON strings in contracts/set_summary.v1.schema.json.
library;

enum Exercise {
  squat('squat', 'Squat'),
  deadlift('deadlift', 'Deadlift'),
  benchPress('bench_press', 'Bench Press'),
  pushUp('push_up', 'Push-Up');

  const Exercise(this.wire, this.displayName);
  final String wire;
  final String displayName;

  static Exercise fromWire(String s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => throw FormatException('unknown exercise "$s"'));
}

enum Goal {
  /// ROLE_BRIEFING: Max Strength = 20 % velocity-loss cap, Hypertrophy = 30 %.
  maxStrength('max_strength', 'Max Strength', 20.0),
  hypertrophy('hypertrophy', 'Hypertrophy', 30.0);

  const Goal(this.wire, this.displayName, this.vlCapPct);
  final String wire;
  final String displayName;
  final double vlCapPct;

  static Goal fromWire(String s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => throw FormatException('unknown goal "$s"'));
}

enum FaultFlag {
  valgus('valgus'),
  lumbarFlexion('lumbar_flexion'),
  incompleteRom('incomplete_rom');

  const FaultFlag(this.wire);
  final String wire;

  static FaultFlag fromWire(String s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => throw FormatException('unknown fault "$s"'));
}

enum DataSource {
  simulated('simulated'),
  real('real');

  const DataSource(this.wire);
  final String wire;

  static DataSource fromWire(String s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => throw FormatException('unknown data_source "$s"'));
}

enum VelocitySource {
  imu('imu'),
  vision('vision'),
  fused('fused');

  const VelocitySource(this.wire);
  final String wire;

  static VelocitySource fromWire(String s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => throw FormatException('unknown velocity_source "$s"'));
}

/// The 7-phase demo flow (ROLE_BRIEFING, kept).
enum WorkoutPhase {
  pair, // 1 Launch / pair (Device Connect)
  exerciseGoal, // 2 Exercise + goal selection
  positioning, // 3 Camera positioning, TTS "Step back 2 meters"
  calibration, // 4 3-tap time sync calibration
  liveSet, // 5 Live set: HUD + skeleton, fault/fatigue cues
  setConclusion, // 6 Racked / zero-motion dwell > 2.0 s -> sleep haptic, vision 10 FPS, persist
  restAudit, // 7 Rest audit: set summary + coaching card
}
