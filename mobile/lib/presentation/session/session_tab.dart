import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/bindings.dart';
import 'session_page.dart';

/// Entry tab for the 7-phase velocity-tracked session.
class SessionTab extends ConsumerWidget {
  const SessionTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final mock = ref.watch(anyMockActiveProvider);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Velocity-tracked session', style: t.headlineSmall),
      const SizedBox(height: 8),
      const Text('Connect the sensor, pick the exercise and goal, stand where the camera sees you, '
          'calibrate with three taps, then lift. Each set is measured, saved and coached.'),
      const SizedBox(height: 8),
      if (mock)
        Text('Mock mode: the sensor and camera are simulated with three demo sets '
            '(clean squat, fatigue bench press, valgus squat).', style: t.bodySmall),
      const SizedBox(height: 24),
      FilledButton.icon(
        key: const Key('session.open'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SessionPage())),
        icon: const Icon(Icons.play_circle_outline),
        label: const Text('Start session'),
      ),
    ]);
  }
}
