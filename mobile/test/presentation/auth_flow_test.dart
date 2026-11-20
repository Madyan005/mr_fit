import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mr_fit/app/providers.dart';
import 'package:mr_fit/app/session.dart';
import 'package:mr_fit/data/local/app_database.dart';

import '../support/app_harness.dart';
import '../support/fake_http.dart';

void main() {
  Future<void> fill(WidgetTester tester, {String email = 'me@example.com', String password = 'secret1', String? url}) async {
    if (url != null) await tester.enterText(find.byKey(const Key('auth.url')), url);
    await tester.enterText(find.byKey(const Key('auth.email')), email);
    await tester.enterText(find.byKey(const Key('auth.password')), password);
    await tester.tap(find.byKey(const Key('auth.submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('login shows the four ported tabs and stores tokens + backend URL', (tester) async {
    final h = AppHarness();
    h.http.reply('POST', '/auth/login', 200, tokenJson('a1', 'r1-xxxxxxxxxxxxxxxxxxxx'));
    await h.pump(tester);
    expect(find.byKey(const Key('auth.url')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('auth.url'))).controller!.text, 'http://api.test');

    await fill(tester, email: 'Me@Example.com');
    for (final tab in ['Track', 'Library', 'Stats', 'Coach']) {
      expect(find.text(tab), findsWidgets);
    }
    expect(find.text('SIMULATED'), findsOneWidget);
    expect(h.secrets.values['auth.access_token'], 'a1');
    expect(h.secrets.values['db.owner_email'], 'me@example.com');
    expect(h.http.seen.first.body, {'email': 'me@example.com', 'password': 'secret1'});
    await h.dispose(tester);
  });

  testWidgets('sign up posts to /auth/signup and a server error is shown inline', (tester) async {
    final h = AppHarness();
    h.http.reply('POST', '/auth/signup', 409, {'detail': 'Email already registered'});
    await h.pump(tester);
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();
    await fill(tester);
    expect(find.text('Email already registered'), findsOneWidget);
    expect(h.http.count('POST', '/auth/signup'), 1);
    await h.dispose(tester);
  });

  testWidgets('client-side checks run before any request', (tester) async {
    final h = AppHarness();
    await h.pump(tester);
    await fill(tester, password: '123');
    expect(find.text('Password must be at least 6 characters'), findsOneWidget);
    await fill(tester, email: 'nobody');
    expect(find.text('Enter a valid email address'), findsOneWidget);
    await fill(tester, url: '192.168.1.5:8000');
    expect(find.text('Backend URL must look like http://host:port'), findsOneWidget);
    expect(h.http.seen, isEmpty);
    await h.dispose(tester);
  });

  testWidgets('an unreachable server gives a readable message', (tester) async {
    final h = AppHarness();
    h.http.on('POST', '/auth/login', (_) async => (null, null));
    await h.pump(tester);
    await fill(tester);
    expect(find.textContaining('Cannot reach the server'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('a saved session opens the app directly; sign out returns to login', (tester) async {
    final h = AppHarness(secrets: AppHarness.signedIn);
    h.http.reply('POST', '/auth/logout', 204);
    await h.pump(tester);
    expect(find.byKey(const Key('shell.signout')), findsOneWidget);
    await tester.tap(find.byKey(const Key('shell.signout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth.submit')), findsOneWidget);
    expect(h.secrets.values.containsKey('auth.access_token'), isFalse);
    expect(h.http.seen.singleWhere((r) => r.path == '/auth/logout').body, {'refresh_token': 'refresh-1-xxxxxxxxxxxxxxxx'});
    await h.dispose(tester);
  });

  testWidgets('another account with unsynced sets on the phone: confirm, then local data is cleared', (tester) async {
    final h = AppHarness(secrets: {'db.owner_email': 'first@example.com'});
    await h.db.into(h.db.localSets).insert(LocalSetsCompanion.insert(
        setId: 's1', exercise: 'squat', payloadJson: jsonEncode({}), createdAt: DateTime.utc(2026, 11, 20),
        syncState: SyncState.pending));
    h.http.reply('POST', '/auth/login', 200, tokenJson('a2', 'r2-xxxxxxxxxxxxxxxxxxxx'));
    await h.pump(tester);
    await fill(tester, email: 'second@example.com');
    expect(find.text('Unsynced sets on this phone'), findsOneWidget);
    expect(h.http.seen, isEmpty, reason: 'nothing is sent before the user decides');

    await tester.tap(find.text('Delete and continue'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shell.signout')), findsOneWidget);
    expect(await h.db.select(h.db.localSets).get(), isEmpty);
    expect(h.secrets.values['db.owner_email'], 'second@example.com');
    await h.dispose(tester);
  });

  testWidgets('an expired session (refresh rejected) returns to login with a notice', (tester) async {
    final h = AppHarness(secrets: AppHarness.signedIn);
    h.http.reply('GET', '/stats', 401, {'detail': 'expired'});
    h.http.reply('POST', '/auth/refresh', 401, {'detail': 'Invalid refresh token'});
    await h.pump(tester);
    final container = tester.element(find.byKey(const Key('shell.signout')));
    final api = ProviderScope.containerOf(container).read(apiProvider);
    await tester.runAsync(() async {
      try {
        await api.stats();
      } on Exception {
        // expected: unauthorized
      }
    });
    await tester.pumpAndSettle();
    expect(find.text(SessionNotifier.expiredNotice), findsOneWidget);
    await h.dispose(tester);
  });
}
