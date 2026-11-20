import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app/bindings.dart';
import 'presentation/widgets/simulated_banner.dart';

/// Entry point. Mock mode is the default so the app runs on an emulator with no hardware.
/// Placeholder home screen until the ported screens land in step 5c.
void main() {
  runApp(ProviderScope(overrides: sourceOverrides(SourceMode.mock), child: const MrFitApp()));
}

class MrFitApp extends StatelessWidget {
  const MrFitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MR-Fit',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark)),
      home: Scaffold(
        appBar: AppBar(title: const Text('MR-Fit 2.0')),
        body: const Column(
          children: [
            SimulatedBanner(),
            Expanded(child: Center(child: Text('Screens arrive in step 5c'))),
          ],
        ),
      ),
    );
  }
}
