import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_database.dart';
import 'providers.dart';

enum SessionStatus { signedOut, signedIn }

final class SessionState {
  const SessionState(this.status, {this.email, this.notice});
  final SessionStatus status;
  final String? email;

  /// Shown on the sign-in screen (e.g. "Your session expired").
  final String? notice;
}

/// Thrown by [SessionNotifier.signIn] when this phone still holds unsynced sets of a
/// different account; the UI asks before calling again with `discardOtherAccountData`.
class OtherAccountDataPending implements Exception {
  const OtherAccountDataPending(this.ownerEmail, this.pendingSets);
  final String ownerEmail;
  final int pendingSets;
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

class SessionNotifier extends AsyncNotifier<SessionState> {
  static const _ownerKey = 'db.owner_email';
  static const expiredNotice = 'Your session expired. Please sign in again.';

  @override
  Future<SessionState> build() async {
    ref.watch(apiClientProvider).onSessionExpired = _expired;
    final tokens = await ref.watch(tokenStoreProvider).read();
    if (tokens == null) return const SessionState(SessionStatus.signedOut);
    final owner = await ref.read(secretStoreProvider).read(_ownerKey);
    _startSync();
    return SessionState(SessionStatus.signedIn, email: owner);
  }

  /// [signup] = create the account first. Saves [baseUrl] before calling the server.
  Future<void> signIn({
    required String baseUrl,
    required String email,
    required String password,
    bool signup = false,
    bool discardOtherAccountData = false,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final store = ref.read(secretStoreProvider);
    final owner = await store.read(_ownerKey);
    if (owner != null && owner != normalizedEmail) {
      final pending = await _unsyncedSetCount();
      if (pending > 0 && !discardOtherAccountData) throw OtherAccountDataPending(owner, pending);
    }

    await ref.read(tokenStoreProvider).setBaseUrl(baseUrl);
    final api = ref.read(apiProvider);
    if (signup) {
      await api.signup(normalizedEmail, password);
    } else {
      await api.login(normalizedEmail, password);
    }

    if (owner != normalizedEmail) {
      await _clearLocalData(); // never upload one account's sets under another account
      await store.write(_ownerKey, normalizedEmail);
    }
    state = AsyncData(SessionState(SessionStatus.signedIn, email: normalizedEmail));
    _startSync();
  }

  /// Local sets are kept: they upload when the same account signs in again.
  Future<void> signOut() async {
    ref.read(syncServiceProvider).stop();
    await ref.read(apiProvider).logout();
    state = const AsyncData(SessionState(SessionStatus.signedOut));
  }

  void _expired() {
    ref.read(syncServiceProvider).stop();
    state = const AsyncData(SessionState(SessionStatus.signedOut, notice: expiredNotice));
  }

  void _startSync() {
    if (ref.read(syncAutoStartProvider)) ref.read(syncServiceProvider).start();
  }

  Future<int> _unsyncedSetCount() async {
    final db = ref.read(appDatabaseProvider);
    final c = db.localSets.setId.count();
    final row = await (db.selectOnly(db.localSets)
          ..addColumns([c])
          ..where(db.localSets.syncState.equalsValue(SyncState.synced).not()))
        .getSingle();
    return row.read(c) ?? 0;
  }

  Future<void> _clearLocalData() async {
    final db = ref.read(appDatabaseProvider);
    await db.transaction(() async {
      await db.delete(db.outbox).go();
      await db.delete(db.localSets).go();
    });
  }
}
