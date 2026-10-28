import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import 'shell_scaffold.dart';

/// Doctor area. Add your tab here AND its branch in `app/router.dart`.
class DoctorShell extends StatelessWidget {
  const DoctorShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ShellScaffold(
      shell: shell,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          label: l10n.navHome,
        ),
        NavigationDestination(
          icon: const Icon(Icons.schedule_outlined),
          label: l10n.navAvailability,
        ),
        NavigationDestination(
          icon: const Icon(Icons.medical_services_outlined),
          label: l10n.navPractice,
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline),
          label: l10n.navProfile,
        ),
      ],
    );
  }
}
