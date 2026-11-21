import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mr_fit/data/api/api_models.dart';
import 'package:mr_fit/data/local/app_database.dart';
import 'package:mr_fit/presentation/coach/coach_providers.dart';
import 'package:mr_fit/presentation/coach/coach_screen.dart';

import '../support/app_harness.dart';

Map<String, Object?> fixture(String name) =>
    (jsonDecode(File('../contracts/fixtures/set_summary_$name.json').readAsStringSync()) as Map).cast<String, Object?>();

Map<String, Object?> cardJson(String setId, {String source = 'fallback', String? notice, String? model}) => {
      'schema_version': '1.0.0', 'set_id': setId, 'source': source,
      'summary': source == 'guardrail' ? 'Please see a professional.' : 'Velocity loss passed your cap.',
      'cues': source == 'guardrail' ? <Object?>[] : [
        {'text': 'End the set when bar speed drops.', 'metric_ref': 'velocity_loss_pct', 'metric_value': 24.4},
      ],
      'focus_metric': source == 'guardrail' ? null : 'velocity_loss_pct',
      'focus_value': source == 'guardrail' ? null : 24.4,
      'next_set': {'action': 'reduce_load', 'rest_seconds': 240, 'load_change_pct': -5.0, 'rule_id': 'vl_cap_exceeded'},
      'medical_notice': notice, 'model': model, 'fallback_reason': null, 'generated_at': '2026-11-20T10:05:31Z',
    };

Map<String, Object?> setJson(Map<String, Object?> payload, {Map<String, Object?>? coaching, String created = '2026-11-20T10:05:30Z'}) => {
      'set_id': payload['set_id'], 'created_at': created, 'log_id': 1, 'payload': payload,
      'coaching': coaching, 'coaching_source': coaching?['source'],
    };

void main() {
  late AppHarness h;
  final fatigue = fixture('fatigue'); // bench_press, VL 24.4 % > cap 20 %, simulated
  final clean = fixture('clean');
  final fatigueId = fatigue['set_id']! as String;
  final cleanId = clean['set_id']! as String;

  setUp(() {
    h = AppHarness(secrets: AppHarness.signedIn);
    h.http.reply('GET', '/logs', 200, <Object?>[]);
  });

  Future<void> openCoach(WidgetTester tester) async {
    await h.pump(tester);
    await tester.tap(find.text('Coach'));
    await tester.pumpAndSettle();
  }

  Future<void> insertLocal(Map<String, Object?> payload, SyncState state, {String? error}) =>
      h.db.into(h.db.localSets).insert(LocalSetsCompanion.insert(
          setId: payload['set_id']! as String, exercise: payload['exercise']! as String, payloadJson: jsonEncode(payload),
          createdAt: DateTime.utc(2026, 11, 21, 9), syncState: state, lastError: Value(error)));

  testWidgets('a coached set shows its metrics, the SIMULATED tag and a deterministic card', (tester) async {
    h.http.reply('GET', '/sets', 200, {'items': [setJson(fatigue, coaching: cardJson(fatigueId))], 'next_before': null});
    await openCoach(tester);
    expect(find.text('Bench Press · set 2'), findsOneWidget);
    expect(find.byKey(const Key('coach.simulated')), findsOneWidget);
    expect(find.text('VL 24.4 % / cap 20 %'), findsOneWidget);
    expect(find.text('incomplete ROM ×1'), findsOneWidget);
    expect(find.text('Rule-based feedback'), findsOneWidget);
    expect(find.text('Focus: Velocity loss 24.4 %'), findsOneWidget);
    expect(find.text('Next set: Reduce load 5 % · rest 240 s'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'read-only: no chat input');
    await h.dispose(tester);
  });

  testWidgets('a model-written card names its model, so the backend fake LLM is visible', (tester) async {
    h.http.reply('GET', '/sets', 200,
        {'items': [setJson(fatigue, coaching: cardJson(fatigueId, source: 'llm', model: 'fake-llm'))], 'next_before': null});
    await openCoach(tester);
    expect(find.text('AI coach (local model · fake-llm)'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('a set waiting on this phone is listed with Retry now, which runs the queue', (tester) async {
    h.http.reply('GET', '/sets', 200, {'items': <Object?>[], 'next_before': null});
    h.http.reply('POST', '/sets', 201, {});
    await insertLocal(clean, SyncState.pending);
    await h.db.into(h.db.outbox).insert(OutboxCompanion.insert(
        kind: OutboxKind.setSummary, setId: cleanId, body: jsonEncode(clean),
        nextAttemptAt: DateTime.utc(2030), createdAt: DateTime.utc(2026, 11, 21)));
    await openCoach(tester);
    expect(find.text('Saved on this phone, waiting to upload'), findsOneWidget);
    expect(find.text('Coaching is requested after the upload.'), findsOneWidget);

    await tester.tap(find.byKey(Key('coach.retry.$cleanId')));
    await tester.pumpAndSettle();
    expect(h.http.count('POST', '/sets'), 1, reason: 'retry ignores the backoff time');
    expect(find.text('Saved on this phone, waiting to upload'), findsNothing);
    await h.dispose(tester);
  });

  testWidgets('a rejected upload shows the reason', (tester) async {
    h.http.reply('GET', '/sets', 200, {'items': <Object?>[], 'next_before': null});
    await insertLocal(clean, SyncState.failed, error: '422 per_rep: bad');
    await openCoach(tester);
    expect(find.text('Upload failed: 422 per_rep: bad'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('offline: local sets are still shown next to a server error with Retry', (tester) async {
    h.http.on('GET', '/sets', (_) async => (null, null));
    await insertLocal(clean, SyncState.pending);
    await openCoach(tester);
    expect(find.byKey(const Key('coach.servererror')), findsOneWidget);
    expect(find.byKey(Key('coach.set.$cleanId')), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('"Get coaching" asks the server and shows the safety card for a guardrail result', (tester) async {
    h.http.reply('GET', '/sets', 200, {'items': [setJson(clean)], 'next_before': null});
    h.http.reply('POST', '/sets/$cleanId/coaching', 200,
        cardJson(cleanId, source: 'guardrail', notice: 'Talk to a licensed physical therapist.'));
    await openCoach(tester);
    await tester.tap(find.byKey(Key('coach.request.$cleanId')));
    await tester.pumpAndSettle();
    expect(h.http.seen.last.body, {'athlete_note': null, 'force_regenerate': false});
    expect(find.text('Safety notice'), findsOneWidget);
    expect(find.text('Talk to a licensed physical therapist.'), findsOneWidget);
    expect(find.byKey(const Key('coach.nextset')), findsNothing, reason: 'no training advice on a safety referral');
    await h.dispose(tester);
  });

  testWidgets('"Load more" requests the next page with ?before=', (tester) async {
    h.http.on('GET', '/sets', (r) async => r.query['before'] == null
        ? (200, {'items': [setJson(fatigue, coaching: cardJson(fatigueId))], 'next_before': '2026-11-20T10:05:30Z'})
        : (200, {'items': [setJson(clean, created: '2026-11-19T10:00:00Z')], 'next_before': null}));
    await openCoach(tester);
    await tester.scrollUntilVisible(find.byKey(const Key('coach.more')), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coach.more')));
    await tester.pumpAndSettle();
    expect(h.http.seen.lastWhere((r) => r.path == '/sets').query['before'], '2026-11-20T10:05:30Z');
    await tester.scrollUntilVisible(find.byKey(Key('coach.set.$cleanId')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('coach.more')), findsNothing);
    await h.dispose(tester);
  });

  test('merge: one entry per set id, server payload wins, a local card is kept', () {
    final server = SetRecord.fromJson(setJson(fatigue));
    final local = LocalSet(
        setId: fatigueId, exercise: 'bench_press', payloadJson: jsonEncode(fatigue), createdAt: DateTime.utc(2026, 11, 20),
        syncState: SyncState.synced, coachingJson: jsonEncode(cardJson(fatigueId)));
    final merged = mergeCoachEntries([local], [server]);
    expect(merged, hasLength(1));
    expect(merged.single.card!.source, CoachingSource.fallback);
    expect(merged.single.localState, SyncState.synced);
  });

  test('metric formatting uses the unit implied by the key', () {
    expect(metricValue('velocity_loss_pct', 24.4), '24.4 %');
    expect(metricValue('mpv_initial', 0.45), '0.45 m/s');
    expect(metricValue('mqs_score', 71), '71');
  });
}
