import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../api/api_exception.dart';
import '../api/mrfit_api.dart';
import '../local/app_database.dart';

typedef WallClock = DateTime Function();

/// Outcome of one pass over the queue.
final class SyncReport {
  const SyncReport({this.sent = 0, this.retryLater = 0, this.failed = 0, this.stoppedReason});
  final int sent;
  final int retryLater;
  final int failed;

  /// Why the pass stopped early (offline, signed out), if it did.
  final ApiErrorKind? stoppedReason;
}

/// Sends queued work to the backend. Every request it makes is idempotent (`set_id`
/// keyed), so a resend after a lost response is always safe (spec 3.4.1, D-031/D-037).
///
/// Retry policy (D-065):
///  - transient (no response, 5xx, 429): attempts+1, wait min(10 s * 2^(n-1), 15 min);
///    "no response" also ends the pass because the next item would fail the same way;
///  - 401 after the refresh attempt: stop and keep everything for the next sign-in;
///  - 4xx contract/conflict errors: mark the item dead and the set failed (never resent).
class SyncService {
  SyncService(this._db, this._api, {WallClock? now}) : _now = now ?? DateTime.now;

  final AppDatabase _db;
  final MrFitApi _api;
  final WallClock _now;
  Future<SyncReport>? _running;
  Timer? _timer;

  static const baseDelay = Duration(seconds: 10);
  static const maxDelay = Duration(minutes: 15);

  static Duration backoff(int attempts) {
    final ms = baseDelay.inMilliseconds * pow(2, max(0, attempts - 1));
    return Duration(milliseconds: min(ms.toInt(), maxDelay.inMilliseconds));
  }

  /// One pass. Concurrent callers share the pass that is already running.
  Future<SyncReport> runOnce() => _running ??= _pass().whenComplete(() => _running = null);

  /// Periodic passes while the app runs (cheap when the queue is empty).
  void start({Duration every = const Duration(seconds: 30)}) {
    _timer ??= Timer.periodic(every, (_) => unawaited(runOnce()));
    unawaited(runOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// "Retry now" from the UI: make every waiting (not dead) item due immediately.
  Future<SyncReport> retryNow() async {
    await (_db.update(_db.outbox)..where((o) => o.dead.equals(false)))
        .write(OutboxCompanion(nextAttemptAt: Value(_now())));
    return runOnce();
  }

  Future<SyncReport> _pass() async {
    var sent = 0, later = 0, failed = 0;
    final due = await (_db.select(_db.outbox)
          ..where((o) => o.dead.equals(false) & o.nextAttemptAt.isSmallerOrEqualValue(_now()))
          ..orderBy([(o) => OrderingTerm.asc(o.id)]))
        .get();

    for (final item in due) {
      if (item.kind == OutboxKind.coaching && !await _setSynced(item.setId)) continue; // parent first
      try {
        await _send(item);
        await (_db.delete(_db.outbox)..where((o) => o.id.equals(item.id))).go();
        sent++;
      } on ApiException catch (e) {
        if (e.kind == ApiErrorKind.unauthorized) {
          return SyncReport(sent: sent, retryLater: later, failed: failed, stoppedReason: e.kind);
        }
        if (e.isTransient) {
          final attempts = item.attempts + 1;
          await (_db.update(_db.outbox)..where((o) => o.id.equals(item.id))).write(OutboxCompanion(
            attempts: Value(attempts),
            nextAttemptAt: Value(_now().add(backoff(attempts))),
            lastError: Value(e.message),
          ));
          later++;
          if (e.kind == ApiErrorKind.network) {
            return SyncReport(sent: sent, retryLater: later, failed: failed, stoppedReason: e.kind);
          }
        } else {
          await _markDead(item, e);
          failed++;
        }
      }
    }
    return SyncReport(sent: sent, retryLater: later, failed: failed);
  }

  Future<bool> _setSynced(String setId) async {
    final s = await (_db.select(_db.localSets)..where((t) => t.setId.equals(setId))).getSingleOrNull();
    return s?.syncState == SyncState.synced;
  }

  Future<void> _send(OutboxItem item) async {
    final body = (jsonDecode(item.body) as Map).cast<String, Object?>();
    switch (item.kind) {
      case OutboxKind.setSummary:
        await _api.uploadSet(body);
        await (_db.update(_db.localSets)..where((t) => t.setId.equals(item.setId)))
            .write(const LocalSetsCompanion(syncState: Value(SyncState.synced), lastError: Value(null)));
      case OutboxKind.coaching:
        final note = body['athlete_note'];
        final card = await _api.coachingRaw(item.setId, athleteNote: note is String ? note : null);
        await (_db.update(_db.localSets)..where((t) => t.setId.equals(item.setId)))
            .write(LocalSetsCompanion(coachingJson: Value(jsonEncode(card))));
    }
  }

  Future<void> _markDead(OutboxItem item, ApiException e) async {
    final reason = '${e.statusCode ?? ''} ${e.message}'.trim();
    await _db.transaction(() async {
      await (_db.update(_db.outbox)..where((o) => o.id.equals(item.id)))
          .write(OutboxCompanion(dead: const Value(true), lastError: Value(reason), attempts: Value(item.attempts + 1)));
      if (item.kind == OutboxKind.setSummary) {
        await (_db.update(_db.localSets)..where((t) => t.setId.equals(item.setId)))
            .write(LocalSetsCompanion(syncState: const Value(SyncState.failed), lastError: Value(reason)));
      }
    });
  }
}
