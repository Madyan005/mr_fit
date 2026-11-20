import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/api_models.dart';
import 'log_providers.dart';

/// Parsed form fields. Mirrors the server rules (LogCreate/LogUpdate): sets/reps > 0,
/// weight/calories >= 0, name 1..200 chars. Returns an error message or null.
String? validateLogFields({required LogType type, required String name, String sets = '', String reps = '',
    String weight = '', String calories = ''}) {
  final n = name.trim();
  if (n.isEmpty || n.length > 200) return 'Enter a name (up to 200 characters)';
  if (type == LogType.exercise) {
    for (final (label, v) in [('Sets', sets), ('Reps', reps)]) {
      if (v.trim().isEmpty) continue;
      final i = int.tryParse(v.trim());
      if (i == null || i <= 0) return '$label must be a whole number above 0';
    }
    if (weight.trim().isNotEmpty) {
      final w = double.tryParse(weight.trim().replaceAll(',', '.'));
      if (w == null || w < 0 || w.isNaN || w.isInfinite) return 'Weight must be 0 or more';
    }
  } else if (calories.trim().isNotEmpty) {
    final c = int.tryParse(calories.trim());
    if (c == null || c < 0) return 'Calories must be a whole number, 0 or more';
  }
  return null;
}

int? _intOrNull(String s) => s.trim().isEmpty ? null : int.parse(s.trim());
double? _doubleOrNull(String s) => s.trim().isEmpty ? null : double.parse(s.trim().replaceAll(',', '.'));

String _ui(Object e) => e is ApiException ? e.message : 'Something went wrong: $e';

/// Bottom sheet that edits or deletes one log row (replaces v1 inline editing).
Future<void> showEditLogSheet(BuildContext context, LogEntry log) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _LogForm(existing: log));

/// Bottom sheet that adds one log row manually (works without the optional text parser).
Future<void> showAddLogSheet(BuildContext context, {String? exerciseName}) => showModalBottomSheet<void>(
    context: context, isScrollControlled: true, builder: (_) => _LogForm(prefillName: exerciseName));

class _LogForm extends ConsumerStatefulWidget {
  const _LogForm({this.existing, this.prefillName});
  final LogEntry? existing;
  final String? prefillName;

  @override
  ConsumerState<_LogForm> createState() => _LogFormState();
}

class _LogFormState extends ConsumerState<_LogForm> {
  late LogType _type = widget.existing?.type ?? LogType.exercise;
  late final _name = TextEditingController(text: widget.existing?.name ?? widget.prefillName ?? '');
  late final _sets = TextEditingController(text: widget.existing?.sets?.toString() ?? '');
  late final _reps = TextEditingController(text: widget.existing?.reps?.toString() ?? '');
  late final _weight = TextEditingController(text: _w(widget.existing?.weight));
  late final _calories = TextEditingController(text: widget.existing?.calories?.toString() ?? '');
  bool _busy = false;
  String? _error;

  static String _w(double? w) => w == null ? '' : (w == w.roundToDouble() ? w.toStringAsFixed(0) : '$w');

  @override
  void dispose() {
    for (final c in [_name, _sets, _reps, _weight, _calories]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      invalidateLogViewsW(ref);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _ui(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final problem = validateLogFields(
        type: _type, name: _name.text, sets: _sets.text, reps: _reps.text, weight: _weight.text, calories: _calories.text);
    if (problem != null) return setState(() => _error = problem);
    final api = ref.read(apiProvider);
    final existing = widget.existing;
    final isEx = _type == LogType.exercise;
    if (existing == null) {
      _run(() => api.createLog(LogDraft(
            type: _type,
            name: _name.text.trim(),
            sessionId: isEx ? const Uuid().v4() : null,
            sets: isEx ? _intOrNull(_sets.text) : null,
            reps: isEx ? _intOrNull(_reps.text) : null,
            weight: isEx ? _doubleOrNull(_weight.text) : null,
            calories: isEx ? null : _intOrNull(_calories.text),
            rawText: 'Manual entry',
          )));
    } else {
      final patch = LogPatch(
        name: _name.text.trim() == existing.name ? null : _name.text.trim(),
        sets: isEx ? _changed(_intOrNull(_sets.text), existing.sets) : null,
        reps: isEx ? _changed(_intOrNull(_reps.text), existing.reps) : null,
        weight: isEx ? _changed(_doubleOrNull(_weight.text), existing.weight) : null,
        calories: isEx ? null : _changed(_intOrNull(_calories.text), existing.calories),
      );
      if (patch.isEmpty) return Navigator.of(context).pop();
      _run(() => api.updateLog(existing.id, patch));
    }
  }

  static T? _changed<T>(T? now, T? before) => now == before ? null : now;

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this entry?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok ?? false) await _run(() => ref.read(apiProvider).deleteLog(widget.existing!.id));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final isEx = _type == LogType.exercise;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(editing ? 'Edit entry' : 'Add entry', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (!editing)
            SegmentedButton<LogType>(
              segments: const [
                ButtonSegment(value: LogType.exercise, label: Text('Exercise'), icon: Icon(Icons.fitness_center)),
                ButtonSegment(value: LogType.nutrition, label: Text('Meal'), icon: Icon(Icons.restaurant)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
          TextField(key: const Key('log.name'), controller: _name, decoration: InputDecoration(labelText: isEx ? 'Exercise' : 'Meal')),
          if (isEx)
            Row(children: [
              Expanded(child: TextField(key: const Key('log.sets'), controller: _sets, keyboardType: TextInputType.number,
                  inputFormatters: digits, decoration: const InputDecoration(labelText: 'Sets'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(key: const Key('log.reps'), controller: _reps, keyboardType: TextInputType.number,
                  inputFormatters: digits, decoration: const InputDecoration(labelText: 'Reps'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(key: const Key('log.weight'), controller: _weight,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Weight (kg)'))),
            ])
          else
            TextField(key: const Key('log.calories'), controller: _calories, keyboardType: TextInputType.number,
                inputFormatters: digits, decoration: const InputDecoration(labelText: 'Calories (kcal)')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, key: const Key('log.error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          Row(children: [
            if (editing)
              TextButton.icon(
                key: const Key('log.delete'),
                onPressed: _busy ? null : _delete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            const Spacer(),
            FilledButton(key: const Key('log.save'), onPressed: _busy ? null : _save, child: const Text('Save')),
          ]),
        ],
      ),
    );
  }
}
