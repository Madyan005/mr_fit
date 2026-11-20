/// Typed views of the backend responses (backend/app/schemas/*). Hand-written so every
/// cast is explicit under `strict-casts`; unknown extra keys are ignored on purpose
/// (the server may add fields), missing required keys throw [FormatException].
library;

import '../../domain/contracts/set_summary_payload.dart';

Map<String, Object?> asMap(Object? v, String what) {
  if (v is Map) return v.cast<String, Object?>();
  throw FormatException('$what: expected an object');
}

List<Object?> asList(Object? v, String what) {
  if (v is List) return v.cast<Object?>();
  throw FormatException('$what: expected a list');
}

String _str(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v is String) return v;
  throw FormatException('$k: expected a string');
}

String? _strOrNull(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null || v is String) return v as String?;
  throw FormatException('$k: expected a string or null');
}

int _int(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw FormatException('$k: expected an integer');
}

int? _intOrNull(Map<String, Object?> m, String k) => m[k] == null ? null : _int(m, k);

double? _numOrNull(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  throw FormatException('$k: expected a number');
}

double _num(Map<String, Object?> m, String k) =>
    _numOrNull(m, k) ?? (throw FormatException('$k: expected a number'));

/// Backend timestamps are UTC; a value without an offset (SQLite in dev) is read as UTC.
DateTime parseServerTime(String s) {
  final hasZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(s);
  return DateTime.parse(hasZone ? s : '${s}Z').toUtc();
}

enum LogType {
  exercise('EXERCISE'),
  nutrition('NUTRITION');

  const LogType(this.wire);
  final String wire;
  static LogType fromWire(String s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => throw FormatException('unknown log type "$s"'));
}

/// One row of `/logs` (LogOut). In `/logs/heatmap` details, `user_id` and `raw_text` are omitted.
final class LogEntry {
  const LogEntry({
    required this.id,
    required this.type,
    required this.name,
    required this.createdAt,
    this.sessionId,
    this.sets,
    this.reps,
    this.weight,
    this.calories,
    this.volume,
    this.rawText,
  });

  final int id;
  final LogType type;
  final String name;
  final DateTime createdAt;
  final String? sessionId;
  final int? sets;
  final int? reps;
  final double? weight;
  final int? calories;
  final double? volume;
  final String? rawText;

  factory LogEntry.fromJson(Object? json) {
    final m = asMap(json, 'log');
    return LogEntry(
      id: _int(m, 'id'),
      type: LogType.fromWire(_str(m, 'type')),
      name: _str(m, 'name'),
      createdAt: parseServerTime(_str(m, 'created_at')),
      sessionId: _strOrNull(m, 'session_id'),
      sets: _intOrNull(m, 'sets'),
      reps: _intOrNull(m, 'reps'),
      weight: _numOrNull(m, 'weight'),
      calories: _intOrNull(m, 'calories'),
      volume: _numOrNull(m, 'volume'),
      rawText: _strOrNull(m, 'raw_text'),
    );
  }
}

/// Body of `POST /logs` (LogCreate). `volume` is computed by the server for exercises.
final class LogDraft {
  const LogDraft({
    required this.type,
    required this.name,
    this.sessionId,
    this.sets,
    this.reps,
    this.weight,
    this.calories,
    this.rawText = '',
  });

  final LogType type;
  final String name;
  final String? sessionId;
  final int? sets;
  final int? reps;
  final double? weight;
  final int? calories;
  final String rawText;

  Map<String, Object?> toJson() => {
        'type': type.wire,
        'name': name,
        'session_id': sessionId,
        'sets': sets,
        'reps': reps,
        'weight': weight,
        'calories': calories,
        'raw_text': rawText,
      };

  /// An item returned by `POST /parse-entry` (optional Gemini parser).
  factory LogDraft.fromParsed(Object? json, {required String rawText, String? sessionId}) {
    final m = asMap(json, 'parsed item');
    final type = LogType.fromWire(_str(m, 'type'));
    return LogDraft(
      type: type,
      name: _str(m, 'name'),
      sessionId: type == LogType.exercise ? sessionId : null,
      sets: _positiveOrNull(_intOrNull(m, 'sets')),
      reps: _positiveOrNull(_intOrNull(m, 'reps')),
      weight: _numOrNull(m, 'weight'),
      calories: _intOrNull(m, 'calories'),
      rawText: rawText,
    );
  }

  static int? _positiveOrNull(int? v) => v != null && v > 0 ? v : null;
}

/// Body of `PUT /logs/{id}` (LogUpdate). Only non-null fields are sent.
final class LogPatch {
  const LogPatch({this.name, this.sets, this.reps, this.weight, this.calories});
  final String? name;
  final int? sets;
  final int? reps;
  final double? weight;
  final int? calories;

  Map<String, Object?> toJson() => {
        'name': ?name,
        'sets': ?sets,
        'reps': ?reps,
        'weight': ?weight,
        'calories': ?calories,
      };

  bool get isEmpty => toJson().isEmpty;
}

/// `GET /logs/heatmap` value for one UTC day.
final class HeatmapDay {
  const HeatmapDay({required this.count, required this.details});
  final int count;
  final List<LogEntry> details;

  static Map<String, HeatmapDay> parseAll(Object? json) => {
        for (final e in asMap(json, 'heatmap').entries)
          e.key: () {
            final m = asMap(e.value, 'heatmap day');
            return HeatmapDay(
              count: _int(m, 'count'),
              details: [for (final d in asList(m['details'], 'details')) LogEntry.fromJson(d)],
            );
          }(),
      };
}

/// `GET /stats`.
final class StatsSummary {
  const StatsSummary({
    required this.avgVolume,
    required this.avgCalories,
    required this.totalWorkouts,
    required this.totalMeals,
    required this.days,
  });
  final int avgVolume;
  final int avgCalories;
  final int totalWorkouts;
  final int totalMeals;
  final List<StatsDay> days;

  factory StatsSummary.fromJson(Object? json) {
    final m = asMap(json, 'stats');
    return StatsSummary(
      avgVolume: _int(m, 'avg_volume'),
      avgCalories: _int(m, 'avg_calories'),
      totalWorkouts: _int(m, 'total_workouts'),
      totalMeals: _int(m, 'total_meals'),
      days: [
        for (final d in asList(m['days'], 'days'))
          () {
            final dm = asMap(d, 'stats day');
            return StatsDay(date: _str(dm, 'date'), volume: _num(dm, 'volume'), calories: _int(dm, 'calories'));
          }(),
      ],
    );
  }
}

final class StatsDay {
  const StatsDay({required this.date, required this.volume, required this.calories});
  final String date; // YYYY-MM-DD (UTC)
  final double volume;
  final int calories;
}

/// One entry of `GET /exercises`.
final class ExerciseItem {
  const ExerciseItem({
    required this.name,
    required this.muscle,
    required this.equipmentType,
    this.biomechKey,
    this.custom = false,
    this.id,
  });
  final String name;
  final String muscle;
  final String equipmentType;
  final String? biomechKey; // squat / deadlift / bench_press / push_up, or null
  final bool custom;
  final int? id; // custom exercises only

  factory ExerciseItem.fromJson(Object? json) {
    final m = asMap(json, 'exercise');
    final custom = m['custom'];
    return ExerciseItem(
      name: _str(m, 'name'),
      muscle: _str(m, 'muscle'),
      equipmentType: _str(m, 'equipment_type'),
      biomechKey: _strOrNull(m, 'biomech_key'),
      custom: custom is bool && custom,
      id: _intOrNull(m, 'id'),
    );
  }
}

final class ExerciseLibrary {
  const ExerciseLibrary({required this.muscles, required this.equipmentTypes, required this.exercises});
  final List<String> muscles;
  final List<String> equipmentTypes;
  final List<ExerciseItem> exercises;

  factory ExerciseLibrary.fromJson(Object? json) {
    final m = asMap(json, 'exercise library');
    return ExerciseLibrary(
      muscles: [for (final x in asList(m['muscles'], 'muscles')) x as String],
      equipmentTypes: [for (final x in asList(m['equipment_types'], 'equipment_types')) x as String],
      exercises: [for (final x in asList(m['exercises'], 'exercises')) ExerciseItem.fromJson(x)],
    );
  }
}

enum CoachingSource {
  llm('llm'),
  fallback('fallback'),
  guardrail('guardrail');

  const CoachingSource(this.wire);
  final String wire;
  static CoachingSource fromWire(String s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => throw FormatException('unknown coaching source "$s"'));
}

final class CardCue {
  const CardCue({required this.text, this.metricRef, this.metricValue});
  final String text;
  final String? metricRef;
  final double? metricValue;
}

final class NextSetPrescription {
  const NextSetPrescription({
    required this.action,
    required this.restSeconds,
    required this.loadChangePct,
    required this.ruleId,
  });
  final String action; // continue | increase_load | reduce_load | stop_exercise
  final int? restSeconds;
  final double loadChangePct;
  final String ruleId;
}

/// Coaching card (backend/app/schemas/coaching.py CoachingCard). Every number on it was
/// filled deterministically by the server; the app only displays it.
final class CoachingCard {
  const CoachingCard({
    required this.source,
    required this.summary,
    required this.cues,
    required this.focusMetric,
    required this.focusValue,
    required this.nextSet,
    required this.generatedAt,
    this.medicalNotice,
    this.model,
    this.fallbackReason,
  });

  final CoachingSource source;
  final String summary;
  final List<CardCue> cues;
  final String? focusMetric;
  final double? focusValue;
  final NextSetPrescription nextSet;
  final DateTime generatedAt;
  final String? medicalNotice;
  final String? model;
  final String? fallbackReason;

  factory CoachingCard.fromJson(Object? json) {
    final m = asMap(json, 'coaching card');
    final n = asMap(m['next_set'], 'next_set');
    return CoachingCard(
      source: CoachingSource.fromWire(_str(m, 'source')),
      summary: _str(m, 'summary'),
      cues: [
        for (final c in asList(m['cues'], 'cues'))
          () {
            final cm = asMap(c, 'cue');
            return CardCue(
                text: _str(cm, 'text'), metricRef: _strOrNull(cm, 'metric_ref'), metricValue: _numOrNull(cm, 'metric_value'));
          }(),
      ],
      focusMetric: _strOrNull(m, 'focus_metric'),
      focusValue: _numOrNull(m, 'focus_value'),
      nextSet: NextSetPrescription(
        action: _str(n, 'action'),
        restSeconds: _intOrNull(n, 'rest_seconds'),
        loadChangePct: _num(n, 'load_change_pct'),
        ruleId: _str(n, 'rule_id'),
      ),
      generatedAt: parseServerTime(_str(m, 'generated_at')),
      medicalNotice: _strOrNull(m, 'medical_notice'),
      model: _strOrNull(m, 'model'),
      fallbackReason: _strOrNull(m, 'fallback_reason'),
    );
  }
}

/// One item of `GET /sets` (SetOut). [payload] is null if the stored payload no longer
/// parses with this app's contract version; the raw map is kept for display.
final class SetRecord {
  const SetRecord({
    required this.setId,
    required this.createdAt,
    required this.rawPayload,
    required this.payload,
    required this.coaching,
  });
  final String setId;
  final DateTime createdAt;
  final Map<String, Object?> rawPayload;
  final SetSummaryPayload? payload;
  final CoachingCard? coaching;

  factory SetRecord.fromJson(Object? json) {
    final m = asMap(json, 'set');
    final raw = asMap(m['payload'], 'payload');
    SetSummaryPayload? parsed;
    try {
      parsed = SetSummaryPayload.fromJson(raw);
    } on FormatException {
      parsed = null;
    }
    return SetRecord(
      setId: _str(m, 'set_id'),
      createdAt: parseServerTime(_str(m, 'created_at')),
      rawPayload: raw,
      payload: parsed,
      coaching: m['coaching'] == null ? null : CoachingCard.fromJson(m['coaching']),
    );
  }
}

final class SetPage {
  const SetPage({required this.items, required this.nextBefore});
  final List<SetRecord> items;
  final String? nextBefore;

  factory SetPage.fromJson(Object? json) {
    final m = asMap(json, 'set page');
    return SetPage(
      items: [for (final s in asList(m['items'], 'items')) SetRecord.fromJson(s)],
      nextBefore: _strOrNull(m, 'next_before'),
    );
  }
}
