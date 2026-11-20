import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/api_models.dart';
import '../../data/api/mrfit_api.dart';
import 'log_format.dart';
import 'log_providers.dart';
import 'log_sheets.dart';

/// Grouped log list (v1 `getGroupedLogsHTML`): one card per exercise with its sets, one
/// row per meal. Tap a row to edit it in a bottom sheet; the group menu renames or
/// deletes the whole exercise group.
class LogList extends StatelessWidget {
  const LogList({super.key, required this.logs, this.emptyText = 'Nothing logged yet'});
  final List<LogEntry> logs;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text(emptyText, style: Theme.of(context).textTheme.bodyMedium)),
      );
    }
    return Column(children: [for (final g in groupLogs(logs)) _LogGroupCard(group: g)]);
  }
}

class _LogGroupCard extends ConsumerWidget {
  const _LogGroupCard({required this.group});
  final List<LogEntry> group;

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final ctl = TextEditingController(text: group.first.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename exercise'),
        content: TextField(key: const Key('group.rename'), controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (name == null || name.isEmpty || name == group.first.name || !context.mounted) return;
    await _forAll(context, ref, (api, l) => api.updateLog(l.id, LogPatch(name: name)));
  }

  Future<void> _deleteAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete all ${group.length} entries of ${group.first.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if ((ok ?? false) && context.mounted) await _forAll(context, ref, (api, l) => api.deleteLog(l.id));
  }

  Future<void> _forAll(BuildContext context, WidgetRef ref, Future<void> Function(MrFitApi api, LogEntry l) op) async {
    final api = ref.read(apiProvider);
    try {
      for (final l in group) {
        await op(api, l);
      }
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    invalidateLogViewsW(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = group.first;
    final theme = Theme.of(context);
    if (first.type == LogType.nutrition) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.restaurant),
          title: Text(first.name),
          subtitle: Text(describeLog(first)),
          trailing: Text(fmtTime(context, first.createdAt), style: theme.textTheme.bodySmall),
          onTap: () => showEditLogSheet(context, first),
        ),
      );
    }
    final volume = group.fold<double>(0, (s, l) => s + (l.volume ?? 0));
    return Card(
      child: Column(children: [
        ListTile(
          leading: const Icon(Icons.fitness_center),
          title: Text(first.name, style: theme.textTheme.titleMedium),
          subtitle: Text('${fmtTime(context, first.createdAt)}${volume > 0 ? ' · ${fmtNum(volume)} kg total' : ''}'),
          trailing: PopupMenuButton<String>(
            key: Key('group.menu.${first.name}'),
            onSelected: (v) => v == 'rename' ? _rename(context, ref) : _deleteAll(context, ref),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete all')),
            ],
          ),
        ),
        for (final (i, l) in group.indexed)
          ListTile(
            dense: true,
            title: Text('Entry ${i + 1}'),
            trailing: Text(describeLog(l)),
            onTap: () => showEditLogSheet(context, l),
          ),
      ]),
    );
  }
}
