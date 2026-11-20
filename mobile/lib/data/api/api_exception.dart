import 'package:dio/dio.dart';

enum ApiErrorKind {
  /// No response (offline, DNS, timeout). Safe to retry later.
  network,

  /// 401 after the refresh attempt: the session is over.
  unauthorized,

  /// 409.
  conflict,

  /// 422 / 400: the request itself is wrong; retrying the same body never helps.
  invalid,

  /// 404.
  notFound,

  /// 429 cooldown.
  rateLimited,

  /// 503: the service is temporarily unavailable, or (for `/parse-entry` only) the optional
  /// feature is switched off on this server. Retryable; the caller decides what it means.
  unavailable,

  /// 5xx and anything else unexpected. Retryable.
  server,
}

class ApiException implements Exception {
  const ApiException(this.kind, this.message, {this.statusCode});
  final ApiErrorKind kind;
  final String message;
  final int? statusCode;

  /// Worth retrying the identical request later (used by the sync queue).
  bool get isTransient => switch (kind) {
        ApiErrorKind.network || ApiErrorKind.server || ApiErrorKind.rateLimited || ApiErrorKind.unavailable => true,
        _ => false,
      };

  factory ApiException.fromDio(DioException e) {
    final r = e.response;
    if (r == null) {
      return const ApiException(ApiErrorKind.network, 'Cannot reach the server. Check the backend URL and your connection.');
    }
    final code = r.statusCode ?? 0;
    final msg = detailMessage(r.data) ?? 'HTTP $code';
    final kind = switch (code) {
      401 => ApiErrorKind.unauthorized,
      404 => ApiErrorKind.notFound,
      409 => ApiErrorKind.conflict,
      400 || 413 || 422 => ApiErrorKind.invalid,
      429 => ApiErrorKind.rateLimited,
      503 => ApiErrorKind.unavailable,
      _ => ApiErrorKind.server,
    };
    return ApiException(kind, msg, statusCode: code);
  }

  /// FastAPI errors: `{"detail": "text"}` or `{"detail": [{"loc": [...], "msg": "..."}]}`.
  static String? detailMessage(Object? data) {
    if (data is! Map) return null;
    final d = data['detail'];
    if (d is String) return d;
    if (d is List && d.isNotEmpty && d.first is Map) {
      final first = d.first as Map;
      final loc = first['loc'];
      final field = loc is List && loc.isNotEmpty ? '${loc.last}: ' : '';
      return '$field${first['msg']}';
    }
    return null;
  }

  @override
  String toString() => 'ApiException($kind, $statusCode, $message)';
}
