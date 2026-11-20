/// SetSummaryPayload v1.0.0 — Dart mirror of backend/app/schemas/set_summary.py and
/// contracts/set_summary.v1.schema.json (docs/CONTRACT.md).
///
/// Same rules as the server: unknown keys are rejected, every key is required (missing
/// metrics are explicit `null`), and the consistency checks run in [validate].
/// `backend/tests/test_contract.py` checks that every schema key appears here as a
/// quoted string; `test/contract/set_summary_payload_test.dart` parses the shared fixtures.
library;

import '../workout/workout_models.dart';

const kSetSummarySchemaVersion = '1.0.0';

class ContractError extends FormatException {
  ContractError(super.message);
}

Map<String, Object?> _obj(Object? v, String where) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) return v.cast<String, Object?>();
  throw ContractError('$where: expected object');
}

void _exactKeys(Map<String, Object?> m, Set<String> keys, String where) {
  final unknown = m.keys.toSet().difference(keys);
  final missing = keys.difference(m.keys.toSet());
  if (unknown.isNotEmpty) throw ContractError('$where: unknown field(s) $unknown');
  if (missing.isNotEmpty) throw ContractError('$where: missing field(s) $missing (send null instead)');
}

double? _numOrNull(Object? v, String k) {
  if (v == null) return null;
  if (v is num && v.isFinite) return v.toDouble();
  throw ContractError('$k: expected finite number or null');
}

double _num(Object? v, String k) => _numOrNull(v, k) ?? (throw ContractError('$k: must not be null'));

int _int(Object? v, String k) {
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw ContractError('$k: expected integer');
}

String _str(Object? v, String k) => v is String ? v : throw ContractError('$k: expected string');

/// Closed-vocabulary field: any unknown value is a contract violation (ContractError),
/// not a bare FormatException from the enum's `fromWire`.
T _enum<T>(T Function(String) fromWire, Object? v, String k) {
  final s = _str(v, k);
  try {
    return fromWire(s);
  } on FormatException catch (e) {
    throw ContractError('$k: ${e.message}');
  }
}

DateTime? _dateOrNull(Object? v, String k) {
  if (v == null) return null;
  final d = DateTime.tryParse(_str(v, k));
  if (d == null) throw ContractError('$k: invalid ISO-8601 datetime');
  return d;
}

final class RepMetrics {
  const RepMetrics({
    required this.repIndex,
    required this.peakDepthDeg,
    required this.meanVelocityMS,
    required this.faultFlags,
  });

  final int repIndex; // 1-based
  final double? peakDepthDeg;
  final double? meanVelocityMS;
  final List<FaultFlag> faultFlags;

  static const keys = {'rep_index', 'peak_depth_deg', 'mean_velocity_m_s', 'fault_flags'};

  factory RepMetrics.fromJson(Object? json) {
    final m = _obj(json, 'per_rep[]');
    _exactKeys(m, keys, 'per_rep[]');
    final flags = m['fault_flags'];
    if (flags is! List) throw ContractError('fault_flags: expected list');
    return RepMetrics(
      repIndex: _int(m['rep_index'], 'rep_index'),
      peakDepthDeg: _numOrNull(m['peak_depth_deg'], 'peak_depth_deg'),
      meanVelocityMS: _numOrNull(m['mean_velocity_m_s'], 'mean_velocity_m_s'),
      faultFlags: [for (final f in flags) _enum(FaultFlag.fromWire, f, 'fault_flags[]')],
    );
  }

  Map<String, Object?> toJson() => {
        'rep_index': repIndex,
        'peak_depth_deg': peakDepthDeg,
        'mean_velocity_m_s': meanVelocityMS,
        'fault_flags': [for (final f in faultFlags) f.wire],
      };
}

final class FaultCounts {
  const FaultCounts({required this.valgus, required this.lumbarFlexion, required this.incompleteRom});

  final int valgus;
  final int lumbarFlexion;
  final int incompleteRom;

  static const zero = FaultCounts(valgus: 0, lumbarFlexion: 0, incompleteRom: 0);
  static const keys = {'valgus', 'lumbar_flexion', 'incomplete_rom'};

  factory FaultCounts.tally(Iterable<RepMetrics> reps) {
    var v = 0, l = 0, r = 0;
    for (final rep in reps) {
      for (final f in rep.faultFlags) {
        switch (f) {
          case FaultFlag.valgus:
            v++;
          case FaultFlag.lumbarFlexion:
            l++;
          case FaultFlag.incompleteRom:
            r++;
        }
      }
    }
    return FaultCounts(valgus: v, lumbarFlexion: l, incompleteRom: r);
  }

  factory FaultCounts.fromJson(Object? json) {
    final m = _obj(json, 'fault_counts');
    _exactKeys(m, keys, 'fault_counts');
    return FaultCounts(
      valgus: _int(m['valgus'], 'valgus'),
      lumbarFlexion: _int(m['lumbar_flexion'], 'lumbar_flexion'),
      incompleteRom: _int(m['incomplete_rom'], 'incomplete_rom'),
    );
  }

  int get total => valgus + lumbarFlexion + incompleteRom;

  Map<String, Object?> toJson() =>
      {'valgus': valgus, 'lumbar_flexion': lumbarFlexion, 'incomplete_rom': incompleteRom};

  @override
  bool operator ==(Object other) =>
      other is FaultCounts &&
      other.valgus == valgus &&
      other.lumbarFlexion == lumbarFlexion &&
      other.incompleteRom == incompleteRom;

  @override
  int get hashCode => Object.hash(valgus, lumbarFlexion, incompleteRom);
}

final class SetSummaryPayload {
  const SetSummaryPayload({
    this.schemaVersion = kSetSummarySchemaVersion,
    required this.setId,
    required this.exercise,
    required this.goal,
    required this.vlCapPct,
    required this.setIndex,
    required this.repsCompleted,
    required this.loadKg,
    required this.perRep,
    required this.mpvInitial,
    required this.mpvFinal,
    required this.velocityLossPct,
    required this.vlCapExceeded,
    required this.velocitySource,
    required this.mqsScore,
    required this.mqsBreakdown,
    required this.symmetryIndex,
    required this.faultCounts,
    required this.dataSource,
    required this.deviceLabels,
    required this.startedAt,
    required this.endedAt,
  });

  final String schemaVersion;
  final String setId; // UUID generated on the phone
  final Exercise exercise;
  final Goal goal;
  final double vlCapPct;
  final int setIndex;
  final int repsCompleted;
  final double? loadKg;
  final List<RepMetrics> perRep;
  final double? mpvInitial;
  final double? mpvFinal;
  final double? velocityLossPct;
  final bool vlCapExceeded;
  final VelocitySource? velocitySource;
  final double? mqsScore;
  final Map<String, double?>? mqsBreakdown;
  final double? symmetryIndex;
  final FaultCounts faultCounts;
  final DataSource dataSource;
  final List<String> deviceLabels;
  final DateTime? startedAt;
  final DateTime? endedAt;

  static const keys = {
    'schema_version', 'set_id', 'exercise', 'goal', 'vl_cap_pct', 'set_index', 'reps_completed',
    'load_kg', 'per_rep', 'mpv_initial', 'mpv_final', 'velocity_loss_pct', 'vl_cap_exceeded',
    'velocity_source', 'mqs_score', 'mqs_breakdown', 'symmetry_index', 'fault_counts',
    'data_source', 'device_labels', 'started_at', 'ended_at',
  };

  factory SetSummaryPayload.fromJson(Object? json) {
    final m = _obj(json, 'SetSummaryPayload');
    _exactKeys(m, keys, 'SetSummaryPayload');
    final version = _str(m['schema_version'], 'schema_version');
    if (version != kSetSummarySchemaVersion) throw ContractError('schema_version: expected $kSetSummarySchemaVersion');
    final perRep = m['per_rep'];
    final labels = m['device_labels'];
    final breakdown = m['mqs_breakdown'];
    final exceeded = m['vl_cap_exceeded'];
    if (perRep is! List) throw ContractError('per_rep: expected list');
    if (labels is! List) throw ContractError('device_labels: expected list');
    if (exceeded is! bool) throw ContractError('vl_cap_exceeded: expected bool');
    final p = SetSummaryPayload(
      schemaVersion: version,
      setId: _str(m['set_id'], 'set_id'),
      exercise: _enum(Exercise.fromWire, m['exercise'], 'exercise'),
      goal: _enum(Goal.fromWire, m['goal'], 'goal'),
      vlCapPct: _num(m['vl_cap_pct'], 'vl_cap_pct'),
      setIndex: _int(m['set_index'], 'set_index'),
      repsCompleted: _int(m['reps_completed'], 'reps_completed'),
      loadKg: _numOrNull(m['load_kg'], 'load_kg'),
      perRep: [for (final r in perRep) RepMetrics.fromJson(r)],
      mpvInitial: _numOrNull(m['mpv_initial'], 'mpv_initial'),
      mpvFinal: _numOrNull(m['mpv_final'], 'mpv_final'),
      velocityLossPct: _numOrNull(m['velocity_loss_pct'], 'velocity_loss_pct'),
      vlCapExceeded: exceeded,
      velocitySource: m['velocity_source'] == null
          ? null
          : _enum(VelocitySource.fromWire, m['velocity_source'], 'velocity_source'),
      mqsScore: _numOrNull(m['mqs_score'], 'mqs_score'),
      mqsBreakdown: breakdown == null
          ? null
          : {for (final e in _obj(breakdown, 'mqs_breakdown').entries) e.key: _numOrNull(e.value, e.key)},
      symmetryIndex: _numOrNull(m['symmetry_index'], 'symmetry_index'),
      faultCounts: FaultCounts.fromJson(m['fault_counts']),
      dataSource: _enum(DataSource.fromWire, m['data_source'], 'data_source'),
      deviceLabels: [for (final l in labels) _str(l, 'device_labels[]')],
      startedAt: _dateOrNull(m['started_at'], 'started_at'),
      endedAt: _dateOrNull(m['ended_at'], 'ended_at'),
    );
    p.validate();
    return p;
  }

  /// Same cross-field rules as the Pydantic model. Throws [ContractError].
  void validate() {
    if (perRep.length != repsCompleted) throw ContractError('per_rep must have exactly reps_completed entries');
    for (var i = 0; i < perRep.length; i++) {
      if (perRep[i].repIndex != i + 1) throw ContractError('per_rep.rep_index must be 1..reps_completed in order');
      if (perRep[i].faultFlags.toSet().length != perRep[i].faultFlags.length) {
        throw ContractError('rep ${i + 1}: duplicate fault flag');
      }
    }
    if (FaultCounts.tally(perRep) != faultCounts) {
      throw ContractError('fault_counts must equal the tally of per_rep.fault_flags');
    }
    final vl = velocityLossPct;
    if (vl == null ? vlCapExceeded : vlCapExceeded != (vl >= vlCapPct)) {
      throw ContractError('vl_cap_exceeded must equal velocity_loss_pct >= vl_cap_pct');
    }
    if (vlCapPct <= 0 || vlCapPct > 100) throw ContractError('vl_cap_pct out of range');
    if (setIndex < 1) throw ContractError('set_index must be >= 1');
    if (deviceLabels.isEmpty || deviceLabels.length > 8) throw ContractError('device_labels: 1..8 entries');
    final s = startedAt, e = endedAt;
    if (s != null && e != null && e.isBefore(s)) throw ContractError('ended_at is before started_at');
  }

  Map<String, Object?> toJson() => {
        'schema_version': schemaVersion,
        'set_id': setId,
        'exercise': exercise.wire,
        'goal': goal.wire,
        'vl_cap_pct': vlCapPct,
        'set_index': setIndex,
        'reps_completed': repsCompleted,
        'load_kg': loadKg,
        'per_rep': [for (final r in perRep) r.toJson()],
        'mpv_initial': mpvInitial,
        'mpv_final': mpvFinal,
        'velocity_loss_pct': velocityLossPct,
        'vl_cap_exceeded': vlCapExceeded,
        'velocity_source': velocitySource?.wire,
        'mqs_score': mqsScore,
        'mqs_breakdown': mqsBreakdown,
        'symmetry_index': symmetryIndex,
        'fault_counts': faultCounts.toJson(),
        'data_source': dataSource.wire,
        'device_labels': deviceLabels,
        'started_at': startedAt?.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
      };
}
