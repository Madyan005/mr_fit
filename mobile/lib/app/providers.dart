/// Data-layer wiring (API, local DB, sync). Separate from `bindings.dart`, which stays the
/// single place that swaps Mock <-> Real sensors/vision (spec 3.2).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/api/mrfit_api.dart';
import '../data/auth/token_store.dart';
import '../data/local/app_database.dart';
import '../data/storage/secret_store.dart';
import '../data/sync/set_repository.dart';
import '../data/sync/sync_service.dart';

/// Bound in `main.dart` (Keystore-backed) and in tests (in-memory).
final secretStoreProvider = Provider<SecretStore>((ref) => throw UnimplementedError('bind secretStoreProvider'));

/// Bound in `main.dart` after the encrypted DB is opened.
final appDatabaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('bind appDatabaseProvider'));

/// Null = dio's real HTTP adapter. Tests bind a fake backend here.
final httpAdapterProvider = Provider<HttpClientAdapter?>((ref) => null);

/// Periodic background sync. Widget tests switch it off to keep virtual time quiet.
final syncAutoStartProvider = Provider<bool>((ref) => true);

/// Shown once on the home screen (e.g. the DB had to be recreated at start-up).
final startupNoticeProvider = Provider<String?>((ref) => null);

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore(ref.watch(secretStoreProvider)));

final apiClientProvider = Provider<ApiClient>(
    (ref) => ApiClient(tokens: ref.watch(tokenStoreProvider), adapter: ref.watch(httpAdapterProvider)));

final apiProvider = Provider<MrFitApi>((ref) => MrFitApi(ref.watch(apiClientProvider)));

final syncServiceProvider = Provider<SyncService>((ref) {
  final s = SyncService(ref.watch(appDatabaseProvider), ref.watch(apiProvider));
  ref.onDispose(s.stop);
  return s;
});

final setRepositoryProvider =
    Provider<SetRepository>((ref) => SetRepository(ref.watch(appDatabaseProvider), ref.watch(syncServiceProvider)));

final pendingUploadsProvider = StreamProvider<int>((ref) => ref.watch(setRepositoryProvider).watchPendingCount());
