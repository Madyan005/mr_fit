import 'package:drift/drift.dart';

part 'app_database.g.dart';

enum SyncState { pending, synced, failed }

enum OutboxKind {
  /// `POST /sets` with the SetSummaryPayload JSON.
  setSummary,

  /// `POST /sets/{id}/coaching` once the set is on the server; body = {"athlete_note": ...}.
  coaching,
}

/// Sets recorded on this phone. Written BEFORE any network call (online-first, offline-safe).
@DataClassName('LocalSet')
class LocalSets extends Table {
  TextColumn get setId => text()();
  TextColumn get exercise => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get syncState => textEnum<SyncState>()();
  TextColumn get lastError => text().nullable()();

  /// Cached coaching card JSON once the server produced it.
  TextColumn get coachingJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {setId};
}

/// Retry queue. Rows are deleted when the server accepted them; [dead] rows failed
/// permanently (contract error, conflict) and are kept so the UI can show why.
@DataClassName('OutboxItem')
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind => textEnum<OutboxKind>()();
  TextColumn get setId => text().references(LocalSets, #setId)();
  TextColumn get body => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime()();
  TextColumn get lastError => text().nullable()();
  BoolColumn get dead => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
}

@DriftDatabase(tables: [LocalSets, Outbox])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async => customStatement('PRAGMA foreign_keys = ON'),
      );
}
