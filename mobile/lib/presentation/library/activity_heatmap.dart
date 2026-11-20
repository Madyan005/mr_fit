import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/api/api_models.dart';
import '../../data/api/mrfit_api.dart';
import '../logs/log_list.dart';
import '../logs/log_providers.dart';
import '../widgets/async_view.dart';

/// v1 intensity buckets: 0 | 1-2 | 3-4 | 5+.
int heatmapIntensity(int count) => count <= 0 ? 0 : (count <= 2 ? 1 : (count <= 4 ? 2 : 3));

/// The last [days] UTC days, oldest first, as YYYY-MM-DD keys (same keys as `/logs/heatmap`).
List<String> heatmapDays(DateTime nowUtc, {int days = 90}) {
  final today = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
  return [for (var i = days - 1; i >= 0; i--) MrFitApi.utcDay(today.subtract(Duration(days: i)))];
}

/// 90-day activity heatmap (v1). Tap a day to see, edit or delete its entries.
class ActivityHeatmap extends ConsumerWidget {
  const ActivityHeatmap({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(heatmapProvider);
    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(heatmapProvider),
      builder: (map) => _Grid(map: map),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.map});
  final Map<String, HeatmapDay> map;

  Color _color(ColorScheme cs, int level) => switch (level) {
        0 => cs.surfaceContainerHighest,
        1 => cs.primary.withValues(alpha: 0.35),
        2 => cs.primary.withValues(alpha: 0.65),
        _ => cs.primary,
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget square(int level, {Key? key}) => Container(
          key: key,
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: _color(cs, level), borderRadius: BorderRadius.circular(3)),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 3, runSpacing: 3, children: [
        for (final day in heatmapDays(DateTime.now().toUtc()))
          Tooltip(
            message: '$day: ${map[day]?.count ?? 0} activities',
            child: InkWell(
              onTap: () => _showDay(context, day),
              child: square(heatmapIntensity(map[day]?.count ?? 0), key: Key('heat.$day')),
            ),
          ),
      ]),
      const SizedBox(height: 8),
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Text('Less '),
        for (var l = 0; l <= 3; l++) ...[square(l), const SizedBox(width: 3)],
        const Text(' More'),
      ]),
    ]);
  }

  void _showDay(BuildContext context, String day) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (c) => Consumer(builder: (c, ref, _) {
          // Re-read so edits made from the sheet show up immediately.
          final details = ref.watch(heatmapProvider).value?[day]?.details ?? map[day]?.details ?? const [];
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            builder: (c, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
              Text(day, style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 8),
              LogList(logs: details, emptyText: 'No activities logged on this day.'),
            ]),
          );
        }),
      );
}
