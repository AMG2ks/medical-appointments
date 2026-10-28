import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n/locale_controller.dart';
import '../features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import 'router.dart';
import 'theme.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the "who is logged in" providers fresh. User-scoped providers that survive a
    // logout are dormant (nobody listens) and stale at the next login; they are rebuilt when
    // a screen first watches them, WHILE widgets are building. If their dependency (the user
    // id / role) were rebuilt right then too, its change would invalidate other providers
    // mid-build ("setState() or markNeedsBuild() called during build"). With a listener here
    // these two are refreshed before any descendant builds, so nothing cascades.
    ref.listen(currentUserIdProvider, (_, _) {});
    ref.listen(currentUserProvider, (_, _) {});
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: appTheme,
      routerConfig: ref.watch(routerProvider),
      locale: ref.watch(localeControllerProvider),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
    );
  }
}
