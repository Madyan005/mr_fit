import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/main.dart';

void main() {
  testWidgets('app starts in mock mode and shows the SIMULATED banner', (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: sourceOverrides(SourceMode.mock), child: const MrFitApp()));
    expect(find.text('SIMULATED'), findsOneWidget);
    expect(find.text('MR-Fit 2.0'), findsOneWidget);
  });

  testWidgets('no banner when every binding is real', (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: sourceOverrides(SourceMode.real), child: const MrFitApp()));
    expect(find.text('SIMULATED'), findsNothing);
  });
}
