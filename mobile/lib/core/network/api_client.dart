import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// core -> features/auth is a cycle at import level only (Dart allows it): the interceptor
// callbacks below read the auth controller lazily, so there is no provider cycle.
import '../../features/auth/presentation/auth_controller.dart';
import '../config/constants.dart';
import '../config/env.dart';
import '../l10n/locale_controller.dart';
import '../storage/token_storage.dart';
import 'auth_interceptor.dart';

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

/// `https://host:8000` -> `https://host:8000/api/v1/` (overridden in tests).
final apiBaseUrlProvider = Provider<String>((ref) {
  final base = Env.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base$apiPrefix';
});

Dio _newDio(String baseUrl) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: {'Accept': 'application/json'},
    ),
  );
  if (kDebugMode) {
    // Never log headers or bodies: they hold tokens and passwords.
    dio.interceptors.add(
      LogInterceptor(
        requestHeader: false,
        requestBody: false,
        responseHeader: false,
        responseBody: false,
      ),
    );
  }
  return dio;
}

/// No auth: used by the interceptor itself to refresh and to retry. A retry through it
/// skips every interceptor added later to [dioProvider] (logging aside): keep them idempotent.
final plainDioProvider = Provider<Dio>(
  (ref) => _newDio(ref.watch(apiBaseUrlProvider)),
);

/// THE client for every feature: `ref.watch(dioProvider)`. Never create your own `Dio`.
final dioProvider = Provider<Dio>((ref) {
  final dio = _newDio(ref.watch(apiBaseUrlProvider));
  dio.interceptors.insert(
    0,
    AuthInterceptor(
      plainDio: ref.watch(plainDioProvider),
      tokens: ref.watch(tokenStorageProvider),
      // Read at call time, so there is no provider cycle with the controllers.
      currentLanguage: () => ref.read(localeControllerProvider).languageCode,
      onSessionExpired:
          () => ref.read(authControllerProvider.notifier).sessionExpired(),
    ),
  );
  return dio;
});
