import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/api/api_models.dart';
import '../logs/log_providers.dart';
import '../widgets/async_view.dart';

const statsRanges = [7, 14, 30, 90];

/// Ported v1 Stats page: range pills, four summary pills, lifting volume (bars) and
/// daily calories (line). All numbers come from `GET /stats` (UTC days).
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(statsDaysProvider);
    final stats = ref.watch(statsProvider);
    final t = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: () => ref.refresh(statsProvider.future),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Last $days days', key: const Key('stats.subtitle'), style: t.bodyMedium),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [for (final d in statsRanges) ButtonSegment(value: d, label: Text('${d}d'))],
            selected: {days},
            onSelectionChanged: (s) => ref.read(statsDaysProvider.notifier).select(s.first),
          ),
          const SizedBox(height: 16),
          AsyncView(
            value: stats,
            onRetry: () => ref.invalidate(statsProvider),
            builder: (s) => _StatsBody(stats: s),
          ),
        ],
      ),
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.stats});
  final StatsSummary stats;

  @override
  Widget build(BuildContext context) {
    final hasVolume = stats.days.any((d) => d.volume > 0);
    final hasCalories = stats.days.any((d) => d.calories > 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [
          _Pill('Avg volume / day', '${stats.avgVolume} kg', key: const Key('stats.avgVolume')),
          _Pill('Avg calories / day', '${stats.avgCalories} kcal', key: const Key('stats.avgCalories')),
          _Pill('Workouts', '${stats.totalWorkouts}', key: const Key('stats.workouts')),
          _Pill('Meals logged', '${stats.totalMeals}', key: const Key('stats.meals')),
        ],
      ),
      const SizedBox(height: 16),
      _ChartCard(
        title: 'Lifting volume',
        headline: '${stats.avgVolume} kg avg',
        empty: hasVolume ? null : 'Log workouts to see your trend',
        chart: BarChart(BarChartData(
          barGroups: [
            for (final (i, d) in stats.days.indexed)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(toY: d.volume, width: stats.days.length > 30 ? 2 : 8, color: Theme.of(context).colorScheme.primary),
              ]),
          ],
          titlesData: _titles(stats.days),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
        )),
      ),
      const SizedBox(height: 16),
      _ChartCard(
        title: 'Daily calories',
        headline: '${stats.avgCalories} kcal avg',
        empty: hasCalories ? null : 'Log meals to see your trend',
        chart: LineChart(LineChartData(
          lineBarsData: [
            LineChartBarData(
              spots: [for (final (i, d) in stats.days.indexed) FlSpot(i.toDouble(), d.calories.toDouble())],
              isCurved: true,
              preventCurveOverShooting: true,
              color: Theme.of(context).colorScheme.tertiary,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.12)),
            ),
          ],
          minY: 0,
          titlesData: _titles(stats.days),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
        )),
      ),
    ]);
  }

  /// Day-of-month labels on about six evenly spaced days.
  static FlTitlesData _titles(List<StatsDay> days) {
    final every = (days.length / 6).ceil().clamp(1, 1000);
    return FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          interval: 1,
          getTitlesWidget: (value, meta) {
            final i = value.round();
            if (i < 0 || i >= days.length || value != i || i % every != 0) return const SizedBox.shrink();
            final d = days[i].date; // YYYY-MM-DD
            return Text('${d.substring(8, 10)}/${d.substring(5, 7)}', style: const TextStyle(fontSize: 10));
          },
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(label, style: t.labelSmall),
          Text(value, style: t.titleLarge),
        ]),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.headline, required this.chart, this.empty});
  final String title;
  final String headline;
  final Widget chart;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.titleSmall),
          Text(headline, style: t.headlineSmall),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: empty == null ? chart : Center(child: Text(empty!, style: t.bodyMedium)),
          ),
        ]),
      ),
    );
  }
}
