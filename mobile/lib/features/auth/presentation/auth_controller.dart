import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/locale_controller.dart';
import '../../notifications/local_reminders.dart';
import '../data/auth_repository.dart';
import '../data/models/user.dart';

/// loading = unknown (app starting) · data(null) = logged out · data(user) = logged in.
class AuthController extends AsyncNotifier<User?> {
  AuthRepository get _repo => ref.read(authRepositoryProvider);

  @override
  Future<User?> build() async {
    final user = await _repo.restoreSession();
    if (user != null) _adoptServerLanguage(user);
    return user;
  }

  /// Server wins: the account's language replaces the device's choice.
  void _adoptServerLanguage(User user) {
    ref
        .read(localeControllerProvider.notifier)
        .applyServerLanguage(user.preferredLanguage);
  }

  Future<void> login(String email, String password) async {
    final user = await _repo.login(email, password);
    _adoptServerLanguage(user);
    state = AsyncData(user);
  }

  /// [body] is the register payload; the screen adds `preferred_language`.
  Future<void> register(Map<String, dynamic> body) async {
    final user = await _repo.register(body);
    state = AsyncData(user);
  }

  bool _loggingOut = false;

  /// Hook of the notifications module: reminders of this user must not outlive the session
  /// (the next person using the phone must not get them). Never throws: a failing hook must
  /// never keep the user logged in.
  Future<void> _cancelReminders() async {
    try {
      await ref.read(localRemindersProvider).cancelAll();
    } catch (_) {}
  }

  /// Local logout first (the user is out immediately, even offline), server revoke after.
  Future<void> logout() async {
    if (_loggingOut) return; // double tap
    _loggingOut = true;
    try {
      final refresh = await _repo.endSession();
      state = const AsyncData(null);
      await _cancelReminders();
      if (refresh != null) unawaited(_repo.revokeOnServer(refresh));
    } finally {
      _loggingOut = false;
    }
  }

  /// "Back to login" on the splash error state: forget the stored session.
  Future<void> discardSession() async {
    await _repo.clearSession();
    state = const AsyncData(null);
    unawaited(_cancelReminders());
  }

  /// Called by the interceptor when the refresh token is dead (tokens already cleared).
  void sessionExpired() {
    state = const AsyncData(null);
    unawaited(_cancelReminders());
  }

  Future<void> updateProfile(Map<String, dynamic> patch) async {
    state = AsyncData(await _repo.updateProfile(patch));
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, User?>(
  AuthController.new,
);

/// The logged-in user, or null. Every user-scoped provider must watch this, so its data
/// resets on logout.
final currentUserProvider = Provider<User?>(
  (ref) => ref.watch(authControllerProvider).value,
);

/// The logged-in user's id, or null. User-scoped providers should watch THIS one: it does
/// not change when the profile is edited, so their data is not reloaded needlessly, and it
/// still resets on logout or account switch.
final currentUserIdProvider = Provider<int?>(
  (ref) => ref.watch(authControllerProvider.select((auth) => auth.value?.id)),
);
