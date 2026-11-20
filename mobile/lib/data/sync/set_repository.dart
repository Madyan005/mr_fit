import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/contracts/set_summary_payload.dart';
import '../local/app_database.dart';
import 'sync_service.dart';

/// Entry point for finished sets: persist locally first, then let the queue sync them.
class SetRepository {
  SetRepository(this._db, this._sync, {WallClock? now}) : _now = now ?? DateTime.now;

  final AppDatabase _db;
  final SyncService _sync;
  final WallClock _now;

  /// Validates the payload against the contract, stores it encrypted, queues the upload
  /// (and, if [requestCoaching], the coaching request) in ONE transaction, then starts a
  /// sync pass without waiting for it. Saving the same `set_id` twice is a no-op.
  Future<void> saveCompletedSet(SetSummaryPayload payload, {bool requestCoaching = true, String? athleteNote}) async {
    payload.validate();
    final now = _now();
    await _db.transaction(() async {
      final exists = await (_db.select(_db.localSets)..where((t) => t.setId.equals(payload.setId))).getSingleOrNull();
      if (exists != null) return;
      await _db.into(_db.localSets).insert(LocalSetsCompanion.insert(
            setId: payload.setId,
            exercise: payload.exercise.wire,
            payloadJson: jsonEncode(payload.toJson()),
            createdAt: now,
            syncState: SyncState.pending,
          ));
      await _db.into(_db.outbox).insert(OutboxCompanion.insert(
            kind: OutboxKind.setSummary,
            setId: payload.setId,
            body: jsonEncode(payload.toJson()),
            nextAttemptAt: now,
            createdAt: now,
          ));
      if (requestCoaching) {
        await _db.into(_db.outbox).insert(OutboxCompanion.insert(
              kind: OutboxKind.coaching,
              setId: payload.setId,
              body: jsonEncode({'athlete_note': athleteNote}),
              nextAttemptAt: now,
              createdAt: now,
            ));
      }
    });
    unawaited(_sync.runOnce());
  }

  /// One stored set (sync state and, once the server answered, its coaching card).
  Stream<LocalSet?> watchLocalSet(String setId) =>
      (_db.select(_db.localSets)..where((t) => t.setId.equals(setId))).watchSingleOrNull();

  /// Newest first.
  Stream<List<LocalSet>> watchLocalSets() =>
      (_db.select(_db.localSets)..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  /// Number of queue items still waiting to be sent (excludes permanent failures).
  Stream<int> watchPendingCount() {
    final c = _db.outbox.id.count();
    return (_db.selectOnly(_db.outbox)
          ..addColumns([c])
          ..where(_db.outbox.dead.equals(false)))
        .map((r) => r.read(c) ?? 0)
        .watchSingle();
  }
}
