import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/data/local/app_database.dart';
import 'package:mr_fit/data/local/encrypted_db.dart';
import 'package:mr_fit/data/storage/secret_store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Runs against the real SQLCipher build that package:sqlite3 ships for the host
/// (hooks.user_defines.sqlite3.source: sqlcipher), the same source as the Android build.
void main() {
  late Directory dir;
  const marker = 'PLAINTEXT-MARKER-squat-0b6f7c1e';

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() => dir = Directory.systemTemp.createTempSync('mrfit_db_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> writeMarker(AppDatabase db) => db.into(db.localSets).insert(LocalSetsCompanion.insert(
        setId: 's1', exercise: 'squat', payloadJson: jsonEncode({'note': marker}),
        createdAt: DateTime.utc(2026, 11, 20), syncState: SyncState.pending));

  test('the linked SQLite is SQLCipher', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final v = db.select('PRAGMA cipher_version;');
    expect(v, isNotEmpty);
    expect('${v.first.values.first}', isNotEmpty);
  });

  test('data on disk is encrypted and only opens with the right key', () async {
    final key = (await EncryptedDb.obtainKey(InMemorySecretStore(), random: Random(1))).keyHex;
    final file = File('${dir.path}/mrfit.db');
    final db = AppDatabase(EncryptedDb.fileExecutor(file, key));
    await writeMarker(db);
    await db.close();

    final bytes = file.readAsBytesSync();
    expect(ascii.decode(bytes.sublist(0, 15), allowInvalid: true), isNot('SQLite format 3'));
    expect(latin1.decode(bytes).contains(marker), isFalse);

    final again = AppDatabase(EncryptedDb.fileExecutor(file, key));
    expect((await again.select(again.localSets).getSingle()).payloadJson, contains(marker));
    await again.close();

    final wrongKey = 'ab' * 32;
    final raw = sqlite3.open(file.path);
    addTearDown(raw.close);
    expect(() => EncryptedDb.applyKey(raw, wrongKey), throwsA(isA<SqliteException>()));
  });

  test('the key is 256-bit hex, created once and then reused', () async {
    final store = InMemorySecretStore();
    final a = await EncryptedDb.obtainKey(store);
    final b = await EncryptedDb.obtainKey(store);
    expect(a.keyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(a.keyCreated, isTrue);
    expect(b.keyCreated, isFalse);
    expect(b.keyHex, a.keyHex);
  });

  test('if the key was lost, the unreadable file is moved aside (not deleted) and a fresh DB opens', () async {
    final store = InMemorySecretStore();
    final first = await EncryptedDb.open(dir, store);
    await writeMarker(first.db);
    await first.db.close();
    expect(first.movedAside, isNull);

    await store.delete(EncryptedDb.keyName); // e.g. secure storage reset after a Keystore error
    final second = await EncryptedDb.open(dir, store);
    expect(second.movedAside, isNotNull);
    expect(second.movedAside!.existsSync(), isTrue);
    expect(await second.db.select(second.db.localSets).get(), isEmpty);
    await second.db.close();
  });

  test('reopening with the stored key keeps the data', () async {
    final store = InMemorySecretStore();
    final first = await EncryptedDb.open(dir, store);
    await writeMarker(first.db);
    await first.db.close();
    final second = await EncryptedDb.open(dir, store);
    expect(second.movedAside, isNull);
    expect(await second.db.select(second.db.localSets).get(), hasLength(1));
    await second.db.close();
  });
}
