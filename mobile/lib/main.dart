import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/bindings.dart';
import 'app/providers.dart';
import 'data/local/encrypted_db.dart';
import 'data/storage/secret_store.dart';

/// Opens the encrypted local DB (key from the Android Keystore) before the first frame.
/// Mock mode is the default so the app runs on an emulator with no hardware.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final secrets = SecureSecretStore();
  final opened = await EncryptedDb.open(await getApplicationSupportDirectory(), secrets);
  runApp(ProviderScope(
    overrides: [
      ...sourceOverrides(SourceMode.mock),
      secretStoreProvider.overrideWithValue(secrets),
      appDatabaseProvider.overrideWithValue(opened.db),
      if (opened.movedAside != null)
        startupNoticeProvider.overrideWithValue(
            'The local database could not be decrypted and was set aside; a new one was created.'),
    ],
    child: const MrFitApp(),
  ));
}
