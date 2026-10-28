import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/utils/date_format.dart';
import '../../../../core/widgets/async_value_view.dart';
import '../../../appointments/presentation/appointments_routes.dart';
import '../../../auth/data/models/user.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../data/models/app_notification.dart';
import '../notifications_providers.dart';
import 'notification_texts.dart';

/// The in-app notification list (patient and doctor tabs). Unread ones are bold with a dot;
/// tapping one marks it read and opens its appointment.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  Future<void> _guard(
    BuildContext context,
    Future<void> Function() call,
  ) async {
    try {
      await call();
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }

  void _open(BuildContext context, WidgetRef ref, AppNotification n) {
    _guard(
      context,
      () => ref.read(notificationsListProvider.notifier).markRead(n),
    );
    final id = n.appointmentId;
    final role = ref.read(currentUserProvider)?.role;
    if (id == null || role == null || role == UserRole.admin) return;
    showAppointment(context, id: id, doctor: role == UserRole.doctor);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final list = ref.watch(notificationsListProvider);
    final controller = ref.read(notificationsListProvider.notifier);
    final role = ref.watch(currentUserProvider.select((u) => u?.role));
    final hasUnread = list.value?.items.any((n) => !n.isRead) ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.notifTitle),
        actions: [
          if (hasUnread)
            TextButton(
              onPressed: () => _guard(context, controller.markAllRead),
              child: Text(l10n.notifMarkAllRead),
            ),
        ],
      ),
      body: AsyncValueView(
        value: list,
        onRetry: () => ref.invalidate(notificationsListProvider),
        onRefresh: controller.refresh,
        isEmpty: (state) => state.items.isEmpty,
        emptyText: l10n.notifEmpty,
        data:
            (state) => RefreshIndicator(
              onRefresh: controller.refresh,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: state.items.length + (state.hasNext ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index == state.items.length) {
                    return Padding(
                      padding: const EdgeInsets.all(8),
                      child: TextButton(
                        onPressed: () => _guard(context, controller.loadMore),
                        child: Text(l10n.commonLoadMore),
                      ),
                    );
                  }
                  final n = state.items[index];
                  final text = notificationText(
                    context,
                    n,
                    role ?? UserRole.patient,
                  );
                  return ListTile(
                    onTap: () => _open(context, ref, n),
                    leading:
                        n.isRead
                            ? const Icon(Icons.notifications_none)
                            : Icon(
                              Icons.circle,
                              size: 12,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                    title: Text(
                      text.title,
                      style:
                          n.isRead
                              ? null
                              : const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '${text.body}\n${formatDateTime(context, n.createdAt)}',
                    ),
                    isThreeLine: true,
                  );
                },
              ),
            ),
      ),
    );
  }
}
