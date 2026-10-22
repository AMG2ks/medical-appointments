import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

/// Home tab of the patient and doctor areas until M2/M3 replace it with their screens.
class HomePlaceholder extends ConsumerWidget {
  const HomePlaceholder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navHome)),
      body: Center(child: Text(l10n.homeWelcome(user?.firstName ?? ''))),
    );
  }
}
