import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/data/api/api_client.dart';
import 'package:mr_fit/data/api/api_exception.dart';
import 'package:mr_fit/data/api/mrfit_api.dart';
import 'package:mr_fit/data/auth/token_store.dart';
import 'package:mr_fit/data/local/app_database.dart';
import 'package:mr_fit/data/local/encrypted_db.dart';
import 'package:mr_fit/data/storage/secret_store.dart';
import 'package:mr_fit/data/sync/set_repository.dart';
import 'package:mr_fit/data/sync/sync_service.dart';
import 'package:mr_fit/domain/contracts/set_summary_payload.dart';

import '../support/fake_http.dart';

const _setId = '0b6f7c1e-8a52-4c1d-9a3e-3f1f0a000002';

Map<String, Object?> _card() => {
      'schema_version': '1.0.0', 'set_id': _setId, 'source': 'fallback', 'summary': 'Velocity loss passed your cap.',
      'cues': [{'text': 'Stop earlier.', 'metric_ref': 'velocity_loss_pct', 'metric_value': 24.4}],
      'focus_metric': 'velocity_loss_pct', 'focus_value': 24.4,
      'next_set': {'action': 'reduce_load', 'rest_seconds': 240, 'load_change_pct': -5.0, 'rule_id': 'vl_cap_exceeded'},
      'medical_notice': null, 'model': null, 'fallback_reason': 'llm_unavailable', 'generated_at': '2026-11-20T10:05:31Z',
    };

void main() {
  late FakeHttp http;
  late AppDatabase db;
  late SyncService sync;
  late SetRepository repo;
  late SetSummaryPayload payload;
  var now = DateTime.utc(2026, 11, 20, 10);

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    now = DateTime.utc(2026, 11, 20, 10);
    http = FakeHttp();
    final tokens = TokenStore(InMemorySecretStore({'settings.backend_url': 'http://api.test'}));
    await tokens.save(const TokenPair(accessToken: 'a', refreshToken: 'refresh-xxxxxxxxxxxxxxxx'));
    final api = MrFitApi(ApiClient(tokens: tokens, adapter: http));
    db = EncryptedDb.inMemoryForTests();
    sync = SyncService(db, api, now: () => now);
    repo = SetRepository(db, sync, now: () => now);
    payload = SetSummaryPayload.fromJson(jsonDecode(File('../contracts/fixtures/set_summary_fatigue.json').readAsStringSync()));
  });
  tearDown(() => db.close());

  Future<LocalSet> localSet() => (db.select(db.localSets)).getSingle();
  Future<List<OutboxItem>> outbox() => db.select(db.outbox).get();

  test('a saved set is stored locally first, then uploaded and coached; the queue empties', () async {
    http.reply('POST', '/sets', 201, {});
    http.reply('POST', '/sets/$_setId/coaching', 200, _card());
    await repo.saveCompletedSet(payload, athleteNote: 'felt heavy');
    final report = await sync.runOnce();

    expect(report.sent, 2);
    expect(http.seen.map((r) => r.path), ['/sets', '/sets/$_setId/coaching']);
    expect(http.seen.first.body, payload.toJson());
    expect(http.seen.last.body, {'athlete_note': 'felt heavy', 'force_regenerate': false});
    final s = await localSet();
    expect(s.syncState, SyncState.synced);
    expect((jsonDecode(s.coachingJson!) as Map)['next_set'], containsPair('rule_id', 'vl_cap_exceeded'));
    expect(await outbox(), isEmpty);
  });

  test('offline: the set stays pending, retries back off, and it syncs when due', () async {
    http.on('POST', '/sets', (_) async => (null, null));
    await repo.saveCompletedSet(payload);
    var report = await sync.runOnce();
    expect(report.stoppedReason, ApiErrorKind.network);
    expect((await localSet()).syncState, SyncState.pending);
    final waiting = (await outbox()).firstWhere((o) => o.kind == OutboxKind.setSummary);
    expect(waiting.attempts, 1);
    // drift returns local DateTimes; compare the instant in UTC.
    expect(waiting.nextAttemptAt.toUtc(), now.add(const Duration(seconds: 10)));
    expect(http.count('POST', '/sets/$_setId/coaching'), 0, reason: 'coaching waits for its set');

    now = now.add(const Duration(seconds: 5)); // not due yet
    report = await sync.runOnce();
    expect(http.count('POST', '/sets'), 1);

    http.reply('POST', '/sets', 201, {});
    http.reply('POST', '/sets/$_setId/coaching', 200, _card());
    now = now.add(const Duration(seconds: 6));
    report = await sync.runOnce();
    expect(report.sent, 2);
    expect((await localSet()).syncState, SyncState.synced);
  });

  test('a lost response is safe: the replay (200) also counts as stored', () async {
    http.reply('POST', '/sets', 200, {});
    await repo.saveCompletedSet(payload, requestCoaching: false);
    await sync.runOnce();
    expect((await localSet()).syncState, SyncState.synced);
  });

  test('a contract error is permanent: the set is marked failed and never resent', () async {
    http.reply('POST', '/sets', 422, {'detail': [{'loc': ['body', 'per_rep'], 'msg': 'bad', 'type': 'x'}]});
    await repo.saveCompletedSet(payload);
    final report = await sync.runOnce();
    expect(report.failed, 1);
    final s = await localSet();
    expect(s.syncState, SyncState.failed);
    expect(s.lastError, contains('422'));

    now = now.add(const Duration(days: 1));
    await sync.retryNow();
    expect(http.count('POST', '/sets'), 1);
    expect(http.count('POST', '/sets/$_setId/coaching'), 0);
  });

  test('signed out (refresh rejected): the pass stops and nothing is consumed', () async {
    http.reply('POST', '/sets', 401, {'detail': 'expired'});
    http.reply('POST', '/auth/refresh', 401, {'detail': 'Invalid refresh token'});
    await repo.saveCompletedSet(payload);
    final report = await sync.runOnce();
    expect(report.stoppedReason, ApiErrorKind.unauthorized);
    expect((await outbox()).every((o) => o.attempts == 0 && !o.dead), isTrue);
    expect((await localSet()).syncState, SyncState.pending);
  });

  test('server errors back off exponentially up to 15 minutes', () {
    expect(SyncService.backoff(1), const Duration(seconds: 10));
    expect(SyncService.backoff(2), const Duration(seconds: 20));
    expect(SyncService.backoff(4), const Duration(seconds: 80));
    expect(SyncService.backoff(20), const Duration(minutes: 15));
  });

  test('a 5xx on one set does not block the pass (unlike offline)', () async {
    http.reply('POST', '/sets', 503, {'detail': 'busy'});
    await repo.saveCompletedSet(payload, requestCoaching: false);
    final report = await sync.runOnce();
    expect(report.retryLater, 1);
    expect(report.stoppedReason, isNull);
  });

  test('saving the same set twice queues it once; concurrent passes share one upload', () async {
    final gate = Completer<void>();
    http.on('POST', '/sets', (_) async {
      await gate.future;
      return (201, <String, Object?>{});
    });
    await repo.saveCompletedSet(payload, requestCoaching: false);
    await repo.saveCompletedSet(payload, requestCoaching: false);
    final a = sync.runOnce();
    final b = sync.runOnce();
    gate.complete();
    await Future.wait([a, b]);
    expect(http.count('POST', '/sets'), 1);
    expect(await db.select(db.localSets).get(), hasLength(1));
  });

  test('an invalid payload is rejected before anything is stored', () async {
    final bad = SetSummaryPayload(
      setId: 'x', exercise: payload.exercise, goal: payload.goal, vlCapPct: payload.vlCapPct, setIndex: 1,
      repsCompleted: 3, loadKg: null, perRep: const [], mpvInitial: null, mpvFinal: null, velocityLossPct: null,
      vlCapExceeded: false, velocitySource: null, mqsScore: null, mqsBreakdown: null, symmetryIndex: null,
      faultCounts: payload.faultCounts, dataSource: payload.dataSource, deviceLabels: const ['Mock'],
      startedAt: null, endedAt: null);
    await expectLater(repo.saveCompletedSet(bad), throwsA(isA<ContractError>()));
    expect(await db.select(db.localSets).get(), isEmpty);
  });

  test('pending count follows the queue', () async {
    http.on('POST', '/sets', (_) async => (null, null));
    await repo.saveCompletedSet(payload);
    await sync.runOnce();
    expect(await repo.watchPendingCount().first, 2);
  });
}
