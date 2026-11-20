import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/secret_store.dart';
import 'app_database.dart';

/// Key handling and opening of the SQLCipher database (D-044, D-064).
///
/// The 256-bit key is random, stored only in the [SecretStore] (Android Keystore) and
/// passed to SQLCipher as a raw key (`x'..'`), so no passphrase derivation is needed.
class EncryptedDb {
  static const keyName = 'db.sqlcipher_key';

  /// Returns the stored key, or creates one. [keyCreated] tells the caller that any
  /// existing database file cannot belong to this key.
  static Future<({String keyHex, bool keyCreated})> obtainKey(SecretStore store, {Random? random}) async {
    final existing = await store.read(keyName);
    if (existing != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(existing)) {
      return (keyHex: existing, keyCreated: false);
    }
    final rng = random ?? Random.secure();
    final hex = [for (var i = 0; i < 32; i++) rng.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    await store.write(keyName, hex);
    return (keyHex: hex, keyCreated: true);
  }

  /// Applies the key and refuses to run on a SQLite build without SQLCipher, so the app
  /// can never silently write an unencrypted database. Runs on drift's isolate.
  static void applyKey(Database db, String keyHex) {
    db.execute('PRAGMA key = "x\'$keyHex\'";');
    final v = db.select('PRAGMA cipher_version;');
    if (v.isEmpty || '${v.first.values.first}'.isEmpty) {
      throw StateError('SQLCipher is not active: refusing to open an unencrypted database');
    }
    // Fails with "file is not a database" right here if the key does not match.
    db.select('SELECT count(*) FROM sqlite_master;');
  }

  /// Opens `<dir>/mrfit.db`. If the key had to be (re)created while a database file
  /// exists, or the file cannot be decrypted, that file is moved aside (never deleted)
  /// and a fresh database is created. Returns the moved file, if any, for logging.
  static Future<({AppDatabase db, File? movedAside})> open(Directory dir, SecretStore store) async {
    final file = File('${dir.path}${Platform.pathSeparator}mrfit.db');
    final key = await obtainKey(store);
    File? moved;
    if (key.keyCreated && file.existsSync()) {
      moved = _moveAside(file);
    } else if (file.existsSync() && !_canOpen(file, key.keyHex)) {
      moved = _moveAside(file);
    }
    final keyHex = key.keyHex;
    final executor = NativeDatabase.createInBackground(file, setup: (db) => applyKey(db, keyHex));
    return (db: AppDatabase(executor), movedAside: moved);
  }

  static bool _canOpen(File file, String keyHex) {
    final db = sqlite3.open(file.path);
    try {
      applyKey(db, keyHex);
      return true;
    } on SqliteException {
      return false;
    } finally {
      db.close();
    }
  }

  static File _moveAside(File file) {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    return file.renameSync('${file.path}.unreadable-$stamp');
  }

  /// Unencrypted in-memory database for widget tests only.
  static AppDatabase inMemoryForTests() => AppDatabase(NativeDatabase.memory());

  /// Encrypted executor for a given file (tests of the encryption itself).
  static QueryExecutor fileExecutor(File file, String keyHex) =>
      NativeDatabase(file, setup: (db) => applyKey(db, keyHex));
}
