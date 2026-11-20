import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mr_fit/app/app_root.dart';
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/app/providers.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('the developer switch moves the whole app between Mock and Real, and remembers it', (tester) async {
    final h = AppHarness(secrets: AppHarness.signedIn);
    h.http.reply('GET', '/logs', 200, <Object?>[]);
    await tester.pumpWidget(AppRoot(
      secrets: h.secrets,
      db: h.db,
      initialMode: await readSourceMode(h.secrets),
      extraOverrides: [httpAdapterProvider.overrideWithValue(h.http), syncAutoStartProvider.overrideWithValue(false)],
    ));
    await tester.pumpAndSettle();
    expect(find.text('SIMULATED'), findsOneWidget, reason: 'mock is the default');

    await tester.tap(find.byKey(const Key('shell.settings')));
    await tester.pumpAndSettle();
    expect(find.text('http://api.test'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings.real')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shell.signout')), findsOneWidget, reason: 'still signed in after the rebuild');
    expect(find.text('SIMULATED'), findsNothing);
    expect(h.secrets.values['debug.source_mode'], 'real');
    expect(await readSourceMode(h.secrets), SourceMode.real);

    await tester.tap(find.byKey(const Key('shell.settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.mock')));
    await tester.pumpAndSettle();
    expect(find.text('SIMULATED'), findsOneWidget);
    expect(h.secrets.values['debug.source_mode'], 'mock');
    await h.dispose(tester);
  });
}
