import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:material_ui/material_ui.dart';

import '../data/local/app_database.dart';
import '../data/storage/secret_store.dart';
import 'app.dart';
import 'bindings.dart';
import 'providers.dart';

/// Switches the whole app between Mock and Real bindings (Settings → Data source).
typedef SourceModeSwitch = Future<void> Function(SourceMode mode);

final sourceModeSwitchProvider =
    Provider<SourceModeSwitch>((ref) => throw UnimplementedError('bind sourceModeSwitchProvider'));

const _modeKey = 'debug.source_mode';

/// Mock is the default (the prototype has no sensor hardware yet).
Future<SourceMode> readSourceMode(SecretStore store) async =>
    (await store.read(_modeKey)) == SourceMode.real.name ? SourceMode.real : SourceMode.mock;

/// Owns the data-source mode. Changing it rebuilds the ProviderScope with the other
/// binding set (bindings.dart), so every sensor/vision/time-sync provider starts fresh;
/// the encrypted DB and the secret store are the same instances.
class AppRoot extends StatefulWidget {
  const AppRoot({
    super.key,
    required this.secrets,
    required this.db,
    required this.initialMode,
    this.startupNotice,
    this.extraOverrides = const [],
  });

  final SecretStore secrets;
  final AppDatabase db;
  final SourceMode initialMode;
  final String? startupNotice;

  /// Tests only (fake backend, no background sync).
  final List<Override> extraOverrides;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late SourceMode _mode = widget.initialMode;

  Future<void> _switch(SourceMode mode) async {
    await widget.secrets.write(_modeKey, mode.name);
    if (mounted && mode != _mode) setState(() => _mode = mode);
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
        key: ValueKey(_mode),
        retry: noAutoRetry,
        overrides: [
          ...sourceOverrides(_mode),
          secretStoreProvider.overrideWithValue(widget.secrets),
          appDatabaseProvider.overrideWithValue(widget.db),
          sourceModeSwitchProvider.overrideWithValue(_switch),
          if (widget.startupNotice != null) startupNoticeProvider.overrideWithValue(widget.startupNotice),
          ...widget.extraOverrides,
        ],
        child: const MrFitApp(),
      );
}
