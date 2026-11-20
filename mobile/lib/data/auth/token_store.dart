import '../storage/secret_store.dart';

/// Access/refresh token pair as returned by `/auth/login`, `/auth/signup`, `/auth/refresh`.
final class TokenPair {
  const TokenPair({required this.accessToken, required this.refreshToken});
  final String accessToken;
  final String refreshToken;

  factory TokenPair.fromJson(Map<String, Object?> j) {
    final a = j['access_token'];
    final r = j['refresh_token'];
    if (a is! String || r is! String || a.isEmpty || r.isEmpty) {
      throw const FormatException('token response without access_token/refresh_token');
    }
    return TokenPair(accessToken: a, refreshToken: r);
  }
}

/// Tokens and the backend URL, persisted in the [SecretStore]. Values are cached in
/// memory after the first read so the HTTP interceptor does not hit the Keystore per request.
class TokenStore {
  TokenStore(this._store);
  final SecretStore _store;

  static const _kAccess = 'auth.access_token';
  static const _kRefresh = 'auth.refresh_token';
  static const _kBaseUrl = 'settings.backend_url';

  /// Android emulator alias for the development PC's localhost.
  static const defaultBaseUrl = 'http://10.0.2.2:8000';

  TokenPair? _tokens;
  bool _loaded = false;
  String? _baseUrl;

  Future<TokenPair?> read() async {
    if (!_loaded) {
      final a = await _store.read(_kAccess);
      final r = await _store.read(_kRefresh);
      _tokens = (a != null && r != null) ? TokenPair(accessToken: a, refreshToken: r) : null;
      _loaded = true;
    }
    return _tokens;
  }

  Future<void> save(TokenPair t) async {
    await _store.write(_kAccess, t.accessToken);
    await _store.write(_kRefresh, t.refreshToken);
    _tokens = t;
    _loaded = true;
  }

  Future<void> clear() async {
    await _store.delete(_kAccess);
    await _store.delete(_kRefresh);
    _tokens = null;
    _loaded = true;
  }

  Future<String> baseUrl() async => _baseUrl ??= (await _store.read(_kBaseUrl)) ?? defaultBaseUrl;

  Future<void> setBaseUrl(String url) async {
    final normalized = normalizeBaseUrl(url);
    await _store.write(_kBaseUrl, normalized);
    _baseUrl = normalized;
  }

  /// Trims, drops trailing slashes and requires an http(s) URL with a host.
  static String normalizeBaseUrl(String url) {
    final t = url.trim().replaceAll(RegExp(r'/+$'), '');
    final u = Uri.tryParse(t);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
      throw const FormatException('Backend URL must look like http://host:port');
    }
    return t;
  }
}
