import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_root.dart';
import '../../app/bindings.dart';
import '../../app/providers.dart';
import '../widgets/simulated_banner.dart';

/// Settings: backend URL (read-only here; it is set at sign-in) and the developer
/// data-source switch between simulated and real sensor/vision bindings.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<void> _setMode(BuildContext context, WidgetRef ref, SourceMode mode) async {
    if (mode == ref.read(sourceModeProvider)) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    await ref.read(sourceModeSwitchProvider)(mode);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(sourceModeProvider);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Column(children: [
        const SimulatedBanner(),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Backend', style: t.titleMedium),
            FutureBuilder<String>(
              future: ref.read(tokenStoreProvider).baseUrl(),
              builder: (_, s) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.data ?? '…', key: const Key('settings.url')),
                subtitle: const Text('Change it by signing out and signing in again.'),
              ),
            ),
            const Divider(),
            Text('Data source (developer)', style: t.titleMedium),
            Text('Mock uses the simulated sensor, camera and clock offset. Real uses the hardware '
                'slots, which are not implemented in this prototype yet.', style: t.bodySmall),
            RadioGroup<SourceMode>(
              groupValue: mode,
              onChanged: (m) {
                if (m != null) _setMode(context, ref, m);
              },
              child: const Column(children: [
                RadioListTile<SourceMode>(
                    key: Key('settings.mock'), value: SourceMode.mock, title: Text('Mock (simulated)')),
                RadioListTile<SourceMode>(
                    key: Key('settings.real'), value: SourceMode.real, title: Text('Real hardware')),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
