import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/api/api_models.dart';

/// "Today" is the UTC day, as in v1 and in the backend's `/logs?date=`, `/logs/heatmap`
/// and `/stats` (all UTC). See docs/DECISIONS.md D-067.
DateTime utcToday() => DateTime.now().toUtc();

final todayLogsProvider = FutureProvider.autoDispose<List<LogEntry>>(
    (ref) => ref.watch(apiProvider).logsForDay(utcToday()));

final heatmapProvider = FutureProvider.autoDispose<Map<String, HeatmapDay>>(
    (ref) => ref.watch(apiProvider).heatmap(days: 90));

/// Selected Stats range (7 / 14 / 30 / 90 days, as in v1).
final statsDaysProvider = NotifierProvider<StatsDays, int>(StatsDays.new);

class StatsDays extends Notifier<int> {
  @override
  int build() => 7;
  void select(int d) => state = d;
}

final statsProvider = FutureProvider.autoDispose<StatsSummary>(
    (ref) => ref.watch(apiProvider).stats(days: ref.watch(statsDaysProvider)));

final exerciseLibraryProvider =
    FutureProvider.autoDispose<ExerciseLibrary>((ref) => ref.watch(apiProvider).exercises());

/// Exercise picked in the Library to be logged by voice/text on Track (v1 "prefill").
final prefillExerciseProvider = NotifierProvider<PrefillExercise, String?>(PrefillExercise.new);

class PrefillExercise extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? name) => state = name;
}

/// Every view that shows logs must refresh after a log changes.
void invalidateLogViewsW(WidgetRef ref) {
  ref.invalidate(todayLogsProvider);
  ref.invalidate(heatmapProvider);
  ref.invalidate(statsProvider);
}
