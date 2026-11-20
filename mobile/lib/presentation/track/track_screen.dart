import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/api_models.dart';
import '../../data/voice/voice_input.dart';
import '../logs/log_format.dart';
import '../logs/log_list.dart';
import '../logs/log_providers.dart';
import '../logs/log_sheets.dart';
import '../widgets/async_view.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String utcDayLabel(DateTime utc) => '${_weekdays[utc.weekday - 1]} ${utc.day} ${_months[utc.month - 1]} (UTC day)';

/// Ported v1 Track page: today's totals, the text/voice input, and today's log.
class TrackScreen extends ConsumerStatefulWidget {
  const TrackScreen({super.key});

  @override
  ConsumerState<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends ConsumerState<TrackScreen> {
  final _input = TextEditingController();
  // Kept in a field: `ref` must not be used in dispose().
  late final VoiceInput _voice;
  bool _busy = false;
  bool _listening = false;
  ({bool ok, String text})? _status;

  @override
  void initState() {
    super.initState();
    _voice = ref.read(voiceInputProvider);
  }

  @override
  void dispose() {
    if (_listening) _voice.stop();
    _input.dispose();
    super.dispose();
  }

  /// v1 `logEntry`: parse on the server (optional Gemini), then POST /logs per item with
  /// one session id per exercise name.
  Future<void> _logIt() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    final api = ref.read(apiProvider);
    final saved = <LogEntry>[];
    try {
      final items = await api.parseEntry(text, prefillExercise: ref.read(prefillExerciseProvider));
      if (items.isEmpty) throw const ApiException(ApiErrorKind.invalid, 'Nothing to log was found in that text.');
      final sessions = <String, String>{};
      for (final item in items) {
        final name = '${asMap(item, 'parsed item')['name']}';
        final draft = LogDraft.fromParsed(item, rawText: text, sessionId: sessions.putIfAbsent(name, () => const Uuid().v4()));
        saved.add(await api.createLog(draft));
      }
      _input.clear();
      ref.read(prefillExerciseProvider.notifier).set(null);
      _status = (ok: true, text: 'Logged: ${saved.map((s) => s.name).join(', ')}');
    } on ApiException catch (e) {
      final why = e.kind == ApiErrorKind.unavailable && saved.isEmpty
          ? 'Text parsing is switched off on this server. Use "Add manually".'
          : e.message;
      _status = (ok: false, text: saved.isEmpty ? why : 'Logged ${saved.length}, then failed: $why');
    } on FormatException catch (e) {
      _status = (ok: false, text: 'Unexpected parser output: ${e.message}');
    }
    if (saved.isNotEmpty) invalidateLogViewsW(ref);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleMic() async {
    final voice = _voice;
    if (_listening) {
      await voice.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final started = await voice.start((words, isFinal) {
      if (!mounted) return;
      setState(() {
        _input.text = words;
        if (isFinal) _listening = false;
      });
    });
    if (!mounted) return;
    setState(() {
      _listening = started;
      if (!started) _status = (ok: false, text: 'Voice input is not available (microphone permission or no recognizer).');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final logs = ref.watch(todayLogsProvider);
    final prefill = ref.watch(prefillExerciseProvider);
    final today = logs.value ?? const <LogEntry>[];
    final kcal = today.where((l) => l.type == LogType.nutrition).fold<int>(0, (s, l) => s + (l.calories ?? 0));
    final volume = today.where((l) => l.type == LogType.exercise).fold<double>(0, (s, l) => s + (l.volume ?? 0));

    return RefreshIndicator(
      onRefresh: () => ref.refresh(todayLogsProvider.future),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Today', style: theme.textTheme.headlineSmall),
          Text(utcDayLabel(utcToday()), style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _SummaryCard(label: 'Calories', value: '$kcal', unit: 'kcal today', key: const Key('track.kcal'))),
            const SizedBox(width: 12),
            Expanded(child: _SummaryCard(label: 'Volume', value: fmtNum(volume.round()), unit: 'kg lifted today', key: const Key('track.volume'))),
          ]),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (prefill != null)
                  InputChip(
                    key: const Key('track.prefill'),
                    avatar: const Icon(Icons.bolt, size: 18),
                    label: Text('Logging: $prefill · add reps & weight'),
                    onDeleted: () => ref.read(prefillExerciseProvider.notifier).set(null),
                  ),
                TextField(
                  key: const Key('track.input'),
                  controller: _input,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: "e.g. '3 sets of 12 reps bench press at 80kg' or 'chicken salad and coffee'",
                  ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  IconButton(
                    key: const Key('track.mic'),
                    tooltip: _listening ? 'Stop listening' : 'Voice input',
                    onPressed: _busy ? null : _toggleMic,
                    icon: Icon(_listening ? Icons.mic : Icons.mic_none),
                    color: _listening ? theme.colorScheme.error : null,
                  ),
                  TextButton.icon(
                    key: const Key('track.manual'),
                    onPressed: () => showAddLogSheet(context, exerciseName: prefill),
                    icon: const Icon(Icons.add),
                    label: const Text('Add manually'),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('track.logit'),
                    onPressed: _busy ? null : _logIt,
                    child: _busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Log it'),
                  ),
                ]),
                if (_status case final s?)
                  Text(s.text,
                      key: const Key('track.status'),
                      style: TextStyle(color: s.ok ? theme.colorScheme.primary : theme.colorScheme.error)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Text("Today's log", style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          AsyncView(
            value: logs,
            onRetry: () => ref.invalidate(todayLogsProvider),
            builder: (list) => LogList(logs: list, emptyText: 'Nothing logged yet. Start with a set or a meal.'),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({super.key, required this.label, required this.value, required this.unit});
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: t.labelSmall),
          Text(value, style: t.headlineMedium),
          Text(unit, style: t.bodySmall),
        ]),
      ),
    );
  }
}
