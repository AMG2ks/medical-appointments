import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import 'models/user.dart';

/// Access + refresh tokens, with the user when the endpoint returns it.
class AuthSession {
  const AuthSession({required this.access, required this.refresh, this.user});

  final String access;
  final String refresh;
  final User? user;

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    access: json['access'] as String,
    refresh: json['refresh'] as String,
    user:
        json['user'] == null
            ? null
            : User.fromJson(json['user'] as Map<String, dynamic>),
  );
}

/// One method per endpoint of `/api/v1/auth/`. Errors come out as [ApiException].
class AuthApi {
  AuthApi(this._dio);

  final Dio _dio;

  Future<AuthSession> register(Map<String, dynamic> body) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      'auth/register/',
      data: body,
    );
    return AuthSession.fromJson(response.data!);
  });

  Future<AuthSession> login(String email, String password) =>
      guardApi(() async {
        final response = await _dio.post<Map<String, dynamic>>(
          'auth/login/',
          data: {'email': email, 'password': password},
        );
        return AuthSession.fromJson(response.data!);
      });

  Future<void> logout(String refresh) => guardApi(
    () => _dio.post<void>('auth/logout/', data: {'refresh': refresh}),
  );

  Future<User> me() => guardApi(() async {
    final response = await _dio.get<Map<String, dynamic>>('auth/me/');
    return User.fromJson(response.data!);
  });

  Future<User> updateMe(Map<String, dynamic> patch) => guardApi(() async {
    final response = await _dio.patch<Map<String, dynamic>>(
      'auth/me/',
      data: patch,
    );
    return User.fromJson(response.data!);
  });

  Future<AuthSession> changePassword(String oldPassword, String newPassword) =>
      guardApi(() async {
        final response = await _dio.post<Map<String, dynamic>>(
          'auth/password/change/',
          data: {'old_password': oldPassword, 'new_password': newPassword},
        );
        return AuthSession.fromJson(response.data!);
      });

  Future<void> requestPasswordReset(String email) => guardApi(
    () => _dio.post<void>('auth/password/reset/', data: {'email': email}),
  );

  Future<void> confirmPasswordReset({
    required String email,
    required String code,
    required String newPassword,
  }) => guardApi(
    () => _dio.post<void>(
      'auth/password/reset/confirm/',
      data: {'email': email, 'code': code, 'new_password': newPassword},
    ),
  );
}

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(dioProvider)),
);
