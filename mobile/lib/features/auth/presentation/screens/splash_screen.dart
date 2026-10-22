import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

import '../../../../core/l10n/error_text.dart';
import '../auth_controller.dart';

/// Shown while the session is being checked. The router leaves it as soon as the state is
/// known. If the check failed (e.g. offline) it offers a retry and a way back to login.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final auth = ref.watch(authControllerProvider);
    return Scaffold(
      body: Center(
        child:
            auth.hasError
                ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        errorText(context, auth.error),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => ref.invalidate(authControllerProvider),
                        child: Text(l10n.commonRetry),
                      ),
                      TextButton(
                        onPressed:
                            () =>
                                ref
                                    .read(authControllerProvider.notifier)
                                    .discardSession(),
                        child: Text(l10n.splashBackToLogin),
                      ),
                    ],
                  ),
                )
                : const CircularProgressIndicator(),
      ),
    );
  }
}
