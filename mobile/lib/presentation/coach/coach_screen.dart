import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/api_models.dart';
import '../../data/local/app_database.dart';
import '../../domain/contracts/set_summary_payload.dart';
import '../../domain/workout/workout_models.dart';
import '../logs/log_format.dart';
import 'coach_providers.dart';

const _metricLabels = {
  'velocity_loss_pct': 'Velocity loss',
  'mpv_initial': 'First-rep velocity',
  'mpv_final': 'Last-rep velocity',
  'mqs_score': 'Movement quality',
  'symmetry_index': 'Symmetry index',
  'load_kg': 'Load',
  'reps_completed': 'Reps',
  'vl_cap_pct': 'Velocity-loss cap',
};

String metricLabel(String key) => _metricLabels[key] ?? key.replaceAll('_', ' ');

/// Formats a server-provided metric value with the unit implied by its key.
String metricValue(String key, double v) {
  if (key.endsWith('_pct')) return '${fmtNum(v)} %';
  if (key.startsWith('mpv') || key.endsWith('_m_s')) return '${v.toStringAsFixed(2)} m/s';
  if (key.endsWith('_deg')) return '${fmtNum(v)}°';
  if (key.endsWith('_kg')) return '${fmtNum(v)} kg';
  return fmtNum(v);
}

String nextSetText(NextSetPrescription n) {
  final action = switch (n.action) {
    'increase_load' => 'Increase load ${fmtNum(n.loadChangePct.abs())} %',
    'reduce_load' => 'Reduce load ${fmtNum(n.loadChangePct.abs())} %',
    'stop_exercise' => 'Stop this exercise for today',
    _ => 'Keep the same load',
  };
  final rest = n.restSeconds;
  return rest == null ? action : '$action · rest $rest s';
}

/// Read-only history of sets and their coaching cards (replaces the v1 free-form chat,
/// spec 3.4). Every number shown was produced by the device or the server's rules,
/// never by the language model.
class CoachScreen extends ConsumerWidget {
  const CoachScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(localSetsProvider);
    final server = ref.watch(serverSetsProvider);
    final entries = mergeCoachEntries(local.value ?? const [], server.value?.items ?? const []);
    final t = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: () => ref.refresh(serverSetsProvider.future),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Coaching history', style: t.headlineSmall),
          Text('Feedback on your tracked sets. To log food or workouts by text, use Track.', style: t.bodySmall),
          const SizedBox(height: 12),
          if (server case AsyncError(:final error))
            Card(
              key: const Key('coach.servererror'),
              child: ListTile(
                leading: const Icon(Icons.cloud_off),
                title: Text(error is ApiException ? error.message : 'Could not load sets from the server'),
                subtitle: const Text('Sets saved on this phone are still shown.'),
                trailing: TextButton(onPressed: () => ref.invalidate(serverSetsProvider), child: const Text('Retry')),
              ),
            ),
          if (server.isLoading && entries.isEmpty) const Center(child: CircularProgressIndicator()),
          if (!server.isLoading && entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('No tracked sets yet. Finish a set in a session to get coaching here.')),
            ),
          for (final e in entries) _SetCard(entry: e),
          if (server.value?.nextBefore != null)
            Center(
              child: TextButton(
                key: const Key('coach.more'),
                onPressed: () => ref.read(serverSetsProvider.notifier).loadMore(),
                child: const Text('Load more'),
              ),
            ),
        ],
      ),
    );
  }
}

class _SetCard extends ConsumerWidget {
  const _SetCard({required this.entry});
  final CoachEntry entry;

  Future<void> _coach(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(serverSetsProvider.notifier).requestCoaching(entry.setId);
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = entry.payload;
    final card = entry.card;
    final when = entry.createdAt.toLocal();
    final title = p == null ? 'Set ${entry.setId.substring(0, 8)}' : '${p.exercise.displayName} · set ${p.setIndex}';
    return Card(
      key: Key('coach.set.${entry.setId}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            if (p?.dataSource == DataSource.simulated)
              const Chip(key: Key('coach.simulated'), label: Text('SIMULATED'), visualDensity: VisualDensity.compact),
          ]),
          Text('${when.year}-${_pad2(when.month)}-${_pad2(when.day)} ${fmtTime(context, when)}', style: theme.textTheme.bodySmall),
          if (p != null) ...[const SizedBox(height: 6), _Metrics(p: p)],
          _SyncLine(entry: entry),
          const Divider(),
          if (card != null)
            CoachingCardView(card: card)
          else if (entry.localState == SyncState.pending)
            const Text('Coaching is requested after the upload.')
          else if (entry.localState != SyncState.failed)
            TextButton.icon(
              key: Key('coach.request.${entry.setId}'),
              onPressed: () => _coach(context, ref),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Get coaching'),
            ),
        ]),
      ),
    );
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.p});
  final SetSummaryPayload p;

  @override
  Widget build(BuildContext context) {
    final faults = <String>[
      if (p.faultCounts.valgus > 0) 'valgus ×${p.faultCounts.valgus}',
      if (p.faultCounts.lumbarFlexion > 0) 'lumbar flexion ×${p.faultCounts.lumbarFlexion}',
      if (p.faultCounts.incompleteRom > 0) 'incomplete ROM ×${p.faultCounts.incompleteRom}',
    ];
    final vl = p.velocityLossPct;
    final load = p.loadKg;
    final mqs = p.mqsScore;
    return Wrap(spacing: 6, runSpacing: 4, children: [
      _chip('${p.repsCompleted} reps'),
      if (load != null) _chip('${fmtNum(load)} kg'),
      _chip(p.goal.displayName),
      if (vl != null) _chip('VL ${fmtNum(vl)} % / cap ${fmtNum(p.vlCapPct)} %', warn: p.vlCapExceeded),
      if (mqs != null) _chip('MQS ${fmtNum(mqs)}'),
      if (faults.isNotEmpty) _chip(faults.join(', '), warn: true),
    ]);
  }

  Widget _chip(String s, {bool warn = false}) => Chip(
        label: Text(s),
        visualDensity: VisualDensity.compact,
        avatar: warn ? const Icon(Icons.warning_amber, size: 16) : null,
      );
}

class _SyncLine extends ConsumerWidget {
  const _SyncLine({required this.entry});
  final CoachEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return switch (entry.localState) {
      SyncState.pending => Row(children: [
          const Icon(Icons.cloud_upload_outlined, size: 18),
          const SizedBox(width: 6),
          const Expanded(child: Text('Saved on this phone, waiting to upload')),
          TextButton(
            key: Key('coach.retry.${entry.setId}'),
            onPressed: () => ref.read(syncServiceProvider).retryNow(),
            child: const Text('Retry now'),
          ),
        ]),
      SyncState.failed => Text('Upload failed: ${entry.localError ?? 'rejected by the server'}',
          key: Key('coach.failed.${entry.setId}'), style: TextStyle(color: cs.error)),
      _ => const SizedBox.shrink(),
    };
  }
}

/// One coaching card (source badge, summary, cues, next set). Shared by Coach and the
/// session's rest audit.
class CoachingCardView extends StatelessWidget {
  const CoachingCardView({super.key, required this.card});
  final CoachingCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (badge, icon) = switch (card.source) {
      // The model name tells a real model from the backend's test double (fake-llm).
      CoachingSource.llm => (
          card.model == null ? 'AI coach (local model)' : 'AI coach (local model · ${card.model})',
          Icons.auto_awesome
        ),
      CoachingSource.fallback => ('Rule-based feedback', Icons.rule),
      CoachingSource.guardrail => ('Safety notice', Icons.health_and_safety),
    };
    final focus = card.focusMetric;
    final focusValue = card.focusValue;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(badge, key: Key('coach.source.${card.source.wire}'), style: theme.textTheme.labelLarge),
      ]),
      const SizedBox(height: 6),
      Text(card.summary),
      if (card.medicalNotice case final notice?)
        Card(
          color: theme.colorScheme.errorContainer,
          child: Padding(padding: const EdgeInsets.all(8), child: Text(notice)),
        ),
      if (focus != null && focusValue != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Focus: ${metricLabel(focus)} ${metricValue(focus, focusValue)}', style: theme.textTheme.titleSmall),
        ),
      for (final cue in card.cues)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.chevron_right),
          title: Text(cue.text),
          trailing: (cue.metricRef != null && cue.metricValue != null)
              ? Text(metricValue(cue.metricRef!, cue.metricValue!))
              : null,
        ),
      if (card.source != CoachingSource.guardrail)
        Text('Next set: ${nextSetText(card.nextSet)}', key: const Key('coach.nextset'), style: theme.textTheme.titleSmall),
    ]);
  }
}
