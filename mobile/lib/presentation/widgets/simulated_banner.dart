import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/bindings.dart';

/// Visible whenever any mock (sensor, vision, time sync) is bound (spec 3.2).
class SimulatedBanner extends ConsumerWidget {
  const SimulatedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(anyMockActiveProvider)) return const SizedBox.shrink();
    return Semantics(
      label: 'Simulated data: sensors and vision are mocked',
      child: Container(
        width: double.infinity,
        color: Colors.amber.shade700,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: const Text(
          'SIMULATED',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 2),
        ),
      ),
    );
  }
}
