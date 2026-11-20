import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';

Map<String, Object?> logJson(int id, String type, String name,
        {String? session, int? sets, int? reps, num? weight, int? calories, num? volume}) =>
    {
      'id': id, 'user_id': 1, 'session_id': session, 'type': type, 'name': name, 'sets': sets, 'reps': reps,
      'weight': weight, 'calories': calories, 'volume': volume, 'raw_text': '', 'created_at': '2026-11-20T08:00:00Z',
    };

void main() {
  late AppHarness h;
  late List<Map<String, Object?>> serverLogs;

  setUp(() {
    h = AppHarness(secrets: AppHarness.signedIn);
    serverLogs = [
      logJson(1, 'EXERCISE', 'Squat', session: 's', sets: 1, reps: 5, weight: 100, volume: 500),
      logJson(2, 'EXERCISE', 'Squat', session: 's', sets: 1, reps: 5, weight: 102.5, volume: 512.5),
      logJson(3, 'NUTRITION', 'Oats', calories: 350),
      logJson(4, 'NUTRITION', 'Coffee', calories: 5),
    ];
    h.http.on('GET', '/logs', (_) async => (200, serverLogs));
  });

  testWidgets('shows today\'s totals and the v1 grouping (one card per exercise)', (tester) async {
    await h.pump(tester);
    expect(find.descendant(of: find.byKey(const Key('track.kcal')), matching: find.text('355')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('track.volume')), matching: find.text('1013')), findsOneWidget);
    expect(find.text('Squat'), findsOneWidget, reason: 'two Squat rows -> one group card');
    expect(find.text('1 × 5 @ 102.5 kg · 512.5 kg vol'), findsOneWidget);
    expect(find.text('Oats'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('"Log it" parses on the server, then saves each item with one session per exercise', (tester) async {
    h.http.reply('POST', '/parse-entry', 200, [
      {'type': 'EXERCISE', 'name': 'Bench Press', 'sets': 3, 'reps': 12, 'weight': 80},
      {'type': 'NUTRITION', 'name': 'Chicken salad', 'calories': 450},
    ]);
    var nextId = 10;
    h.http.on('POST', '/logs', (r) async {
      final b = r.body! as Map;
      final saved = logJson(nextId++, b['type'] as String, b['name'] as String,
          session: b['session_id'] as String?, sets: b['sets'] as int?, reps: b['reps'] as int?,
          weight: b['weight'] as num?, calories: b['calories'] as int?);
      serverLogs.add(saved);
      return (201, saved);
    });
    await h.pump(tester);
    await tester.enterText(find.byKey(const Key('track.input')), '3x12 bench 80kg and a chicken salad');
    await tester.tap(find.byKey(const Key('track.logit')));
    await tester.pumpAndSettle();

    final posts = h.http.seen.where((r) => r.method == 'POST' && r.path == '/logs').map((r) => r.body! as Map).toList();
    expect(posts, hasLength(2));
    expect(posts[0]['session_id'], isA<String>());
    expect(posts[1]['session_id'], isNull, reason: 'meals have no session');
    expect(posts.every((p) => p['raw_text'] == '3x12 bench 80kg and a chicken salad'), isTrue);
    expect(find.text('Logged: Bench Press, Chicken salad'), findsOneWidget);
    expect(find.text('Chicken salad'), findsOneWidget, reason: 'today\'s log reloaded');
    expect(h.http.count('GET', '/logs'), 2);
    await h.dispose(tester);
  });

  testWidgets('when the server has text parsing off, the user is pointed to manual entry', (tester) async {
    h.http.reply('POST', '/parse-entry', 503, {'detail': 'Natural-language parsing is disabled on this server (GEMINI_ENABLED=false)'});
    await h.pump(tester);
    await tester.enterText(find.byKey(const Key('track.input')), 'oats');
    await tester.tap(find.byKey(const Key('track.logit')));
    await tester.pumpAndSettle();
    expect(find.text('Text parsing is switched off on this server. Use "Add manually".'), findsOneWidget);
    expect(h.http.count('POST', '/logs'), 0);
    await h.dispose(tester);
  });

  testWidgets('manual entry in a bottom sheet validates like the server, then posts', (tester) async {
    h.http.reply('POST', '/logs', 201, logJson(20, 'EXERCISE', 'Deadlift', sets: 2, reps: 3, weight: 140, volume: 840));
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('track.manual')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('log.name')), 'Deadlift');
    await tester.enterText(find.byKey(const Key('log.sets')), '2');
    await tester.enterText(find.byKey(const Key('log.reps')), '0');
    await tester.tap(find.byKey(const Key('log.save')));
    await tester.pumpAndSettle();
    expect(find.text('Reps must be a whole number above 0'), findsOneWidget);
    expect(h.http.count('POST', '/logs'), 0);

    await tester.enterText(find.byKey(const Key('log.reps')), '3');
    await tester.enterText(find.byKey(const Key('log.weight')), '140');
    await tester.tap(find.byKey(const Key('log.save')));
    await tester.pumpAndSettle();
    final body = h.http.seen.singleWhere((r) => r.method == 'POST').body! as Map;
    expect(body, containsPair('name', 'Deadlift'));
    expect(body, containsPair('sets', 2));
    expect(body, containsPair('reps', 3));
    expect(body, containsPair('weight', 140.0));
    expect(body['session_id'], isA<String>());
    expect(find.byKey(const Key('log.save')), findsNothing, reason: 'sheet closed');
    await h.dispose(tester);
  });

  testWidgets('tapping an entry edits it in a sheet and sends only the changed field', (tester) async {
    h.http.reply('PUT', '/logs/2', 200, logJson(2, 'EXERCISE', 'Squat', sets: 1, reps: 6, weight: 102.5, volume: 615));
    await h.pump(tester);
    await tester.ensureVisible(find.text('Entry 2')); // below the fold at the 800x600 test size
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entry 2'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('log.weight'))).controller!.text, '102.5');
    await tester.enterText(find.byKey(const Key('log.reps')), '6');
    await tester.tap(find.byKey(const Key('log.save')));
    await tester.pumpAndSettle();
    expect(h.http.seen.singleWhere((r) => r.method == 'PUT').body, {'reps': 6});
    await h.dispose(tester);
  });

  testWidgets('the group menu deletes every entry of an exercise after confirmation', (tester) async {
    h.http.reply('DELETE', '/logs/1', 200, {'status': 'deleted'});
    h.http.reply('DELETE', '/logs/2', 200, {'status': 'deleted'});
    await h.pump(tester);
    await tester.ensureVisible(find.byKey(const Key('group.menu.Squat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group.menu.Squat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(h.http.seen.where((r) => r.method == 'DELETE').map((r) => r.path), ['/logs/1', '/logs/2']);
    await h.dispose(tester);
  });

  testWidgets('voice input fills the text box', (tester) async {
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('track.mic')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('track.input'))).controller!.text, '3 sets of 5 squats at 100 kg');
    await h.dispose(tester);
  });

  testWidgets('a failed load shows the error with Retry', (tester) async {
    h.http.on('GET', '/logs', (_) async => (null, null));
    await h.pump(tester);
    expect(find.textContaining('Cannot reach the server'), findsOneWidget);
    h.http.on('GET', '/logs', (_) async => (200, serverLogs));
    await tester.ensureVisible(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Oats'), findsOneWidget);
    await h.dispose(tester);
  });
}
