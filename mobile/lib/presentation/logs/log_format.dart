import 'package:material_ui/material_ui.dart';

import '../../data/api/api_models.dart';

/// 80.0 -> "80", 82.5 -> "82.5".
String fmtNum(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
}

String fmtTime(BuildContext context, DateTime t) => TimeOfDay.fromDateTime(t.toLocal()).format(context);

/// One-line description of a log row, as in v1's log items.
String describeLog(LogEntry l) {
  if (l.type == LogType.nutrition) return l.calories == null ? 'Meal' : '${l.calories} kcal';
  final parts = <String>[];
  final sets = l.sets, reps = l.reps, w = l.weight;
  if (sets != null && reps != null) {
    parts.add('$sets × $reps');
  } else if (reps != null) {
    parts.add('$reps reps');
  } else if (sets != null) {
    parts.add('$sets sets');
  }
  if (w != null && w > 0) parts.add('@ ${fmtNum(w)} kg');
  final vol = l.volume;
  if (vol != null && vol > 0) parts.add('· ${fmtNum(vol)} kg vol');
  return parts.isEmpty ? 'Exercise' : parts.join(' ');
}

/// v1 grouping: exercises by name (sets in id order), then meals in list order.
List<List<LogEntry>> groupLogs(List<LogEntry> logs) {
  final groups = <String, List<LogEntry>>{};
  final meals = <List<LogEntry>>[];
  for (final l in logs) {
    if (l.type == LogType.exercise) {
      groups.putIfAbsent(l.name, () => []).add(l);
    } else {
      meals.add([l]);
    }
  }
  return [
    for (final g in groups.values) g..sort((a, b) => a.id.compareTo(b.id)),
    ...meals,
  ];
}
