import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:medical_appointments/core/l10n/locale_controller.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overrides every test needs (preferences + device language).
Future<List<Override>> baseOverrides({
  Map<String, Object> prefs = const {},
  Locale device = const Locale('fr'),
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final instance = await SharedPreferences.getInstance();
  return [
    sharedPreferencesProvider.overrideWithValue(instance),
    deviceLocaleProvider.overrideWithValue(device),
  ];
}

ProviderContainer makeContainer(List<Override> overrides) {
  final container = ProviderContainer(
    overrides: overrides,
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  return container;
}

/// Pumps [child] with localization in [locale] and the given provider overrides.
Widget testApp(
  Widget child, {
  required Locale locale,
  required List<Override> overrides,
}) {
  return ProviderScope(
    retry: (_, _) => null,
    overrides: overrides,
    child: MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: child,
    ),
  );
}

/// Like [testApp] but with a router (for screens that navigate).
Widget testRouterApp(
  GoRouter router, {
  required Locale locale,
  required List<Override> overrides,
}) {
  return ProviderScope(
    retry: (_, _) => null,
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: router,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
    ),
  );
}
