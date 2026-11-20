import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'api_models.dart';

/// Result of `POST /sets`: 201 created or 200 identical replay (both mean "stored").
enum SetUploadResult { created, replayed }

/// Typed endpoints of the MR-Fit backend. Every method throws [ApiException] on failure.
class MrFitApi {
  MrFitApi(this._client);
  final ApiClient _client;

  Dio get _dio => _client.dio;
  TokenStore get _tokens => _client.tokens;

  Future<T> _call<T>(Future<Response<Object?>> Function() send, T Function(Object? data) parse) async {
    try {
      final r = await send();
      return parse(r.data);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    } on FormatException catch (e) {
      throw ApiException(ApiErrorKind.server, 'Unexpected server response: ${e.message}');
    }
  }

  static String utcDay(DateTime d) => d.toUtc().toIso8601String().substring(0, 10);

  // ---- auth -------------------------------------------------------------------------

  Future<void> signup(String email, String password) => _auth('/auth/signup', email, password);
  Future<void> login(String email, String password) => _auth('/auth/login', email, password);

  Future<void> _auth(String path, String email, String password) async {
    final pair = await _call(
      () async => _client.plain.post<Object?>('${await _tokens.baseUrl()}$path',
          data: {'email': email.trim(), 'password': password}),
      (d) => TokenPair.fromJson(asMap(d, 'token pair')),
    );
    await _tokens.save(pair);
  }

  /// Revokes this device's refresh-token family on the server (best effort) and always
  /// forgets the tokens locally.
  Future<void> logout() async {
    final t = await _tokens.read();
    try {
      if (t != null) {
        await _client.plain.post<Object?>('${await _tokens.baseUrl()}/auth/logout',
            data: {'refresh_token': t.refreshToken});
      }
    } on DioException {
      // Offline logout still signs out locally; the refresh token expires on its own.
    } finally {
      await _tokens.clear();
    }
  }

  /// `GET /health` on [baseUrl] (before saving it). Returns the server version.
  Future<String> health(String baseUrl) => _call(
        () => _client.plain.get<Object?>('${TokenStore.normalizeBaseUrl(baseUrl)}/health'),
        (d) => '${asMap(d, 'health')['version']}',
      );

  // ---- logs (ported v1 routes) ------------------------------------------------------

  Future<List<LogEntry>> logsForDay(DateTime day) => _call(
        () => _dio.get<Object?>('/logs', queryParameters: {'date': utcDay(day)}),
        (d) => [for (final x in asList(d, 'logs')) LogEntry.fromJson(x)],
      );

  Future<LogEntry> createLog(LogDraft draft) =>
      _call(() => _dio.post<Object?>('/logs', data: draft.toJson()), LogEntry.fromJson);

  Future<LogEntry> updateLog(int id, LogPatch patch) =>
      _call(() => _dio.put<Object?>('/logs/$id', data: patch.toJson()), LogEntry.fromJson);

  Future<void> deleteLog(int id) => _call(() => _dio.delete<Object?>('/logs/$id'), (_) {});

  Future<Map<String, HeatmapDay>> heatmap({int days = 90}) => _call(
        () => _dio.get<Object?>('/logs/heatmap', queryParameters: {'days': days}),
        HeatmapDay.parseAll,
      );

  Future<StatsSummary> stats({int days = 7}) =>
      _call(() => _dio.get<Object?>('/stats', queryParameters: {'days': days}), StatsSummary.fromJson);

  /// OPTIONAL Gemini parser. A 503 ([ApiErrorKind.unavailable]) here means the server has
  /// it switched off (GEMINI_ENABLED=false); the UI then offers manual entry.
  Future<List<Object?>> parseEntry(String text, {String? prefillExercise}) => _call(
        () => _dio.post<Object?>('/parse-entry', data: {'text': text, 'prefill_exercise': prefillExercise}),
        (d) => asList(d, 'parsed items'),
      );

  // ---- exercise library -------------------------------------------------------------

  Future<ExerciseLibrary> exercises() => _call(() => _dio.get<Object?>('/exercises'), ExerciseLibrary.fromJson);

  Future<ExerciseItem> addCustomExercise(String name, String muscle, String equipmentType) => _call(
        () => _dio.post<Object?>('/exercises/custom',
            data: {'name': name, 'muscle': muscle, 'equipment_type': equipmentType}),
        ExerciseItem.fromJson,
      );

  Future<void> deleteCustomExercise(int id) => _call(() => _dio.delete<Object?>('/exercises/custom/$id'), (_) {});

  // ---- biomechanical sets -----------------------------------------------------------

  /// Idempotent by `set_id`: a resend of the same payload returns 200.
  Future<SetUploadResult> uploadSet(Map<String, Object?> payload) async {
    try {
      final r = await _dio.post<Object?>('/sets', data: payload);
      return r.statusCode == 200 ? SetUploadResult.replayed : SetUploadResult.created;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<SetPage> sets({String? exercise, int limit = 50, String? before}) => _call(
        () => _dio.get<Object?>('/sets', queryParameters: {
          'limit': limit,
          'exercise': ?exercise,
          'before': ?before,
        }),
        SetPage.fromJson,
      );

  /// Idempotent: returns the stored card unless [forceRegenerate].
  Future<CoachingCard> coaching(String setId, {String? athleteNote, bool forceRegenerate = false}) async =>
      CoachingCard.fromJson(await coachingRaw(setId, athleteNote: athleteNote, forceRegenerate: forceRegenerate));

  /// Same as [coaching] but returns the validated card JSON (cached as-is in the local DB).
  Future<Map<String, Object?>> coachingRaw(String setId, {String? athleteNote, bool forceRegenerate = false}) =>
      _call(
        () => _dio.post<Object?>('/sets/$setId/coaching',
            data: {'athlete_note': athleteNote, 'force_regenerate': forceRegenerate}),
        (d) {
          final m = asMap(d, 'coaching card');
          CoachingCard.fromJson(m); // reject malformed cards before caching them
          return m;
        },
      );
}
