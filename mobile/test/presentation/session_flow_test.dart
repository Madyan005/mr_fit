import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/app/session/session_providers.dart';
import 'package:mr_fit/core/clock.dart';
import 'package:mr_fit/domain/metrics/metrics_session.dart';
import 'package:mr_fit/domain/workout/workout_models.dart';
import 'package:mr_fit/presentation/session/session_page.dart';

import '../support/app_harness.dart';
import '../support/session_fakes.dart';

/// Phone clock on the widget-test binding's fake time.
class BindingClock implements MonotonicClock {
  BindingClock(this.tester);
  final WidgetTester tester;
  late final int _base = tester.binding.clock.now().microsecondsSinceEpoch;
  @override
  int nowNs() => (tester.binding.clock.now().microsecondsSinceEpoch - _base) * 1000;
}

Map<String, Object?> _card(String setId) => {
      'schema_version': '1.0.0', 'set_id': setId, 'source': 'fallback', 'summary': 'Clean set, keep the load.',
      'cues': [{'text': 'Same tempo next set.', 'metric_ref': null, 'metric_value': null}],
      'focus_metric': null, 'focus_value': null,
      'next_set': {'action': 'continue', 'rest_seconds': 90, 'load_change_pct': 0.0, 'rule_id': 'default'},
      'medical_notice': null, 'model': null, 'fallback_reason': 'llm_unavailable', 'generated_at': '2026-11-21T10:00:00Z',
    };

void main() {
  testWidgets('the 7 phases in the UI: connect, setup, positioning, taps, live HUD, rest with coaching', (tester) async {
    final cues = RecordingCues();
    final keep = RecordingKeepAlive();
    final h = AppHarness(secrets: AppHarness.signedIn, extra: [
      monotonicClockProvider.overrideWithValue(BindingClock(tester)),
      cueOutputProvider.overrideWithValue(cues),
      keepAliveProvider.overrideWithValue(keep),
      metricsSessionFactoryProvider.overrideWithValue(InlineMetricsSession.start),
    ]);
    h.http.reply('GET', '/logs', 200, <Object?>[]);
    h.http.reply('POST', '/sets', 201, <String, Object?>{});
    String? postedSetId;
    h.http.onPrefix('POST', '/sets/', (r) async {
      postedSetId = r.path.split('/')[2];
      return (200, _card(postedSetId!));
    });

    Future<void> pumpFor(Duration d, {Duration step = const Duration(milliseconds: 100)}) async {
      for (var t = Duration.zero; t < d; t += step) {
        await tester.pump(step);
      }
    }

    await h.pump(tester);
    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session.open')));
    await pumpFor(const Duration(milliseconds: 600));

    // 1 · connect
    expect(find.text('1 · Connect device'), findsOneWidget);
    expect(find.text('MockSensorSource (SIMULATED)'), findsOneWidget);
    expect(find.text('SIMULATED'), findsOneWidget, reason: 'banner stays visible in the session');
    expect(keep.running, isTrue);
    await tester.tap(find.byKey(const Key('pair.continue')));
    await pumpFor(const Duration(milliseconds: 300));

    // 2 · setup (demo scenario 1: clean squat)
    expect(find.text('2 · Exercise and goal'), findsOneWidget);
    expect(find.textContaining('Squat · Hypertrophy'), findsOneWidget);
    await tester.tap(find.byKey(const Key('setup.continue')));
    await pumpFor(const Duration(milliseconds: 500));

    // 3 · positioning, then automatically 4 · calibration
    expect(find.text('3 · Camera position'), findsOneWidget);
    expect(find.byKey(const Key('session.skeleton')), findsOneWidget);
    await pumpFor(const Duration(seconds: 6), step: const Duration(milliseconds: 250));
    expect(find.text('4 · Calibration'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('calibration.tap')));
      await pumpFor(const Duration(milliseconds: 400));
    }

    // 5 · live set
    expect(find.text('5 · Live set'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live.start')));
    await pumpFor(const Duration(seconds: 6), step: const Duration(milliseconds: 250));
    expect(int.parse(tester.widget<Text>(find.byKey(const Key('hud.reps'))).data!), greaterThan(0));
    expect(find.textContaining('m/s'), findsWidgets);
    for (var i = 0; i < 160 && find.text('7 · Rest and review').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // 7 · rest audit: summary, upload, coaching card, timer from the card
    expect(find.text('7 · Rest and review'), findsOneWidget);
    expect(find.textContaining('5 reps'), findsOneWidget);
    await pumpFor(const Duration(seconds: 2), step: const Duration(milliseconds: 200));
    expect(h.http.count('POST', '/sets'), 1);
    expect(postedSetId, isNotNull, reason: 'coaching requested after the upload');
    expect(find.text('Uploaded.'), findsOneWidget);
    expect(find.text('Rule-based feedback'), findsOneWidget);
    expect(find.textContaining('Recommended rest 90 s'), findsOneWidget);
    expect(cues.haptics, isNotEmpty);

    // Next set → setup with demo scenario 2 preselected; then end the session.
    await tester.ensureVisible(find.byKey(const Key('rest.next')));
    await tester.tap(find.byKey(const Key('rest.next')));
    await pumpFor(const Duration(milliseconds: 500));
    expect(find.textContaining('Bench Press · Max Strength'), findsOneWidget);
    await tester.tap(find.byKey(const Key('session.end')));
    await pumpFor(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('session.open')), findsOneWidget);
    expect(keep.running, isFalse);
    await h.dispose(tester);
  });

  testWidgets('real mode without hardware shows the reason, and Close leaves the session', (tester) async {
    final h = AppHarness(secrets: AppHarness.signedIn, mode: SourceMode.real, extra: [
      monotonicClockProvider.overrideWithValue(BindingClock(tester)),
      cueOutputProvider.overrideWithValue(RecordingCues()),
      keepAliveProvider.overrideWithValue(RecordingKeepAlive()),
    ]);
    h.http.reply('GET', '/logs', 200, <Object?>[]);
    await h.pump(tester);
    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session.demo')), findsNothing, reason: 'the scripted demo is Mock mode only');
    await tester.tap(find.byKey(const Key('session.open')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // page transition
    }
    expect(find.byKey(const Key('session.error')), findsOneWidget);
    expect(find.textContaining('Switch to Mock in Settings'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('pair.continue'))).onPressed, isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session.open')), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('"Run scripted demo" narrates the phases, advances by itself, and can be taken over', (tester) async {
    final h = AppHarness(secrets: AppHarness.signedIn, extra: [
      monotonicClockProvider.overrideWithValue(BindingClock(tester)),
      cueOutputProvider.overrideWithValue(RecordingCues()),
      keepAliveProvider.overrideWithValue(RecordingKeepAlive()),
      metricsSessionFactoryProvider.overrideWithValue(InlineMetricsSession.start),
    ]);
    h.http.reply('GET', '/logs', 200, <Object?>[]);
    await h.pump(tester);
    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session.demo')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('1 · Connect device'), findsOneWidget);
    expect(find.textContaining('Phase 1 · Connect.'), findsOneWidget);
    expect(find.textContaining('of about 6:40'), findsOneWidget);
    expect(find.text('SIMULATED'), findsOneWidget);

    for (var i = 0; i < 31; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('2 · Exercise and goal'), findsOneWidget, reason: 'Continue pressed by the runner at 0:30');
    expect(find.textContaining('Set 1: Squat, Hypertrophy'), findsOneWidget);
    expect(find.textContaining('0:31 of about 6:40'), findsOneWidget);

    await tester.tap(find.byKey(const Key('demo.stop')));
    await tester.pump();
    expect(find.text('Scripted demo · stopped'), findsOneWidget);
    expect(find.byKey(const Key('demo.stop')), findsNothing);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('2 · Exercise and goal'), findsOneWidget, reason: 'nothing advances after Take over');
    await tester.tap(find.byKey(const Key('session.end')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('session.open')), findsOneWidget);
    await h.dispose(tester);
  });

  test('default rest follows the rules table (D-036)', () {
    expect(defaultRestSeconds(Goal.maxStrength), 180);
    expect(defaultRestSeconds(Goal.hypertrophy), 90);
  });
}
