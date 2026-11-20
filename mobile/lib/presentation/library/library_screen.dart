import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/api_models.dart';
import '../logs/log_providers.dart';
import '../widgets/async_view.dart';
import 'activity_heatmap.dart';
import 'quick_log_sheet.dart';

/// Ported v1 Library page: search, muscle filter, custom exercises (now stored on the
/// server per user instead of in browser localStorage), quick log, activity heatmap.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _search = TextEditingController();
  String? _muscle; // null = all

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ExerciseItem> _filter(List<ExerciseItem> all) {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final e in all)
        if ((_muscle == null || e.muscle == _muscle) && (q.isEmpty || e.name.toLowerCase().contains(q))) e,
    ];
  }

  Future<void> _deleteCustom(ExerciseItem e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove "${e.name}" from your library?'),
        content: const Text('Logged entries are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    try {
      await ref.read(apiProvider).deleteCustomExercise(e.id!);
      ref.invalidate(exerciseLibraryProvider);
    } on ApiException catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lib = ref.watch(exerciseLibraryProvider);
    return RefreshIndicator(
      onRefresh: () {
        ref.invalidate(heatmapProvider);
        return ref.refresh(exerciseLibraryProvider.future);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('lib.search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search exercises…'),
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: lib,
            onRetry: () => ref.invalidate(exerciseLibraryProvider),
            builder: (l) {
              final shown = _filter(l.exercises);
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ChoiceChip(label: const Text('All'), selected: _muscle == null, onSelected: (_) => setState(() => _muscle = null)),
                  for (final m in l.muscles)
                    ChoiceChip(
                      key: Key('lib.muscle.$m'),
                      label: Text(m),
                      selected: _muscle == m,
                      onSelected: (_) => setState(() => _muscle = _muscle == m ? null : m),
                    ),
                ]),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('lib.addcustom'),
                    onPressed: () => showModalBottomSheet<void>(
                        context: context, isScrollControlled: true, builder: (_) => _AddExerciseSheet(library: l)),
                    icon: const Icon(Icons.add),
                    label: const Text('Add exercise'),
                  ),
                ),
                if (shown.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('No exercises match.'))),
                for (final e in shown)
                  Card(
                    child: ListTile(
                      key: Key('lib.ex.${e.name}'),
                      title: Text(e.name),
                      subtitle: Text('${e.muscle} · ${e.equipmentType}${e.biomechKey != null ? ' · velocity tracking' : ''}'),
                      onTap: () => showQuickLogSheet(context, e),
                      trailing: e.custom && e.id != null
                          ? IconButton(
                              key: Key('lib.delete.${e.name}'),
                              tooltip: 'Remove custom exercise',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteCustom(e),
                            )
                          : null,
                    ),
                  ),
              ]);
            },
          ),
          const SizedBox(height: 24),
          Text('Activity heatmap (last 90 days)', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const ActivityHeatmap(),
        ],
      ),
    );
  }
}

class _AddExerciseSheet extends ConsumerStatefulWidget {
  const _AddExerciseSheet({required this.library});
  final ExerciseLibrary library;

  @override
  ConsumerState<_AddExerciseSheet> createState() => _AddExerciseSheetState();
}

class _AddExerciseSheetState extends ConsumerState<_AddExerciseSheet> {
  final _name = TextEditingController();
  late String _muscle = widget.library.muscles.first;
  late String _equipment = widget.library.equipmentTypes.first;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty || name.length > 100) return setState(() => _error = 'Enter an exercise name (up to 100 characters)');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).addCustomExercise(name, _muscle, _equipment);
      ref.invalidate(exerciseLibraryProvider);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Add exercise', style: Theme.of(context).textTheme.titleLarge),
        TextField(key: const Key('custom.name'), controller: _name, decoration: const InputDecoration(labelText: 'Exercise name')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: const Key('custom.muscle'),
              initialValue: _muscle,
              decoration: const InputDecoration(labelText: 'Muscle'),
              items: [for (final m in widget.library.muscles) DropdownMenuItem(value: m, child: Text(m))],
              onChanged: (v) => setState(() => _muscle = v ?? _muscle),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              key: const Key('custom.equipment'),
              initialValue: _equipment,
              decoration: const InputDecoration(labelText: 'Equipment'),
              items: [for (final t in widget.library.equipmentTypes) DropdownMenuItem(value: t, child: Text(t))],
              onChanged: (v) => setState(() => _equipment = v ?? _equipment),
            ),
          ),
        ]),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, key: const Key('custom.error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(key: const Key('custom.save'), onPressed: _busy ? null : _add, child: const Text('Add')),
        ),
      ]),
    );
  }
}
