import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/clock.dart';
import '../../data/sensors/mock/scenarios.dart';
import '../../domain/contracts/set_summary_payload.dart';
import '../../domain/metrics/live_metrics.dart';
import '../../domain/metrics/metrics_engine.dart';
import '../../domain/metrics/metrics_session.dart';
import '../../domain/sensors/channels.dart';
import '../../domain/sensors/sensor_models.dart';
import '../../domain/sensors/sensor_source.dart';
import '../../domain/session/session_ports.dart';
import '../../domain/timesync/time_sync.dart';
import '../../domain/vision/vision_models.dart';
import '../../domain/workout/workout_models.dart';
import '../bindings.dart';
import 'session_providers.dart';

const _keep = Object();

/// Everything the session screens show. `phase == null`: no session running.
final class SessionState {
  const SessionState({
    this.phase,
    this.device = DeviceStatus.disconnected,
    this.error,
    this.exercise,
    this.goal,
    this.loadKg,
    this.setIndex = 1,
    this.framingScore,
    this.framed = false,
    this.tapsSent = 0,
    this.tapsMatched = 0,
    this.calibrated = false,
    this.calibrationNote,
    this.setRunning = false,
    this.live,
    this.pose,
    this.cue,
    this.summary,
    this.restStartedNs,
  });

  final WorkoutPhase? phase;
  final DeviceStatus device;
  final String? error;
  final Exercise? exercise;
  final Goal? goal;
  final double? loadKg;
  final int setIndex;
  final double? framingScore;
  final bool framed;
  final int tapsSent;
  final int tapsMatched;
  final bool calibrated;
  final String? calibrationNote;
  final bool setRunning;
  final LiveMetrics? live;
  final List<Keypoint>? pose;

  /// Last spoken coaching cue during the set (also shown on the HUD).
  final String? cue;
  final SetSummaryPayload? summary;
  final int? restStartedNs;

  SessionState copyWith({
    Object? phase = _keep,
    DeviceStatus? device,
    Object? error = _keep,
    Object? exercise = _keep,
    Object? goal = _keep,
    Object? loadKg = _keep,
    int? setIndex,
    Object? framingScore = _keep,
    bool? framed,
    int? tapsSent,
    int? tapsMatched,
    bool? calibrated,
    Object? calibrationNote = _keep,
    bool? setRunning,
    Object? live = _keep,
    Object? pose = _keep,
    Object? cue = _keep,
    Object? summary = _keep,
    Object? restStartedNs = _keep,
  }) =>
      SessionState(
        phase: identical(phase, _keep) ? this.phase : phase as WorkoutPhase?,
        device: device ?? this.device,
        error: identical(error, _keep) ? this.error : error as String?,
        exercise: identical(exercise, _keep) ? this.exercise : exercise as Exercise?,
        goal: identical(goal, _keep) ? this.goal : goal as Goal?,
        loadKg: identical(loadKg, _keep) ? this.loadKg : loadKg as double?,
        setIndex: setIndex ?? this.setIndex,
        framingScore: identical(framingScore, _keep) ? this.framingScore : framingScore as double?,
        framed: framed ?? this.framed,
        tapsSent: tapsSent ?? this.tapsSent,
        tapsMatched: tapsMatched ?? this.tapsMatched,
        calibrated: calibrated ?? this.calibrated,
        calibrationNote: identical(calibrationNote, _keep) ? this.calibrationNote : calibrationNote as String?,
        setRunning: setRunning ?? this.setRunning,
        live: identical(live, _keep) ? this.live : live as LiveMetrics?,
        pose: identical(pose, _keep) ? this.pose : pose as List<Keypoint>?,
        cue: identical(cue, _keep) ? this.cue : cue as String?,
        summary: identical(summary, _keep) ? this.summary : summary as SetSummaryPayload?,
        restStartedNs: identical(restStartedNs, _keep) ? this.restStartedNs : restStartedNs as int?,
      );
}

/// Spoken cue for a rep's faults (most serious first).
String faultCue(Set<FaultFlag> faults) {
  if (faults.contains(FaultFlag.lumbarFlexion)) return 'Keep your back neutral. Chest up.';
  if (faults.contains(FaultFlag.valgus)) return 'Knees out.';
  return 'Go a little deeper.';
}

final sessionControllerProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// The 7-phase session (D-017, D-074): pair → exercise/goal → positioning → calibration →
/// live set → set conclusion → rest audit, then the next set or the end.
class SessionController extends Notifier<SessionState> {
  static const framingThreshold = 0.8;
  static const framedHold = Duration(seconds: 1);
  static const tapSpikeAboveG = 15.0; // m/s² on accel_z
  static const tapMatchWindow = Duration(milliseconds: 600);
  static const tapsNeeded = 3;
  static const sampleFlushInterval = Duration(milliseconds: 50);

  SensorSource? _sensor;
  StreamSubscription<DeviceStatus>? _statusSub;
  StreamSubscription<SensorSample>? _sampleSub;
  StreamSubscription<LiveMetrics>? _liveSub;
  StreamSubscription<EngineEvent>? _eventSub;
  Timer? _frameTimer;
  Timer? _flushTimer;
  LiveMetricsSession? _metrics;
  final List<SensorSample> _pendingSamples = [];
  final List<VisionFrameResult> _pendingFrames = [];
  int? _framedSinceNs;
  final List<int> _unmatchedTaps = [];
  final List<TapEvent> _taps = [];
  int? _lastSpikeNs;
  DateTime? _startedAt;
  int _faultCuedRep = 0;
  bool _concluding = false;

  /// A sensor (re)attach in progress; [startSet] waits for it.
  Future<void>? _attaching;

  // Captured at start(): `ref` may not be used inside onDispose.
  CueOutput? _cue;
  KeepAlive? _keepAlive;
  SimulationHooks? _hooks;

  @override
  SessionState build() {
    ref.onDispose(() => unawaited(_teardown()));
    return const SessionState();
  }

  MonotonicClock get _clock => ref.read(monotonicClockProvider);
  bool get _mock => ref.read(sourceModeProvider) == SourceMode.mock;

  // ---------------------------------------------------------------- 1 pair

  Future<void> start() async {
    if (state.phase != null) return;
    state = const SessionState(phase: WorkoutPhase.pair);
    _cue = ref.read(cueOutputProvider);
    _keepAlive = ref.read(keepAliveProvider);
    _hooks = ref.read(simulationHooksProvider);
    unawaited(_keepAlive!.start(simulated: ref.read(sensorSimulatedProvider)));
    await (_attaching = _attachSensor());
  }

  Future<void> _attachSensor() async {
    await _detachSensor();
    try {
      final s = ref.read(sensorSourceProvider);
      _sensor = s;
      _statusSub = s.status().listen((d) {
        if (!ref.mounted) return;
        state = state.copyWith(device: d);
        _metrics?.updateStatus(d, _clock.nowNs());
      });
      _sampleSub = s.samples().listen(_onSample);
      await s.connect();
    } on UnimplementedError catch (e) {
      if (ref.mounted) {
        state = state.copyWith(error: 'No real sensor is available yet (${e.message}). Switch to Mock in Settings.');
      }
    }
  }

  // Subscriptions are cancelled without awaiting: these broadcast streams cancel at
  // once, and awaiting the returned root-zone future stalls fake-time tests.
  Future<void> _detachSensor() async {
    unawaited(_statusSub?.cancel());
    unawaited(_sampleSub?.cancel());
    _statusSub = null;
    _sampleSub = null;
    final s = _sensor;
    _sensor = null;
    if (s != null) {
      try {
        await s.disconnect();
      } on UnimplementedError {
        // REAL SLOT stub
      } on StateError {
        // already disposed by its provider
      }
    }
  }

  void confirmDevice() {
    if (state.phase != WorkoutPhase.pair || !state.device.connected) return;
    state = state.copyWith(phase: WorkoutPhase.exerciseGoal, error: null);
  }

  // ---------------------------------------------------------------- 2 exercise / goal

  /// Mock mode: the simulated motion comes from a scenario, so the scenario fixes the
  /// exercise, goal and load of the set. Changing it rebuilds the mock sensor.
  Future<void> selectScenario(ScenarioId id) {
    if (ref.read(scenarioProvider) == id) return _attaching ?? Future.value();
    return _attaching = () async {
      await _detachSensor(); // disconnect the old mock before its provider disposes it
      ref.read(scenarioProvider.notifier).select(id);
      _hooks = ref.read(simulationHooksProvider); // the mock world was rebuilt
      await _attachSensor();
    }();
  }

  Scenario get currentScenario => Scenarios.byId(ref.read(scenarioProvider));

  void chooseSetup({required Exercise exercise, required Goal goal, double? loadKg}) {
    if (state.phase != WorkoutPhase.exerciseGoal) return;
    state = state.copyWith(exercise: exercise, goal: goal, loadKg: loadKg, error: null);
    if (!state.framed) {
      _enterPositioning();
    } else if (!state.calibrated) {
      _enterCalibration();
    } else {
      state = state.copyWith(phase: WorkoutPhase.liveSet);
    }
  }

  // ---------------------------------------------------------------- 3 positioning

  void _enterPositioning() {
    state = state.copyWith(phase: WorkoutPhase.positioning, framingScore: null);
    _framedSinceNs = null;
    _hooks?.startPositioning(_clock.nowNs());
    _restartFrameTicker();
    _say('Step back about two meters so your whole body is in view.');
  }

  void _onFrame(VisionFrameResult r) {
    if (!ref.mounted || state.phase == null) return;
    state = state.copyWith(pose: r.personInFrame ? r.keypoints : null, framingScore: r.framingScore);
    if (state.phase == WorkoutPhase.positioning) {
      final ok = (r.framingScore ?? 0) >= framingThreshold;
      if (!ok) {
        _framedSinceNs = null;
      } else if ((_framedSinceNs ??= r.tMonoNs) + framedHold.inMicroseconds * 1000 <= r.tMonoNs) {
        state = state.copyWith(framed: true);
        _say('Good. Hold that position.');
        _enterCalibration();
      }
    }
    if (state.setRunning) _pendingFrames.add(r);
  }

  void _restartFrameTicker() {
    _frameTimer?.cancel();
    final vision = ref.read(visionPipelineProvider);
    final period = Duration(microseconds: (1e6 / vision.targetFps).round());
    _frameTimer = Timer.periodic(period, (_) {
      try {
        vision.analyze(CameraFrame(tMonoNs: _clock.nowNs(), width: 0, height: 0)).listen(_onFrame);
      } on UnimplementedError catch (e) {
        _frameTimer?.cancel();
        state = state.copyWith(error: 'No pose model is available yet (${e.message}).');
      }
    });
  }

  // ---------------------------------------------------------------- 4 calibration

  void _enterCalibration() {
    _unmatchedTaps.clear();
    _taps.clear();
    _lastSpikeNs = null;
    state = state.copyWith(phase: WorkoutPhase.calibration, tapsSent: 0, tapsMatched: 0, calibrationNote: null);
    _say('Tap the bar three times.');
  }

  /// The athlete taps the bar; the phone registers the tap now. A real sensor feels the
  /// same tap by itself; the mock sensor is told about it ([TapSimulator]).
  void tap() {
    if (state.phase != WorkoutPhase.calibration || state.calibrated) return;
    final now = _clock.nowNs();
    _unmatchedTaps.add(now);
    if (_sensor case final TapSimulator sim) sim.simulateTap(now);
    state = state.copyWith(tapsSent: state.tapsSent + 1, calibrationNote: null);
  }

  void _matchTap(SensorSample s) {
    final windowNs = tapMatchWindow.inMicroseconds * 1000;
    while (_unmatchedTaps.isNotEmpty && _clock.nowNs() - _unmatchedTaps.first > windowNs) {
      _unmatchedTaps.removeAt(0);
      state = state.copyWith(tapsSent: state.tapsSent - 1, calibrationNote: 'The sensor did not feel that tap. Tap again.');
    }
    if (s.channel != Channels.accelZ || s.value < 9.81 + tapSpikeAboveG || _unmatchedTaps.isEmpty) return;
    final last = _lastSpikeNs;
    if (last != null && s.tMonoNs - last < 150 * 1000000) return; // same tap, next sample
    _lastSpikeNs = s.tMonoNs;
    _taps.add(TapEvent(phoneMonoNs: _unmatchedTaps.removeAt(0), sensorNs: s.tMonoNs));
    state = state.copyWith(tapsMatched: _taps.length);
    if (_taps.length >= tapsNeeded) unawaited(_finishCalibration());
  }

  Future<void> _finishCalibration() async {
    final ts = ref.read(timeSyncProvider);
    final taps = List.of(_taps);
    _taps.clear();
    try {
      await ts.calibrate(taps);
      if (!ref.mounted) return;
      final jitter = ts.jitter;
      state = state.copyWith(
        calibrated: true,
        phase: WorkoutPhase.liveSet,
        calibrationNote: 'Clock offset ${ts.offset.inMilliseconds} ms'
            '${jitter == null ? '' : ', spread ${jitter.inMilliseconds} ms'}',
      );
      _say('Calibrated. Start the set when you are ready.');
    } on StateError catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(tapsSent: 0, tapsMatched: 0, calibrationNote: '${e.message}. Tap three times again.');
    }
  }

  // ---------------------------------------------------------------- 5 live set

  Future<void> startSet() async {
    await _attaching;
    final sensor = _sensor;
    final exercise = state.exercise, goal = state.goal;
    if (state.phase != WorkoutPhase.liveSet || state.setRunning || sensor == null || exercise == null || goal == null) {
      return;
    }
    final vision = ref.read(visionPipelineProvider);
    final ctx = SetContext(
      setId: const Uuid().v4(),
      exercise: exercise,
      goal: goal,
      setIndex: state.setIndex,
      dataSource: ref.read(dataSourceProvider),
      deviceLabels: [sensor.capabilities.sourceName, vision.capabilities.pipelineName],
      loadKg: state.loadKg,
    );
    final m = await ref.read(metricsSessionFactoryProvider)(ctx, sensor.capabilities);
    if (!ref.mounted) {
      m.dispose();
      return;
    }
    _metrics = m;
    _liveSub = m.live.listen((l) {
      if (ref.mounted) state = state.copyWith(live: l);
    });
    _eventSub = m.events.listen(_onEvent);
    _pendingSamples.clear();
    _pendingFrames.clear();
    _faultCuedRep = 0;
    _startedAt = DateTime.now().toUtc();
    vision.setTargetFps(30);
    _restartFrameTicker();
    _hooks?.startSet(_clock.nowNs());
    _flushTimer = Timer.periodic(sampleFlushInterval, (_) => _flush());
    state = state.copyWith(setRunning: true, live: null, cue: null, summary: null, error: null);
    _haptic(HapticCommand.wake);
  }

  void _onSample(SensorSample s) {
    if (!ref.mounted) return;
    if (state.setRunning) {
      _pendingSamples.add(s);
    } else if (state.phase == WorkoutPhase.calibration && !state.calibrated) {
      _matchTap(s);
    }
  }

  /// Samples first, then the frames up to the last sample time (same order as the
  /// engine's golden tests).
  void _flush() {
    final m = _metrics;
    if (m == null || _pendingSamples.isEmpty) return;
    final batch = List.of(_pendingSamples);
    _pendingSamples.clear();
    m.addSamples(batch);
    final upTo = batch.last.tMonoNs;
    final frames = _pendingFrames.where((f) => f.tMonoNs <= upTo).toList();
    _pendingFrames.removeWhere((f) => f.tMonoNs <= upTo);
    if (frames.isNotEmpty) m.addFrames(frames);
  }

  void _onEvent(EngineEvent e) {
    if (!ref.mounted) return;
    switch (e) {
      case FaultDetected(:final repIndex, :final faults) when repIndex > _faultCuedRep:
        _faultCuedRep = repIndex;
        _haptic(HapticCommand.faultDoubleBuzz);
        final text = faultCue(faults);
        state = state.copyWith(cue: text);
        _say(text);
      case FatigueCapReached(:final capPct):
        _haptic(HapticCommand.fatigueLongBuzz);
        final text = 'Velocity loss passed your ${capPct.round()} percent limit. Rack the bar.';
        state = state.copyWith(cue: text);
        _say(text);
      case SetConcluded():
        unawaited(_conclude());
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- 6 conclusion → 7 rest audit

  Future<void> _conclude() async {
    if (_concluding || !state.setRunning) return;
    _concluding = true;
    state = state.copyWith(phase: WorkoutPhase.setConclusion);
    _haptic(HapticCommand.interSetSleep);
    ref.read(visionPipelineProvider).setTargetFps(10);
    _restartFrameTicker();
    _flushTimer?.cancel();
    _flushTimer = null;
    _flush();
    final m = _metrics!;
    try {
      final p = await m.finish(startedAt: _startedAt, endedAt: DateTime.now().toUtc());
      await ref.read(completedSetSinkProvider)(p);
      if (!ref.mounted) return;
      state = state.copyWith(
          summary: p, phase: WorkoutPhase.restAudit, setRunning: false, restStartedNs: _clock.nowNs());
      _say('Set saved. ${p.repsCompleted} reps.');
    } on Object catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(phase: WorkoutPhase.restAudit, setRunning: false, error: 'The set could not be saved: $e');
    } finally {
      await _stopMetrics();
      _concluding = false;
    }
  }

  Future<void> _stopMetrics() async {
    unawaited(_liveSub?.cancel());
    unawaited(_eventSub?.cancel());
    _liveSub = null;
    _eventSub = null;
    _metrics?.dispose();
    _metrics = null;
  }

  /// Back to Phase 2 for the next set. Mock mode moves on to the next demo scenario
  /// (clean → fatigue → valgus); positioning and calibration are kept.
  Future<void> nextSet() async {
    if (state.phase != WorkoutPhase.restAudit) return;
    state = state.copyWith(
        phase: WorkoutPhase.exerciseGoal, setIndex: state.setIndex + 1, live: null, cue: null, summary: null,
        restStartedNs: null, error: null);
    if (_mock) {
      final ids = ScenarioId.values;
      await selectScenario(ids[(ids.indexOf(ref.read(scenarioProvider)) + 1) % ids.length]);
    }
  }

  Future<void> endSession() async {
    await _teardown();
    if (ref.mounted) state = const SessionState();
  }

  Future<void> _teardown() async {
    _frameTimer?.cancel();
    _flushTimer?.cancel();
    _frameTimer = null;
    _flushTimer = null;
    await _stopMetrics();
    await _detachSensor();
    _hooks?.reset();
    await _cue?.stopSpeaking();
    await _keepAlive?.stop();
  }

  // ---------------------------------------------------------------- cues

  void _say(String text) => unawaited(_cue?.speak(text));

  /// Phone vibration and, if the sensor has a motor, the sensor too.
  void _haptic(HapticCommand c) {
    unawaited(_cue?.haptic(c));
    final s = _sensor;
    if (s != null) unawaited(s.sendCommand(c));
  }
}
