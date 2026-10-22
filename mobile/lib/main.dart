import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/config/env.dart';
import 'core/l10n/locale_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Env.validate();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      // Riverpod 3 retries failing providers by default; we show errors with a retry button.
      retry: (retryCount, error) => null,
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const App(),
    ),
  );
}
