import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Recorded request seen by [FakeHttp].
class SeenRequest {
  SeenRequest(this.method, this.path, this.query, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, dynamic> query;
  final Map<String, dynamic> headers;
  final Object? body;
  String? get bearer {
    final a = headers['Authorization'];
    return a is String && a.startsWith('Bearer ') ? a.substring(7) : null;
  }
}

/// (status, json body). A null status simulates "no response" (connection error).
typedef FakeReply = (int?, Object?);
typedef FakeHandler = Future<FakeReply> Function(SeenRequest req);

/// In-process stand-in for the backend: route by "METHOD /path" (path without host).
class FakeHttp implements HttpClientAdapter {
  final Map<String, FakeHandler> _routes = {};
  final List<SeenRequest> seen = [];

  void on(String method, String path, FakeHandler handler) => _routes['$method $path'] = handler;

  void reply(String method, String path, int status, [Object? body]) => on(method, path, (_) async => (status, body));

  int count(String method, String path) => seen.where((r) => r.method == method && r.path == path).length;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final uri = options.uri;
    final req = SeenRequest(options.method, uri.path, uri.queryParameters, Map.of(options.headers), options.data);
    seen.add(req);
    final h = _routes['${options.method} ${uri.path}'];
    if (h == null) {
      return ResponseBody.fromString(jsonEncode({'detail': 'Not Found'}), 404, headers: _json);
    }
    final (status, body) = await h(req);
    if (status == null) {
      throw DioException.connectionError(requestOptions: options, reason: 'fake: connection refused');
    }
    return ResponseBody.fromString(body == null ? '' : jsonEncode(body), status, headers: _json);
  }

  static final _json = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> tokenJson(String access, String refresh) =>
    {'access_token': access, 'refresh_token': refresh, 'token_type': 'bearer', 'expires_in': 1800};
