import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/presentation/auth_controller.dart';
import '../config/constants.dart';

/// Overridden in `main()` with the loaded instance (and in tests).
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) =>
      throw UnimplementedError('Override sharedPreferencesProvider in main()'),
);

/// The device language (overridden in tests).
final deviceLocaleProvider = Provider<Locale>(
  (ref) => PlatformDispatcher.instance.locale,
);

/// Current UI language. Start-up order: stored choice -> device language if supported -> fr.
class LocaleController extends Notifier<Locale> {
  @override
  Locale build() {
    final stored = ref
        .read(sharedPreferencesProvider)
        .getString(localePrefsKey);
    if (stored != null && supportedLanguageCodes.contains(stored)) {
      return Locale(stored);
    }
    final device = ref.read(deviceLocaleProvider).languageCode;
    return Locale(
      supportedLanguageCodes.contains(device)
          ? device
          : supportedLanguageCodes.first,
    );
  }

  Future<void> _apply(Locale locale) async {
    state = locale;
    await ref
        .read(sharedPreferencesProvider)
        .setString(localePrefsKey, locale.languageCode);
  }

  /// After login / app start with a session: the account's language wins.
  void applyServerLanguage(String code) {
    if (supportedLanguageCodes.contains(code) && code != state.languageCode) {
      _apply(Locale(code));
    }
  }

  /// User taps FR/EN. Logged out: local only. Logged in: also saved on the server, and
  /// reverted (error rethrown) if that fails, so the app and the emails never disagree.
  Future<void> setLanguage(String code) async {
    final previous = state;
    await _apply(Locale(code));
    if (ref.read(currentUserProvider) == null) return;
    try {
      await ref.read(authControllerProvider.notifier).updateProfile({
        'preferred_language': code,
      });
    } catch (_) {
      await _apply(previous);
      rethrow;
    }
  }
}

final localeControllerProvider = NotifierProvider<LocaleController, Locale>(
  LocaleController.new,
);
