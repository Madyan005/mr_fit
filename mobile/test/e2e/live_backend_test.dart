/// OPT-IN end-to-end test of the real client stack against a running MR-Fit API.
///
///   MRFIT_LIVE_API=http://127.0.0.1:8000 flutter test test/e2e/live_backend_test.dart
///
/// Use a throwaway server (LLM_BACKEND=fake, GEMINI_ENABLED=false, AI_COOLDOWN_SECONDS=0):
/// it creates a new account on every run. Skipped when MRFIT_LIVE_API is not set.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/data/api/api_client.dart';
import 'package:mr_fit/data/api/api_exception.dart';
import 'package:mr_fit/data/api/api_models.dart';
import 'package:mr_fit/data/api/mrfit_api.dart';
import 'package:mr_fit/data/auth/token_store.dart';
import 'package:mr_fit/data/local/app_database.dart';
import 'package:mr_fit/data/local/encrypted_db.dart';
import 'package:mr_fit/data/storage/secret_store.dart';
import 'package:mr_fit/data/sync/set_repository.dart';
import 'package:mr_fit/data/sync/sync_service.dart';
import 'package:mr_fit/domain/contracts/set_summary_payload.dart';
import 'package:uuid/uuid.dart';

void main() {
  final base = Platform.environment['MRFIT_LIVE_API'];

  test('client stack against a live API', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final secrets = InMemorySecretStore();
    final tokens = TokenStore(secrets);
    await tokens.setBaseUrl(base!);
    var expired = 0;
    final api = MrFitApi(ApiClient(tokens: tokens, onSessionExpired: () => expired++));
    ApiErrorKind? kindOf(Object e) => e is ApiException ? e.kind : null;

    expect(await api.health(base), isNotEmpty);

    // --- auth -------------------------------------------------------------------------
    final email = 'e2e-${const Uuid().v4().substring(0, 8)}@example.com';
    await api.signup(email, 'secret-pass-1');
    await expectLater(api.signup(email, 'secret-pass-1'), throwsA(predicate((e) => kindOf(e!) == ApiErrorKind.conflict)));
    await api.login(email.toUpperCase(), 'secret-pass-1');

    // --- logs, stats, heatmap (ported v1 routes) ----------------------------------------
    final log = await api.createLog(const LogDraft(type: LogType.exercise, name: 'Squat', sets: 3, reps: 5, weight: 100, sessionId: 's1'));
    expect(log.volume, 1500, reason: 'volume is computed by the server');
    final edited = await api.updateLog(log.id, const LogPatch(reps: 6));
    expect(edited.volume, 1800);
    await api.createLog(const LogDraft(type: LogType.nutrition, name: 'Oats', calories: 350));
    final today = await api.logsForDay(DateTime.now());
    expect(today.map((l) => l.name), containsAll(['Squat', 'Oats']));
    final heat = await api.heatmap();
    expect(heat[MrFitApi.utcDay(DateTime.now())]!.count, 2, reason: 'one session + one meal');
    final stats = await api.stats(days: 7);
    expect((stats.totalWorkouts, stats.totalMeals, stats.days.length), (1, 1, 7));
    await expectLater(api.createLog(const LogDraft(type: LogType.exercise, name: 'Bad', reps: 0)),
        throwsA(predicate((e) => kindOf(e!) == ApiErrorKind.invalid)));

    // --- exercise library ---------------------------------------------------------------
    final lib = await api.exercises();
    expect(lib.exercises.where((e) => !e.custom).length, 26);
    final custom = await api.addCustomExercise('E2E Press', lib.muscles.first, lib.equipmentTypes.first);
    await expectLater(api.addCustomExercise('e2e press', lib.muscles.first, lib.equipmentTypes.first),
        throwsA(predicate((e) => kindOf(e!) == ApiErrorKind.conflict)));
    await api.deleteCustomExercise(custom.id!);

    // --- optional Gemini parser is off on this server ------------------------------------
    await expectLater(api.parseEntry('3x5 squat 100kg'), throwsA(predicate((e) => kindOf(e!) == ApiErrorKind.unavailable)));

    // --- refresh: an invalid access token is refreshed once and the request retried -------
    final before = (await tokens.read())!;
    await tokens.save(TokenPair(accessToken: 'not-a-jwt', refreshToken: before.refreshToken));
    expect((await api.stats()).totalWorkouts, 1);
    final after = (await tokens.read())!;
    expect(after.refreshToken, isNot(before.refreshToken), reason: 'refresh tokens rotate');
    expect(expired, 0);

    // --- a set: encrypted DB -> queue -> POST /sets -> coaching -> GET /sets -------------------
    final dir = Directory.systemTemp.createTempSync('mrfit_e2e_');
    final opened = await EncryptedDb.open(dir, InMemorySecretStore());
    final AppDatabase db = opened.db;
    try {
      final sync = SyncService(db, api);
      final repo = SetRepository(db, sync);
      final fixture = (jsonDecode(File('../contracts/fixtures/set_summary_fatigue.json').readAsStringSync()) as Map)
          .cast<String, Object?>();
      final payload = SetSummaryPayload.fromJson({...fixture, 'set_id': const Uuid().v4()});
      await repo.saveCompletedSet(payload, athleteNote: 'felt slow at the end');
      final report = await sync.runOnce();
      expect((report.sent, report.failed, report.stoppedReason), (2, 0, null));
      final local = await db.select(db.localSets).getSingle();
      expect(local.syncState, SyncState.synced);
      final card = CoachingCard.fromJson(jsonDecode(local.coachingJson!));
      expect(card.nextSet.ruleId, isNotEmpty);
      expect(await api.uploadSet(payload.toJson()), SetUploadResult.replayed, reason: 'idempotent resend');

      final page = await api.sets();
      final stored = page.items.singleWhere((s) => s.setId == payload.setId);
      expect(stored.payload!.velocityLossPct, payload.velocityLossPct);
      expect(stored.coaching!.source, card.source);
    } finally {
      await db.close();
      dir.deleteSync(recursive: true);
    }

    // --- logout revokes the refresh family ---------------------------------------------
    final last = (await tokens.read())!;
    await api.logout();
    final replay = Dio();
    final r = await replay.post<Object?>('$base/auth/refresh',
        data: {'refresh_token': last.refreshToken}, options: Options(validateStatus: (_) => true));
    expect(r.statusCode, 401);
  }, skip: base == null ? 'set MRFIT_LIVE_API to run against a live server' : null, timeout: const Timeout(Duration(minutes: 2)));
}
