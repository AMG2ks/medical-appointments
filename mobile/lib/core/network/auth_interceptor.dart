import 'package:dio/dio.dart';

import '../storage/token_storage.dart';

/// Paths (relative to the API base URL) that carry no bearer token and never trigger a
/// refresh. Matched exactly.
const _publicPaths = {
  'auth/login/',
  'auth/register/',
  'auth/token/refresh/',
  'auth/logout/', // if it refreshed, rotation would leave a valid refresh token after logout
  'auth/password/reset/',
  'auth/password/reset/confirm/',
};

bool _isPublic(String path) =>
    _publicPaths.contains(path.startsWith('/') ? path.substring(1) : path);

/// The bearer token is only for our own backend, never for an absolute URL elsewhere.
bool _isOwnBackend(RequestOptions options) =>
    options.uri.origin == Uri.parse(options.baseUrl).origin;

/// Adds `Accept-Language` and the bearer token, and refreshes the access token once on 401.
///
/// A [QueuedInterceptor] handles one 401 at a time: when several requests fail together,
/// the first one refreshes and the others see a newer stored token and just retry.
/// (With rotation + blacklist, refreshing twice with the same refresh token would fail
/// and log the user out.)
///
/// Retries go through [plainDio]: using the same Dio inside a queued interceptor deadlocks.
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor({
    required this.plainDio,
    required this.tokens,
    required this.currentLanguage,
    required this.onSessionExpired,
  });

  final Dio plainDio;
  final TokenStorage tokens;

  /// Called at request time (reads the provider lazily, which avoids a provider cycle).
  final String Function() currentLanguage;
  final void Function() onSessionExpired;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    options.headers['Accept-Language'] = currentLanguage();
    if (!_isPublic(options.path) && _isOwnBackend(options)) {
      final access = await tokens.readAccess();
      if (access != null) options.headers['Authorization'] = 'Bearer $access';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    final isRetryable =
        err.response?.statusCode == 401 &&
        !_isPublic(request.path) &&
        _isOwnBackend(request) &&
        request.extra['retried'] != true;
    if (!isRetryable) return handler.next(err);

    // Another request may already have refreshed while this one was waiting.
    final usedHeader = request.headers['Authorization'];
    final current = await tokens.readAccess();
    if (current != null && usedHeader != 'Bearer $current') {
      return _retry(request, current, handler, err);
    }

    final refresh = await tokens.readRefresh();
    if (refresh == null) return _expire(err, handler);

    try {
      final response = await plainDio.post<Map<String, dynamic>>(
        'auth/token/refresh/',
        data: {'refresh': refresh},
      );
      // Compare-and-set: if the session changed while we were refreshing (logout, new
      // login, password change), do not overwrite it with this older result.
      if (await tokens.readRefresh() != refresh) {
        return _retryWithStoredToken(request, err, handler);
      }
      final access = response.data!['access'] as String;
      await tokens.save(
        access: access,
        refresh: response.data!['refresh'] as String,
      );
      return _retry(request, access, handler, err);
    } on DioException catch (refreshError) {
      final status = refreshError.response?.statusCode;
      if (status == 400 || status == 401) {
        // Only end the session if it is still the one we tried to refresh.
        if (await tokens.readRefresh() == refresh) return _expire(err, handler);
        return _retryWithStoredToken(request, err, handler);
      }
      // Network trouble while refreshing: keep the session, report the network error.
      return handler.next(refreshError);
    }
  }

  Future<void> _retryWithStoredToken(
    RequestOptions request,
    DioException original,
    ErrorInterceptorHandler handler,
  ) async {
    final access = await tokens.readAccess();
    if (access == null) return handler.next(original);
    return _retry(request, access, handler, original);
  }

  Future<void> _expire(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    await tokens.clear();
    onSessionExpired();
    handler.next(err);
  }

  /// One retry only (`retried` flag): a second 401 is returned to the caller.
  Future<void> _retry(
    RequestOptions request,
    String access,
    ErrorInterceptorHandler handler,
    DioException original,
  ) async {
    request.extra['retried'] = true;
    request.headers['Authorization'] = 'Bearer $access';
    try {
      handler.resolve(await plainDio.fetch<dynamic>(request));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
