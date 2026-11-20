// Contract test (Dart side). The Python side (backend/tests/test_contract.py) checks the
// same fixtures against the Pydantic model and that every schema key appears in the Dart
// class. Run from mobile/:  flutter test test/contract
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/domain/contracts/set_summary_payload.dart';
import 'package:mr_fit/domain/sensors/channels.dart';

Map<String, Object?> fixture(String name) =>
    jsonDecode(File('../contracts/fixtures/set_summary_$name.json').readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> schema() =>
    jsonDecode(File('../contracts/set_summary.v1.schema.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  for (final name in ['clean', 'fatigue', 'valgus']) {
    test('fixture $name parses and round-trips byte-equivalent', () {
      final raw = fixture(name);
      final p = SetSummaryPayload.fromJson(raw);
      final again = p.toJson();
      expect(again.keys.toSet(), raw.keys.toSet());
      // Re-parse to prove the output is itself valid under the contract.
      expect(SetSummaryPayload.fromJson(jsonDecode(jsonEncode(again))).toJson(), again);
    });
  }

  test('Dart keys == JSON-schema required keys', () {
    final required = (schema()['required'] as List).cast<String>().toSet();
    expect(SetSummaryPayload.keys, required);
    final defs = schema()[r'$defs'] as Map<String, Object?>;
    expect(RepMetrics.keys, ((defs['RepMetrics'] as Map)['required'] as List).cast<String>().toSet());
    expect(FaultCounts.keys, ((defs['FaultCounts'] as Map)['required'] as List).cast<String>().toSet());
  });

  group('rejects what the server rejects', () {
    Map<String, Object?> base() => fixture('clean');
    final cases = <String, Map<String, Object?> Function()>{
      'unknown field': () => base()..['extra'] = 1,
      'omitted optional metric': () => base()..remove('mqs_score'),
      'bad exercise': () => base()..['exercise'] = 'bicep_curl',
      'bad version': () => base()..['schema_version'] = '2.0.0',
      'inconsistent cap flag': () => base()..['vl_cap_exceeded'] = true,
      'reps mismatch': () => base()..['reps_completed'] = 4,
      'fault tally mismatch': () => base()..['fault_counts'] = {'valgus': 1, 'lumbar_flexion': 0, 'incomplete_rom': 0},
      'bad data_source': () => base()..['data_source'] = 'guess',
    };
    cases.forEach((label, build) {
      test(label, () => expect(() => SetSummaryPayload.fromJson(build()), throwsA(isA<ContractError>())));
    });
  });

  test('explicit nulls are accepted', () {
    final m = fixture('clean')
      ..['mqs_score'] = null
      ..['mqs_breakdown'] = null
      ..['symmetry_index'] = null
      ..['velocity_source'] = null;
    expect(SetSummaryPayload.fromJson(m).mqsScore, isNull);
  });

  test('channel registry equals contracts/channels.v1.json', () {
    final reg = jsonDecode(File('../contracts/channels.v1.json').readAsStringSync()) as Map<String, Object?>;
    final names = {for (final c in reg['channels'] as List) (c as Map)['name'] as String};
    expect(Channels.all, names);
  });
}
