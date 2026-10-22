import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/storage/token_storage.dart';
import 'auth_api.dart';
import 'models/user.dart';

/// Auth API + token storage. Whoever logs in or out goes through here.
class AuthRepository {
  AuthRepository(this._api, this._tokens);

  final AuthApi _api;
  final TokenStorage _tokens;

  /// The user of the stored session, or null when there is none or it cannot be used.
  /// Only a network error is rethrown (the session may still be valid, retry later).
  /// Any other failure (401, 500, unreadable answer, unknown role) drops the tokens, so the
  /// user is never stuck on the splash.
  Future<User?> restoreSession() async {
    if (await _tokens.readRefresh() == null) return null;
    try {
      return await _api
          .me(); // the interceptor refreshes an expired access token
    } on ApiException catch (e) {
      if (e.isNetworkError) rethrow;
      await _tokens.clear();
      return null;
    } catch (_) {
      await _tokens.clear();
      return null;
    }
  }

  Future<User> login(String email, String password) async {
    final session = await _api.login(email, password);
    await _tokens.save(access: session.access, refresh: session.refresh);
    return session.user!;
  }

  Future<User> register(Map<String, dynamic> body) async {
    final session = await _api.register(body);
    await _tokens.save(access: session.access, refresh: session.refresh);
    return session.user!;
  }

  /// Local part of a logout: returns the refresh token to revoke and clears the storage.
  Future<String?> endSession() async {
    final refresh = await _tokens.readRefresh();
    await _tokens.clear();
    return refresh;
  }

  /// Best effort and never throws: the session is already gone locally.
  Future<void> revokeOnServer(String refresh) async {
    try {
      await _api.logout(refresh);
    } catch (_) {
      // Offline or already expired: nothing more to do.
    }
  }

  Future<void> clearSession() => _tokens.clear();

  Future<User> updateProfile(Map<String, dynamic> patch) =>
      _api.updateMe(patch);

  Future<void> changePassword(String oldPassword, String newPassword) async {
    final session = await _api.changePassword(oldPassword, newPassword);
    await _tokens.save(access: session.access, refresh: session.refresh);
  }

  Future<void> requestPasswordReset(String email) =>
      _api.requestPasswordReset(email);

  Future<void> confirmPasswordReset({
    required String email,
    required String code,
    required String newPassword,
  }) => _api.confirmPasswordReset(
    email: email,
    code: code,
    newPassword: newPassword,
  );
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    ref.watch(authApiProvider),
    ref.watch(tokenStorageProvider),
  ),
);
