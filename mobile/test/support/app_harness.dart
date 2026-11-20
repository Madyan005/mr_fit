import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mr_fit/app/app.dart';
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/app/providers.dart';
import 'package:mr_fit/data/local/app_database.dart';
import 'package:mr_fit/data/local/encrypted_db.dart';
import 'package:mr_fit/data/storage/secret_store.dart';

import 'fake_http.dart';

/// Everything a widget test needs: fake backend, in-memory secrets and DB, no timers.
class AppHarness {
  AppHarness({Map<String, String>? secrets, this.mode = SourceMode.mock})
      : http = FakeHttp(),
        secrets = InMemorySecretStore({'settings.backend_url': 'http://api.test', ...?secrets}),
        db = EncryptedDb.inMemoryForTests() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  }

  final FakeHttp http;
  final InMemorySecretStore secrets;
  final AppDatabase db;
  final SourceMode mode;

  static const signedIn = {
    'auth.access_token': 'access-1',
    'auth.refresh_token': 'refresh-1-xxxxxxxxxxxxxxxx',
    'db.owner_email': 'me@example.com',
  };

  List<Override> get overrides => [
        ...sourceOverrides(mode),
        secretStoreProvider.overrideWithValue(secrets),
        appDatabaseProvider.overrideWithValue(db),
        httpAdapterProvider.overrideWithValue(http),
        syncAutoStartProvider.overrideWithValue(false),
      ];

  /// Pumps [child] (default: the whole app) and settles.
  Future<void> pump(WidgetTester tester, {Widget child = const MrFitApp()}) async {
    await tester.pumpWidget(ProviderScope(overrides: overrides, child: child));
    await tester.pumpAndSettle();
  }

  /// Unmounts the tree (cancels drift stream timers) and closes the DB.
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }
}
