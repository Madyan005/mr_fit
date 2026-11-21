import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/bindings.dart';
import '../../app/providers.dart';
import '../../app/session/demo_runner.dart';
import '../../app/session/session_controller.dart';
import '../../data/api/api_models.dart';
import '../../data/local/app_database.dart';
import '../../data/sensors/mock/scenarios.dart';
import '../../domain/contracts/set_summary_payload.dart';
import '../../domain/workout/workout_models.dart';
import '../coach/coach_screen.dart';
import '../logs/log_format.dart';
import '../widgets/simulated_banner.dart';
import 'skeleton_painter.dart';

const _phaseTitles = {
  WorkoutPhase.pair: '1 · Connect device',
  WorkoutPhase.exerciseGoal: '2 · Exercise and goal',
  WorkoutPhase.positioning: '3 · Camera position',
  WorkoutPhase.calibration: '4 · Calibration',
  WorkoutPhase.liveSet: '5 · Live set',
  WorkoutPhase.setConclusion: '6 · Set complete',
  WorkoutPhase.restAudit: '7 · Rest and review',
};

/// Default rest when no coaching card is available yet (rules table, D-036).
int defaultRestSeconds(Goal goal) => goal == Goal.maxStrength ? 180 : 90;

final _localSetProvider = StreamProvider.autoDispose.family<LocalSet?, String>(
    (ref, id) => ref.watch(setRepositoryProvider).watchLocalSet(id));

/// Full-screen 7-phase training session (spec "new screens mapped to the 7 phases").
class SessionPage extends ConsumerStatefulWidget {
  const SessionPage({super.key, this.demo = false});

  /// Played by the scripted demo runner (step 6, Mock mode) instead of by hand.
  final bool demo;

  @override
  ConsumerState<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends ConsumerState<SessionPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.demo
        ? ref.read(demoRunnerProvider.notifier).run()
        : ref.read(sessionControllerProvider.notifier).start());
  }

  Future<void> _end() async {
    ref.read(demoRunnerProvider.notifier).stop();
    await ref.read(sessionControllerProvider.notifier).endSession();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(sessionControllerProvider);
    final phase = st.phase;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _end();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(phase == null ? 'Session' : _phaseTitles[phase]!),
          leading: IconButton(key: const Key('session.end'), tooltip: 'End session', icon: const Icon(Icons.close), onPressed: _end),
        ),
        body: Column(children: [
          const SimulatedBanner(),
          if (widget.demo) const DemoNarrationBar(),
          if (st.error case final e?)
            MaterialBanner(
              key: const Key('session.error'),
              content: Text(e),
              actions: [TextButton(onPressed: _end, child: const Text('Close'))],
            ),
          Expanded(
            child: switch (phase) {
              null => const Center(child: CircularProgressIndicator()),
              WorkoutPhase.pair => _PairView(st: st),
              WorkoutPhase.exerciseGoal => const _SetupView(),
              WorkoutPhase.positioning => _PositioningView(st: st),
              WorkoutPhase.calibration => _CalibrationView(st: st),
              WorkoutPhase.liveSet => _LiveView(st: st),
              WorkoutPhase.setConclusion => const Center(child: Text('Set complete. Saving…')),
              WorkoutPhase.restAudit => _RestView(st: st, onEnd: _end),
            },
          ),
        ]),
      ),
    );
  }
}

SessionController _ctl(WidgetRef ref) => ref.read(sessionControllerProvider.notifier);

String _mmss(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// What the scripted demo is showing, its clock, and a way to take over by hand.
class DemoNarrationBar extends ConsumerStatefulWidget {
  const DemoNarrationBar({super.key});

  @override
  ConsumerState<DemoNarrationBar> createState() => _DemoNarrationBarState();
}

class _DemoNarrationBarState extends ConsumerState<DemoNarrationBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(demoRunnerProvider);
    final t = Theme.of(context).textTheme;
    final started = d.startedNs;
    final elapsed = started == null
        ? Duration.zero
        : Duration(microseconds: (ref.read(monotonicClockProvider).nowNs() - started) ~/ 1000);
    final status = d.running
        ? 'Scripted demo · ${_mmss(elapsed)} of about ${_mmss(d.planned)}'
        : d.finished
            ? 'Scripted demo · finished'
            : 'Scripted demo · stopped';
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(children: [
          const Icon(Icons.record_voice_over_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(status, key: const Key('demo.status'), style: t.labelMedium),
              Text(d.narration ?? 'Starting…', key: const Key('demo.narration'), style: t.bodyMedium),
            ]),
          ),
          if (d.running)
            TextButton(
              key: const Key('demo.stop'),
              onPressed: () => ref.read(demoRunnerProvider.notifier).stop(),
              child: const Text('Take over'),
            ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ 1

class _PairView extends ConsumerWidget {
  const _PairView({required this.st});
  final SessionState st;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = st.device;
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: Icon(d.connected ? Icons.sensors : Icons.sensors_off, size: 36),
          title: Text(d.connected ? d.sourceLabel : 'Connecting…', key: const Key('pair.label')),
          subtitle: Text([
            if (d.batteryPct != null) 'Battery ${d.batteryPct!.round()} %',
            if (d.rssi != null) 'Signal ${d.rssi} dBm',
          ].join(' · ')),
        ),
      ),
      const SizedBox(height: 8),
      Text('The sensor streams motion at about 100 Hz. Keep it on the bar or your wrist.', style: t.bodyMedium),
      const SizedBox(height: 24),
      FilledButton(
        key: const Key('pair.continue'),
        onPressed: d.connected ? _ctl(ref).confirmDevice : null,
        child: const Text('Continue'),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ 2

class _SetupView extends ConsumerStatefulWidget {
  const _SetupView();

  @override
  ConsumerState<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends ConsumerState<_SetupView> {
  Exercise _exercise = Exercise.squat;
  Goal _goal = Goal.maxStrength;
  final _load = TextEditingController();

  @override
  void dispose() {
    _load.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mock = ref.watch(sourceModeProvider) == SourceMode.mock;
    final t = Theme.of(context).textTheme;
    if (mock) {
      final current = ref.watch(scenarioProvider);
      final s = Scenarios.byId(current);
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text('Simulated set', style: t.titleMedium),
        Text('In mock mode the motion comes from a demo scenario, which fixes the exercise, goal and load.',
            style: t.bodySmall),
        const SizedBox(height: 8),
        RadioGroup<ScenarioId>(
          groupValue: current,
          onChanged: (id) {
            if (id != null) _ctl(ref).selectScenario(id);
          },
          child: Column(children: [
            for (final sc in Scenarios.all)
              RadioListTile<ScenarioId>(key: Key('setup.scenario.${sc.id.name}'), value: sc.id, title: Text(sc.label)),
          ]),
        ),
        const Divider(),
        Text('${s.exercise.displayName} · ${s.goal.displayName} (velocity-loss cap ${fmtNum(s.goal.vlCapPct)} %) · '
            '${fmtNum(s.loadKg)} kg', key: const Key('setup.summary')),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('setup.continue'),
          onPressed: () => _ctl(ref).chooseSetup(exercise: s.exercise, goal: s.goal, loadKg: s.loadKg),
          child: const Text('Continue'),
        ),
      ]);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      DropdownButtonFormField<Exercise>(
        initialValue: _exercise,
        decoration: const InputDecoration(labelText: 'Exercise'),
        items: [for (final e in Exercise.values) DropdownMenuItem(value: e, child: Text(e.displayName))],
        onChanged: (e) => setState(() => _exercise = e ?? _exercise),
      ),
      const SizedBox(height: 12),
      SegmentedButton<Goal>(
        segments: [for (final g in Goal.values) ButtonSegment(value: g, label: Text(g.displayName))],
        selected: {_goal},
        onSelectionChanged: (s) => setState(() => _goal = s.first),
      ),
      TextField(
        controller: _load,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        decoration: const InputDecoration(labelText: 'Load (kg, optional)'),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () => _ctl(ref).chooseSetup(
            exercise: _exercise, goal: _goal, loadKg: double.tryParse(_load.text.replaceAll(',', '.'))),
        child: const Text('Continue'),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ 3

class _PositioningView extends ConsumerWidget {
  const _PositioningView({required this.st});
  final SessionState st;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final score = st.framingScore ?? 0;
    final ok = score >= SessionController.framingThreshold;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Step back about 2 m so your whole body is in view.', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      SkeletonView(pose: st.pose, simulated: ref.watch(anyMockActiveProvider)),
      const SizedBox(height: 12),
      Text(ok ? 'Good framing. Hold still…' : 'Framing ${(score * 100).round()} %', key: const Key('positioning.score')),
      LinearProgressIndicator(value: score.clamp(0.0, 1.0)),
    ]);
  }
}

// ------------------------------------------------------------------ 4

class _CalibrationView extends ConsumerWidget {
  const _CalibrationView({required this.st});
  final SessionState st;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Tap the bar three times, pressing the button with each tap.', style: t.titleMedium),
      Text('This lines up the sensor clock with the phone clock.', style: t.bodySmall),
      const SizedBox(height: 24),
      Center(
        child: SizedBox.square(
          dimension: 160,
          child: FilledButton(
            key: const Key('calibration.tap'),
            style: FilledButton.styleFrom(shape: const CircleBorder()),
            onPressed: _ctl(ref).tap,
            child: const Text('TAP', style: TextStyle(fontSize: 28)),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < SessionController.tapsNeeded; i++)
          Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(i < st.tapsMatched ? Icons.check_circle : Icons.radio_button_unchecked, size: 28),
          ),
      ]),
      Text('Felt by the sensor: ${st.tapsMatched} of ${SessionController.tapsNeeded}',
          key: const Key('calibration.count'), textAlign: TextAlign.center),
      if (st.calibrationNote case final n?)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(n, textAlign: TextAlign.center)),
    ]);
  }
}

// ------------------------------------------------------------------ 5

class _LiveView extends ConsumerWidget {
  const _LiveView({required this.st});
  final SessionState st;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final live = st.live;
    if (!st.setRunning) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        if (st.calibrationNote case final n?) Text('Calibrated. $n', style: t.bodySmall),
        const SizedBox(height: 8),
        Text('Set ${st.setIndex}: ${st.exercise?.displayName ?? ''} · ${st.goal?.displayName ?? ''}'
            '${st.loadKg == null ? '' : ' · ${fmtNum(st.loadKg!)} kg'}', style: t.titleMedium),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('live.start'),
          onPressed: _ctl(ref).startSet,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start set'),
        ),
      ]);
    }
    final vl = live?.velocityLossPct;
    final cap = live?.vlCapPct ?? st.goal?.vlCapPct ?? 20;
    final over = vl != null && vl >= cap;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${live?.repCount ?? 0}', key: const Key('hud.reps'), style: t.displayLarge),
        const SizedBox(width: 8),
        Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('reps', style: t.titleMedium)),
        const Spacer(),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(live?.liveConcentricMps == null ? '–' : '${live!.liveConcentricMps!.toStringAsFixed(2)} m/s',
              key: const Key('hud.velocity'), style: t.headlineMedium),
          Text(live?.lastRepMps == null ? 'last rep –' : 'last rep ${live!.lastRepMps!.toStringAsFixed(2)} m/s',
              style: t.bodySmall),
        ]),
      ]),
      const SizedBox(height: 4),
      Text('Velocity loss ${vl == null ? '–' : '${fmtNum(vl)} %'} of ${fmtNum(cap)} % cap', key: const Key('hud.vl')),
      LinearProgressIndicator(
        value: (live?.vlBarFraction ?? 0).clamp(0.0, 1.0),
        minHeight: 10,
        color: over ? Colors.redAccent : null,
      ),
      if (live?.velocityConfidenceLow ?? false)
        Text('Velocity from camera only: treat it as approximate.', style: t.bodySmall),
      const SizedBox(height: 8),
      SkeletonView(pose: st.pose, color: live?.skeletonColor, simulated: ref.watch(anyMockActiveProvider), height: 300),
      if (live?.lastPeakDepthDeg != null)
        Text('Last depth ${fmtNum(live!.lastPeakDepthDeg!)}°', style: t.bodyMedium),
      if (st.cue case final c?)
        Card(
          key: const Key('hud.cue'),
          color: Theme.of(context).colorScheme.tertiaryContainer,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(c, style: t.titleMedium)),
        ),
      const SizedBox(height: 8),
      Text('The set ends by itself when the bar is racked or still for 2 s.', style: t.bodySmall),
    ]);
  }
}

// ------------------------------------------------------------------ 7

class _RestView extends ConsumerStatefulWidget {
  const _RestView({required this.st, required this.onEnd});
  final SessionState st;
  final VoidCallback onEnd;

  @override
  ConsumerState<_RestView> createState() => _RestViewState();
}

class _RestViewState extends ConsumerState<_RestView> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final p = st.summary;
    final t = Theme.of(context).textTheme;
    if (p == null) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Text('This set was not saved.'),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: widget.onEnd, child: const Text('End session')),
      ]);
    }
    final local = ref.watch(_localSetProvider(p.setId)).value;
    CoachingCard? card;
    final cj = local?.coachingJson;
    if (cj != null) {
      try {
        card = CoachingCard.fromJson(jsonDecode(cj));
      } on FormatException {
        card = null;
      }
    }
    final restS = card?.nextSet.restSeconds ?? defaultRestSeconds(p.goal);
    final started = st.restStartedNs;
    final elapsedS = started == null ? 0 : ((ref.read(monotonicClockProvider).nowNs() - started) / 1e9).floor();
    final left = (restS - elapsedS).clamp(0, restS);

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Rest ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', key: const Key('rest.timer'), style: t.displaySmall),
      Text(left == 0 ? 'Ready for the next set.' : 'Recommended rest $restS s', style: t.bodySmall),
      const SizedBox(height: 12),
      _SummaryCard(p: p),
      const SizedBox(height: 8),
      Text(switch (local?.syncState) {
        SyncState.synced => 'Uploaded.',
        SyncState.failed => 'Upload failed: ${local?.lastError ?? ''}',
        _ => 'Saved on this phone; uploading…',
      }, key: const Key('rest.sync'), style: t.bodySmall),
      const SizedBox(height: 8),
      if (card != null)
        Card(child: Padding(padding: const EdgeInsets.all(12), child: CoachingCardView(card: card)))
      else
        const Card(
          key: Key('rest.waitingcard'),
          child: ListTile(leading: Icon(Icons.hourglass_top), title: Text('Coaching card will appear when the server answers.')),
        ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: OutlinedButton(key: const Key('rest.end'), onPressed: widget.onEnd, child: const Text('End session'))),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(key: const Key('rest.next'), onPressed: _ctl(ref).nextSet, child: const Text('Next set')),
        ),
      ]),
    ]);
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.p});
  final SetSummaryPayload p;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final faults = [
      if (p.faultCounts.valgus > 0) 'valgus ×${p.faultCounts.valgus}',
      if (p.faultCounts.lumbarFlexion > 0) 'lumbar flexion ×${p.faultCounts.lumbarFlexion}',
      if (p.faultCounts.incompleteRom > 0) 'incomplete ROM ×${p.faultCounts.incompleteRom}',
    ];
    final vl = p.velocityLossPct;
    return Card(
      key: const Key('rest.summary'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p.exercise.displayName} · set ${p.setIndex}', style: t.titleMedium),
          Text('${p.repsCompleted} reps${p.loadKg == null ? '' : ' · ${fmtNum(p.loadKg!)} kg'} · ${p.goal.displayName}'),
          if (vl != null)
            Text('Velocity loss ${fmtNum(vl)} % (cap ${fmtNum(p.vlCapPct)} %)${p.vlCapExceeded ? ' · cap exceeded' : ''}'),
          if (p.mpvInitial != null && p.mpvFinal != null)
            Text('Mean velocity ${p.mpvInitial!.toStringAsFixed(2)} → ${p.mpvFinal!.toStringAsFixed(2)} m/s'),
          if (p.mqsScore != null) Text('Movement quality ${fmtNum(p.mqsScore!)}'),
          Text(faults.isEmpty ? 'No faults detected' : 'Faults: ${faults.join(', ')}'),
          if (p.dataSource == DataSource.simulated) Text('SIMULATED data', style: t.labelSmall),
        ]),
      ),
    );
  }
}
