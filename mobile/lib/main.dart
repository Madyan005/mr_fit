import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_root.dart';
import 'data/local/encrypted_db.dart';
import 'data/storage/secret_store.dart';

/// Opens the encrypted local DB (key from the Android Keystore) before the first frame.
/// Mock mode is the default so the app runs on an emulator with no hardware; the
/// developer switch in Settings changes it (persisted).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final secrets = SecureSecretStore();
  final opened = await EncryptedDb.open(await getApplicationSupportDirectory(), secrets);
  runApp(AppRoot(
    secrets: secrets,
    db: opened.db,
    initialMode: await readSourceMode(secrets),
    startupNotice: opened.movedAside == null
        ? null
        : 'The local database could not be decrypted and was set aside; a new one was created.',
  ));
}
