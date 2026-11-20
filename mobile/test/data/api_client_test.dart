import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/data/api/api_client.dart';
import 'package:mr_fit/data/api/api_exception.dart';
import 'package:mr_fit/data/api/api_models.dart';
import 'package:mr_fit/data/api/mrfit_api.dart';
import 'package:mr_fit/data/auth/token_store.dart';
import 'package:mr_fit/data/storage/secret_store.dart';

import '../support/fake_http.dart';

void main() {
  late FakeHttp http;
  late InMemorySecretStore store;
  late TokenStore tokens;
  late ApiClient client;
  late MrFitApi api;
  var expired = 0;

  setUp(() {
    http = FakeHttp();
    store = InMemorySecretStore({'settings.backend_url': 'http://api.test:8000'});
    tokens = TokenStore(store);
    expired = 0;
    client = ApiClient(tokens: tokens, adapter: http, onSessionExpired: () => expired++);
    api = MrFitApi(client);
  });

  Map<String, Object?> log(int id) => {
        'id': id, 'user_id': 1, 'session_id': null, 'type': 'NUTRITION', 'name': 'Oats', 'sets': null,
        'reps': null, 'weight': null, 'calories': 300, 'volume': null, 'raw_text': '',
        'created_at': '2026-11-20T08:00:00',
      };

  group('auth', () {
    test('login stores the token pair and later requests carry the bearer token', () async {
      http.reply('POST', '/auth/login', 200, tokenJson('a1', 'r1-xxxxxxxxxxxxxxxxxxxx'));
      http.reply('GET', '/logs', 200, [log(1)]);
      await api.login(' Me@Example.com ', 'secret1');
      expect(store.values['auth.access_token'], 'a1');
      expect(http.seen.single.body, {'email': 'Me@Example.com', 'password': 'secret1'});

      final logs = await api.logsForDay(DateTime.utc(2026, 11, 20, 23));
      expect(logs.single.calories, 300);
      final get = http.seen.last;
      expect(get.bearer, 'a1');
      expect(get.query['date'], '2026-11-20');
    });

    test('a bad login is unauthorized and does not touch stored tokens', () async {
      http.reply('POST', '/auth/login', 401, {'detail': 'Invalid credentials'});
      await expectLater(api.login('a@b.c', 'wrong12'),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.unauthorized)
              .having((e) => e.message, 'message', 'Invalid credentials')));
      expect(await tokens.read(), isNull);
      expect(expired, 0);
    });

    test('logout revokes on the server and clears local tokens even when offline', () async {
      await tokens.save(const TokenPair(accessToken: 'a', refreshToken: 'r'));
      http.on('POST', '/auth/logout', (_) async => (null, null));
      await api.logout();
      expect(await tokens.read(), isNull);
      expect(http.count('POST', '/auth/logout'), 1);
    });
  });

  group('refresh on 401', () {
    setUp(() async => tokens.save(const TokenPair(accessToken: 'old', refreshToken: 'refresh-old-xxxxxxxxxx')));

    void protectedLogs() => http.on('GET', '/logs', (r) async => r.bearer == 'new' ? (200, [log(7)]) : (401, {'detail': 'expired'}));

    test('refreshes once, saves the rotated pair and retries the request', () async {
      protectedLogs();
      http.reply('POST', '/auth/refresh', 200, tokenJson('new', 'refresh-new-xxxxxxxxxx'));
      final logs = await api.logsForDay(DateTime.utc(2026, 11, 20));
      expect(logs.single.id, 7);
      expect(http.count('POST', '/auth/refresh'), 1);
      expect(http.seen.firstWhere((r) => r.path == '/auth/refresh').body, {'refresh_token': 'refresh-old-xxxxxxxxxx'});
      expect((await tokens.read())!.refreshToken, 'refresh-new-xxxxxxxxxx');
    });

    test('concurrent 401s share ONE refresh (reusing a rotated token would revoke the family)', () async {
      protectedLogs();
      final gate = Completer<void>();
      http.on('POST', '/auth/refresh', (_) async {
        await gate.future; // hold the refresh open while the other 401s arrive
        return (200, tokenJson('new', 'refresh-new-xxxxxxxxxx'));
      });
      final calls = [for (var i = 0; i < 3; i++) api.logsForDay(DateTime.utc(2026, 11, 20))];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      final results = await Future.wait(calls);
      expect(results.map((l) => l.single.id), [7, 7, 7]);
      expect(http.count('POST', '/auth/refresh'), 1);
    });

    test('a rejected refresh clears the session and reports unauthorized', () async {
      protectedLogs();
      http.reply('POST', '/auth/refresh', 401, {'detail': 'Invalid refresh token'});
      await expectLater(api.logsForDay(DateTime.utc(2026, 11, 20)),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.unauthorized)));
      expect(await tokens.read(), isNull);
      expect(store.values.containsKey('auth.refresh_token'), isFalse);
      expect(expired, 1);
    });

    test('a refresh that fails offline keeps the tokens (the user stays signed in)', () async {
      protectedLogs();
      http.on('POST', '/auth/refresh', (_) async => (null, null));
      await expectLater(api.logsForDay(DateTime.utc(2026, 11, 20)),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.network)));
      expect((await tokens.read())!.accessToken, 'old');
      expect(expired, 0);
    });

    test('a retry that is still 401 is not refreshed again (no loop)', () async {
      http.reply('GET', '/logs', 401, {'detail': 'nope'});
      http.reply('POST', '/auth/refresh', 200, tokenJson('new', 'refresh-new-xxxxxxxxxx'));
      await expectLater(api.logsForDay(DateTime.utc(2026, 11, 20)), throwsA(isA<ApiException>()));
      expect(http.count('POST', '/auth/refresh'), 1);
      expect(http.count('GET', '/logs'), 2);
    });
  });

  group('errors', () {
    setUp(() async => tokens.save(const TokenPair(accessToken: 'a', refreshToken: 'r')));

    test('no response is a transient network error', () async {
      http.on('GET', '/stats', (_) async => (null, null));
      final e = await api.stats().then<ApiException?>((_) => null, onError: (Object e) => e as ApiException);
      expect(e!.kind, ApiErrorKind.network);
      expect(e.isTransient, isTrue);
    });

    test('422 validation detail becomes a readable, non-transient message', () async {
      http.reply('POST', '/logs', 422, {
        'detail': [
          {'loc': ['body', 'reps'], 'msg': 'Value error, Sets/reps must be positive', 'type': 'value_error'}
        ]
      });
      final e = await api
          .createLog(const LogDraft(type: LogType.exercise, name: 'Squat', reps: 0))
          .then<ApiException?>((_) => null, onError: (Object e) => e as ApiException);
      expect(e!.kind, ApiErrorKind.invalid);
      expect(e.isTransient, isFalse);
      expect(e.message, 'reps: Value error, Sets/reps must be positive');
    });

    test('503 from the optional parser is reported as disabled', () async {
      http.reply('POST', '/parse-entry', 503, {'detail': 'Natural-language parsing is disabled on this server'});
      await expectLater(api.parseEntry('3x5 squat 100kg'),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.disabled)));
    });

    test('POST /sets distinguishes created (201) from an idempotent replay (200)', () async {
      http.reply('POST', '/sets', 201, {});
      expect(await api.uploadSet({'set_id': 'x'}), SetUploadResult.created);
      http.reply('POST', '/sets', 200, {});
      expect(await api.uploadSet({'set_id': 'x'}), SetUploadResult.replayed);
      http.reply('POST', '/sets', 409, {'detail': 'set_id already used with different data'});
      await expectLater(api.uploadSet({'set_id': 'x'}),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.conflict)));
    });
  });

  group('models', () {
    test('base URL is normalised and validated', () {
      expect(TokenStore.normalizeBaseUrl(' http://192.168.1.5:8000/ '), 'http://192.168.1.5:8000');
      expect(() => TokenStore.normalizeBaseUrl('192.168.1.5:8000'), throwsFormatException);
      expect(() => TokenStore.normalizeBaseUrl('ftp://x'), throwsFormatException);
    });

    test('timestamps without an offset are read as UTC', () {
      expect(parseServerTime('2026-11-20T08:00:00'), DateTime.utc(2026, 11, 20, 8));
      expect(parseServerTime('2026-11-20T10:00:00+02:00'), DateTime.utc(2026, 11, 20, 8));
    });

    test('a stored set with its coaching card parses, using the contract fixture', () {
      final fixture = jsonDecode(File('../contracts/fixtures/set_summary_fatigue.json').readAsStringSync());
      final rec = SetRecord.fromJson({
        'set_id': '0b6f7c1e-8a52-4c1d-9a3e-3f1f0a000002',
        'created_at': '2026-11-20T10:05:30Z',
        'log_id': 3,
        'payload': fixture,
        'coaching_source': 'fallback',
        'coaching': {
          'schema_version': '1.0.0', 'set_id': '0b6f7c1e-8a52-4c1d-9a3e-3f1f0a000002', 'source': 'fallback',
          'summary': 'Velocity loss passed your cap.',
          'cues': [{'text': 'Stop the set earlier.', 'metric_ref': 'velocity_loss_pct', 'metric_value': 24.4}],
          'focus_metric': 'velocity_loss_pct', 'focus_value': 24.4,
          'next_set': {'action': 'reduce_load', 'rest_seconds': 240, 'load_change_pct': -5.0, 'rule_id': 'vl_cap_exceeded'},
          'medical_notice': null, 'model': null, 'fallback_reason': 'llm_unavailable',
          'generated_at': '2026-11-20T10:05:31Z',
        },
      });
      expect(rec.payload!.velocityLossPct, 24.4);
      expect(rec.coaching!.source, CoachingSource.fallback);
      expect(rec.coaching!.cues.single.metricValue, 24.4);
      expect(rec.coaching!.nextSet.restSeconds, 240);
    });

    test('a payload from another contract version keeps the raw map instead of failing', () {
      final rec = SetRecord.fromJson({
        'set_id': 's', 'created_at': '2026-11-20T10:00:00Z', 'log_id': null, 'coaching': null,
        'coaching_source': null, 'payload': {'schema_version': '9.0.0', 'exercise': 'squat'},
      });
      expect(rec.payload, isNull);
      expect(rec.rawPayload['exercise'], 'squat');
    });

    test('heatmap details without user_id/raw_text parse', () {
      final days = HeatmapDay.parseAll({
        '2026-11-20': {
          'count': 2,
          'details': [
            {'id': 1, 'session_id': 's1', 'type': 'EXERCISE', 'name': 'Squat', 'sets': 1, 'reps': 5, 'weight': 100,
             'calories': null, 'volume': 500.0, 'created_at': '2026-11-20T08:00:00Z'},
          ],
        },
      });
      expect(days['2026-11-20']!.count, 2);
      expect(days['2026-11-20']!.details.single.weight, 100.0);
    });

    test('parsed Gemini items become drafts; non-positive sets/reps are dropped', () {
      final d = LogDraft.fromParsed({'type': 'EXERCISE', 'name': 'Bench', 'sets': 3, 'reps': 0, 'weight': 80},
          rawText: '3 sets bench 80kg', sessionId: 'S');
      expect(d.toJson(), {
        'type': 'EXERCISE', 'name': 'Bench', 'session_id': 'S', 'sets': 3, 'reps': null, 'weight': 80.0,
        'calories': null, 'raw_text': '3 sets bench 80kg',
      });
    });
  });
}
