import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/api_models.dart';
import '../logs/log_providers.dart';

/// v1 Quick Log: a table of sets for one exercise, saved as one log row per set
/// (sets = 1) sharing a session id.
Future<void> showQuickLogSheet(BuildContext context, ExerciseItem exercise) => showModalBottomSheet<void>(
    context: context, isScrollControlled: true, builder: (_) => _QuickLogSheet(exercise: exercise));

/// Rows the user filled in. A row needs reps > 0 (the v2 server rejects reps = 0, which
/// v1 sent for weight-only rows); weight is optional and >= 0. Returns (rows, error).
({List<({int reps, double? weight})> rows, String? error}) parseQuickLogRows(List<(String, String)> raw) {
  final rows = <({int reps, double? weight})>[];
  for (final (i, (reps, weight)) in raw.indexed) {
    if (reps.trim().isEmpty && weight.trim().isEmpty) continue;
    final r = int.tryParse(reps.trim());
    if (r == null || r <= 0) return (rows: const [], error: 'Set ${i + 1}: reps must be a whole number above 0');
    double? w;
    if (weight.trim().isNotEmpty) {
      w = double.tryParse(weight.trim().replaceAll(',', '.'));
      if (w == null || w < 0) return (rows: const [], error: 'Set ${i + 1}: weight must be 0 or more');
    }
    rows.add((reps: r, weight: w));
  }
  if (rows.isEmpty) return (rows: const [], error: 'Add at least one set');
  return (rows: rows, error: null);
}

class _QuickLogSheet extends ConsumerStatefulWidget {
  const _QuickLogSheet({required this.exercise});
  final ExerciseItem exercise;

  @override
  ConsumerState<_QuickLogSheet> createState() => _QuickLogSheetState();
}

class _QuickLogSheetState extends ConsumerState<_QuickLogSheet> {
  final _rows = <(TextEditingController, TextEditingController)>[];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _addRow();
  }

  void _addRow() => _rows.add((TextEditingController(), TextEditingController()));

  @override
  void dispose() {
    for (final (a, b) in _rows) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final parsed = parseQuickLogRows([for (final (r, w) in _rows) (r.text, w.text)]);
    if (parsed.error != null) return setState(() => _error = parsed.error);
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = ref.read(apiProvider);
    final session = const Uuid().v4();
    var saved = 0;
    try {
      for (final row in parsed.rows) {
        await api.createLog(LogDraft(
          type: LogType.exercise,
          name: widget.exercise.name,
          sessionId: session,
          sets: 1,
          reps: row.reps,
          weight: row.weight,
          rawText: 'Quick log: 1 set',
        ));
        saved++;
      }
      invalidateLogViewsW(ref);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (saved > 0) invalidateLogViewsW(ref);
      if (mounted) setState(() => _error = saved > 0 ? 'Saved $saved set(s), then failed: ${e.message}' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _logByVoice() {
    ref.read(prefillExerciseProvider.notifier).set(widget.exercise.name);
    ref.read(shellTabProvider.notifier).select(0);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Quick log · ${widget.exercise.name}', style: theme.textTheme.titleLarge),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('quick.voice'),
                onPressed: _logByVoice,
                icon: const Icon(Icons.mic_none),
                label: const Text('Log by voice or text on Track'),
              ),
            ),
            for (final (i, (reps, weight)) in _rows.indexed)
              Row(children: [
                SizedBox(width: 56, child: Text('Set ${i + 1}')),
                Expanded(
                  child: TextField(
                    key: Key('quick.reps.$i'),
                    controller: reps,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Reps'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: Key('quick.weight.$i'),
                    controller: weight,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Weight (kg)'),
                  ),
                ),
              ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, key: const Key('quick.error'), style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 12),
            Row(children: [
              TextButton(key: const Key('quick.addset'), onPressed: () => setState(_addRow), child: const Text('+ Add set')),
              const Spacer(),
              FilledButton(key: const Key('quick.save'), onPressed: _busy ? null : _save, child: const Text('Save workout')),
            ]),
          ],
        ),
      ),
    );
  }
}
