import 'package:dio/dio.dart';

import '../auth/token_store.dart';

/// Dio wrapper: base URL from Settings, Bearer token on every request, and ONE
/// refresh-and-retry when a request comes back 401.
///
/// Refresh must be single-flight: the backend rotates refresh tokens and treats a reused
/// one as theft (it revokes the whole token family, D-031). [QueuedInterceptor] handles
/// errors one at a time, and a queued 401 whose token was already replaced is simply
/// retried with the new token instead of refreshing again.
class ApiClient {
  ApiClient({
    required this.tokens,
    HttpClientAdapter? adapter,
    this.onSessionExpired,
    Duration connectTimeout = const Duration(seconds: 8),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) {
    final base = BaseOptions(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
    );
    dio = Dio(base);
    _plain = Dio(base);
    if (adapter != null) {
      dio.httpClientAdapter = adapter;
      _plain.httpClientAdapter = adapter;
    }
    dio.interceptors.add(_AuthInterceptor(this));
  }

  final TokenStore tokens;

  /// Called after a refresh is rejected (tokens are already cleared): show the login screen.
  void Function()? onSessionExpired;

  /// Authenticated client used by [MrFitApi].
  late final Dio dio;

  /// No interceptors: auth endpoints, the token refresh and the single retry go here
  /// (retrying through [dio] from inside its own error queue would deadlock).
  late final Dio _plain;

  Dio get plain => _plain;

  static const _extraRetried = 'mrfit.retried';
  static const _extraToken = 'mrfit.token';

  static bool _isAuthPath(String path) => path.startsWith('/auth/');

  /// POST /auth/refresh with the stored refresh token. Returns the new access token,
  /// null if the server rejected the refresh token (session over). Network errors throw.
  Future<String?> _refresh() async {
    final current = await tokens.read();
    if (current == null) return null;
    try {
      final r = await _plain.post<Object?>('${await tokens.baseUrl()}/auth/refresh',
          data: {'refresh_token': current.refreshToken});
      final pair = TokenPair.fromJson((r.data! as Map).cast<String, Object?>());
      await tokens.save(pair);
      return pair.accessToken;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 422) {
        await tokens.clear();
        onSessionExpired?.call();
        return null;
      }
      rethrow;
    }
  }
}

class _AuthInterceptor extends QueuedInterceptor {
  _AuthInterceptor(this._c);
  final ApiClient _c;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    options.baseUrl = await _c.tokens.baseUrl();
    if (!ApiClient._isAuthPath(options.path)) {
      final t = await _c.tokens.read();
      if (t != null) {
        options.headers['Authorization'] = 'Bearer ${t.accessToken}';
        options.extra[ApiClient._extraToken] = t.accessToken;
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final req = err.requestOptions;
    final eligible = err.response?.statusCode == 401 &&
        !ApiClient._isAuthPath(req.path) &&
        req.extra[ApiClient._extraRetried] != true;
    if (!eligible) return handler.next(err);

    try {
      final current = await _c.tokens.read();
      if (current == null) return handler.next(err);
      // Another queued request already refreshed: reuse its token, never refresh twice.
      final usedToken = req.extra[ApiClient._extraToken];
      final newToken = usedToken != current.accessToken ? current.accessToken : await _c._refresh();
      if (newToken == null) return handler.next(err);

      req.extra[ApiClient._extraRetried] = true;
      req.extra[ApiClient._extraToken] = newToken;
      req.headers['Authorization'] = 'Bearer $newToken';
      handler.resolve(await _c._plain.fetch<Object?>(req));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
