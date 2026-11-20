import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mr_fit/data/api/mrfit_api.dart';
import 'package:mr_fit/presentation/library/activity_heatmap.dart';
import 'package:mr_fit/presentation/library/quick_log_sheet.dart';

import '../support/app_harness.dart';
import 'track_screen_test.dart' show logJson;

Map<String, Object?> libraryJson({bool withCustom = true}) => {
      'muscles': ['Chest', 'Legs'],
      'equipment_types': ['Barbell', 'Dumbbell'],
      'exercises': [
        {'name': 'Bench Press', 'muscle': 'Chest', 'equipment_type': 'Barbell', 'biomech_key': 'bench_press', 'custom': false},
        {'name': 'Squat', 'muscle': 'Legs', 'equipment_type': 'Barbell', 'biomech_key': 'squat', 'custom': false},
        if (withCustom)
          {'name': 'Goblet Squat', 'muscle': 'Legs', 'equipment_type': 'Dumbbell', 'custom': true, 'id': 5,
           'created_at': '2026-11-20T08:00:00Z'},
      ],
    };

void main() {
  late AppHarness h;
  final today = MrFitApi.utcDay(DateTime.now());

  setUp(() {
    h = AppHarness(secrets: AppHarness.signedIn);
    h.http.reply('GET', '/logs', 200, <Object?>[]);
    h.http.reply('GET', '/exercises', 200, libraryJson());
    h.http.reply('GET', '/logs/heatmap', 200, {
      today: {'count': 3, 'details': [logJson(9, 'EXERCISE', 'Squat', session: 'x', sets: 1, reps: 5, weight: 100, volume: 500)]},
    });
  });

  Future<void> openLibrary(WidgetTester tester) async {
    await h.pump(tester);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the library and filters by muscle and by search text', (tester) async {
    await openLibrary(tester);
    expect(find.byKey(const Key('lib.ex.Bench Press')), findsOneWidget);
    expect(find.byKey(const Key('lib.ex.Goblet Squat')), findsOneWidget);

    await tester.tap(find.byKey(const Key('lib.muscle.Legs')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lib.ex.Bench Press')), findsNothing);
    expect(find.byKey(const Key('lib.ex.Squat')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('lib.search')), 'gob');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lib.ex.Squat')), findsNothing);
    expect(find.byKey(const Key('lib.ex.Goblet Squat')), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('adds a custom exercise on the server; a duplicate shows the server message', (tester) async {
    h.http.reply('POST', '/exercises/custom', 409, {'detail': 'Exercise already exists'});
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('lib.addcustom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('custom.name')), '  Hip   Thrust ');
    await tester.tap(find.byKey(const Key('custom.save')));
    await tester.pumpAndSettle();
    expect(find.text('Exercise already exists'), findsOneWidget);
    expect(h.http.seen.last.body, {'name': 'Hip Thrust', 'muscle': 'Chest', 'equipment_type': 'Barbell'});

    h.http.reply('POST', '/exercises/custom', 201,
        {'name': 'Hip Thrust', 'muscle': 'Chest', 'equipment_type': 'Barbell', 'custom': true, 'id': 6});
    await tester.tap(find.byKey(const Key('custom.save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('custom.save')), findsNothing, reason: 'sheet closed');
    expect(h.http.count('GET', '/exercises'), 2, reason: 'library reloaded');
    await h.dispose(tester);
  });

  testWidgets('removes a custom exercise (built-in ones have no delete button)', (tester) async {
    h.http.reply('DELETE', '/exercises/custom/5', 200, {'status': 'deleted'});
    await openLibrary(tester);
    expect(find.byKey(const Key('lib.delete.Squat')), findsNothing);
    await tester.tap(find.byKey(const Key('lib.delete.Goblet Squat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(h.http.count('DELETE', '/exercises/custom/5'), 1);
    await h.dispose(tester);
  });

  testWidgets('quick log saves one row per set with a shared session id', (tester) async {
    var id = 30;
    h.http.on('POST', '/logs', (r) async => (201, logJson(id++, 'EXERCISE', 'Squat', sets: 1, reps: 5)));
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('lib.ex.Squat')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('quick.reps.0')), '5');
    await tester.enterText(find.byKey(const Key('quick.weight.0')), '100');
    await tester.tap(find.byKey(const Key('quick.addset')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('quick.reps.1')), '4');
    await tester.tap(find.byKey(const Key('quick.save')));
    await tester.pumpAndSettle();

    final posts = h.http.seen.where((r) => r.method == 'POST').map((r) => r.body! as Map).toList();
    expect(posts, hasLength(2));
    expect(posts.map((p) => (p['reps'], p['weight'], p['sets'])), [(5, 100.0, 1), (4, null, 1)]);
    expect(posts[0]['session_id'], posts[1]['session_id']);
    expect(posts[0]['raw_text'], 'Quick log: 1 set');
    await h.dispose(tester);
  });

  testWidgets('"log by voice" hands the exercise to Track as a prefill', (tester) async {
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('lib.ex.Bench Press')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick.voice')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('track.prefill')), findsOneWidget);
    expect(find.text('Logging: Bench Press · add reps & weight'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('heatmap: tapping today opens that day\'s entries', (tester) async {
    await openLibrary(tester);
    final todaySquare = find.byKey(Key('heat.$today'));
    // The heatmap sits below the exercise list; the lazy ListView builds it only when scrolled to.
    await tester.scrollUntilVisible(todaySquare, 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(todaySquare);
    await tester.pumpAndSettle();
    expect(find.text(today), findsOneWidget);
    expect(find.text('1 × 5 @ 100 kg · 500 kg vol'), findsOneWidget);
    await h.dispose(tester);
  });

  test('heatmap buckets and day keys follow v1', () {
    expect([0, 1, 2, 3, 4, 5, 9].map(heatmapIntensity), [0, 1, 1, 2, 2, 3, 3]);
    final days = heatmapDays(DateTime.utc(2026, 3, 1, 23, 59));
    expect(days, hasLength(90));
    expect(days.last, '2026-03-01');
    expect(days[days.length - 2], '2026-02-28');
  });

  test('quick-log rows: reps are required per filled row, empty rows are skipped', () {
    expect(parseQuickLogRows([('5', '100'), ('', ''), ('3', '')]).rows, [(reps: 5, weight: 100.0), (reps: 3, weight: null)]);
    expect(parseQuickLogRows([('', '60')]).error, 'Set 1: reps must be a whole number above 0');
    expect(parseQuickLogRows([('', '')]).error, 'Add at least one set');
  });
}
