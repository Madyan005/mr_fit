import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';

Map<String, Object?> statsJson(int days, {bool empty = false}) => {
      'avg_volume': empty ? 0 : 1250,
      'avg_calories': empty ? 0 : 2100,
      'total_workouts': empty ? 0 : 9,
      'total_meals': empty ? 0 : 14,
      'days': [
        for (var i = 0; i < days; i++)
          {
            'date': '2026-11-${(21 - days + 1 + i).toString().padLeft(2, '0')}',
            'volume': empty ? 0.0 : 1000.0 + i,
            'calories': empty ? 0 : 2000 + i,
          },
      ],
    };

void main() {
  late AppHarness h;

  setUp(() {
    h = AppHarness(secrets: AppHarness.signedIn);
    h.http.reply('GET', '/logs', 200, <Object?>[]);
    h.http.on('GET', '/stats', (r) async => (200, statsJson(int.parse(r.query['days'] as String))));
  });

  Future<void> openStats(WidgetTester tester) async {
    await h.pump(tester);
    await tester.tap(find.text('Stats'));
    await tester.pumpAndSettle();
  }

  String pill(WidgetTester tester, String key) => (tester
          .widgetList<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)))
          .last)
      .data!;

  testWidgets('shows the four v1 summary values and both charts for the last 7 days', (tester) async {
    await openStats(tester);
    expect(h.http.seen.lastWhere((r) => r.path == '/stats').query['days'], '7');
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(pill(tester, 'stats.avgVolume'), '1250 kg');
    expect(pill(tester, 'stats.avgCalories'), '2100 kcal');
    expect(pill(tester, 'stats.workouts'), '9');
    expect(pill(tester, 'stats.meals'), '14');
    expect(find.byType(BarChart), findsOneWidget);
    await tester.scrollUntilVisible(find.byType(LineChart), 300, scrollable: find.byType(Scrollable).first);
    expect(find.byType(LineChart), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('range pills reload with ?days=30', (tester) async {
    await openStats(tester);
    await tester.tap(find.text('30d'));
    await tester.pumpAndSettle();
    expect(h.http.seen.lastWhere((r) => r.path == '/stats').query['days'], '30');
    expect(find.text('Last 30 days'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('no data: charts are replaced by the v1 hints', (tester) async {
    h.http.on('GET', '/stats', (r) async => (200, statsJson(7, empty: true)));
    await openStats(tester);
    expect(find.text('Log workouts to see your trend'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Log meals to see your trend'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.byType(BarChart), findsNothing);
    await h.dispose(tester);
  });
}
