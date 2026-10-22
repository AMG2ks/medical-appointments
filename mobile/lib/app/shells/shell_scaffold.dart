import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Bottom navigation container shared by the three role shells.
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({
    super.key,
    required this.shell,
    required this.destinations,
  });

  final StatefulNavigationShell shell;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected:
            (index) => shell.goBranch(
              index,
              initialLocation: index == shell.currentIndex,
            ),
        destinations: destinations,
      ),
    );
  }
}
