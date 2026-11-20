import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/api/api_models.dart';
import '../../data/local/app_database.dart';
import '../../domain/contracts/set_summary_payload.dart';

/// One set in the Coach history, from this phone's DB, the server, or both.
final class CoachEntry {
  const CoachEntry({
    required this.setId,
    required this.createdAt,
    required this.payload,
    required this.card,
    this.localState,
    this.localError,
  });
  final String setId;
  final DateTime createdAt;
  final SetSummaryPayload? payload;
  final CoachingCard? card;

  /// Null when the set is known only from the server.
  final SyncState? localState;
  final String? localError;
}

final localSetsProvider = StreamProvider.autoDispose<List<LocalSet>>((ref) => ref.watch(setRepositoryProvider).watchLocalSets());

final class ServerSets {
  const ServerSets(this.items, this.nextBefore);
  final List<SetRecord> items;
  final String? nextBefore;
}

final serverSetsProvider = AsyncNotifierProvider.autoDispose<ServerSetsNotifier, ServerSets>(ServerSetsNotifier.new);

class ServerSetsNotifier extends AsyncNotifier<ServerSets> {
  static const pageSize = 20;

  @override
  Future<ServerSets> build() async {
    final page = await ref.watch(apiProvider).sets(limit: pageSize);
    return ServerSets(page.items, page.nextBefore);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current?.nextBefore == null) return;
    final page = await ref.read(apiProvider).sets(limit: pageSize, before: current!.nextBefore);
    state = AsyncData(ServerSets([...current.items, ...page.items], page.nextBefore));
  }

  /// Asks the server for the card of a stored set (idempotent on the server).
  Future<void> requestCoaching(String setId) async {
    final card = await ref.read(apiProvider).coaching(setId);
    final current = state.value;
    if (current == null) return;
    state = AsyncData(ServerSets([
      for (final s in current.items)
        s.setId == setId
            ? SetRecord(setId: s.setId, createdAt: s.createdAt, rawPayload: s.rawPayload, payload: s.payload, coaching: card)
            : s,
    ], current.nextBefore));
  }
}

T? _tryParse<T>(String? json, T Function(Object?) parse) {
  if (json == null) return null;
  try {
    return parse(jsonDecode(json));
  } on FormatException {
    return null;
  }
}

/// Merges local and server sets by `set_id`, newest first. The server copy wins for the
/// payload; a coaching card from either side is shown.
List<CoachEntry> mergeCoachEntries(List<LocalSet> local, List<SetRecord> server) {
  final byId = <String, CoachEntry>{};
  for (final s in server) {
    byId[s.setId] = CoachEntry(setId: s.setId, createdAt: s.createdAt, payload: s.payload, card: s.coaching);
  }
  for (final l in local) {
    final fromServer = byId[l.setId];
    byId[l.setId] = CoachEntry(
      setId: l.setId,
      createdAt: fromServer?.createdAt ?? l.createdAt.toUtc(),
      payload: fromServer?.payload ?? _tryParse(l.payloadJson, SetSummaryPayload.fromJson),
      card: fromServer?.card ?? _tryParse(l.coachingJson, CoachingCard.fromJson),
      localState: l.syncState,
      localError: l.lastError,
    );
  }
  return byId.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}
