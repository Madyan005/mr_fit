import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/app/bindings.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('app starts in mock mode and shows the SIMULATED banner', (tester) async {
    final h = AppHarness();
    await h.pump(tester);
    expect(find.text('SIMULATED'), findsOneWidget);
    expect(find.text('MR-Fit'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('no banner when every binding is real', (tester) async {
    final h = AppHarness(mode: SourceMode.real);
    await h.pump(tester);
    expect(find.text('SIMULATED'), findsNothing);
    await h.dispose(tester);
  });
}
