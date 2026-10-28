import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

import '../notifications_providers.dart';

/// Bell icon of the bottom navigation with the unread count as a badge.
class NotificationsNavIcon extends ConsumerWidget {
  const NotificationsNavIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(unreadCountProvider).value ?? 0;
    return Badge(
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : '$count'),
      child: Icon(
        Icons.notifications_outlined,
        semanticLabel: AppLocalizations.of(context).notifUnreadBadge,
      ),
    );
  }
}
