import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

import '../../../../core/config/env.dart';
import '../../../appointments/presentation/appointments_providers.dart';
import '../../../auth/data/models/user.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../notifications_providers.dart';

/// Lives as long as a logged-in shell does (so it disappears on logout). It
/// - polls the unread count every [pollInterval] while the app is in the foreground and
///   stops the timer in the background; it refreshes at once when the app resumes,
/// - shows a snackbar when the count goes up,
/// - keeps the on-device reminders in sync (see [reminderSyncProvider]).
class NotificationsHost extends ConsumerStatefulWidget {
  const NotificationsHost({
    super.key,
    required this.child,
    this.pollInterval = const Duration(seconds: Env.notificationsPollSeconds),
  });

  final Widget child;
  final Duration pollInterval;

  @override
  ConsumerState<NotificationsHost> createState() => _NotificationsHostState();
}

class _NotificationsHostState extends ConsumerState<NotificationsHost>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    super.dispose();
  }

  void _startTimer() {
    _timer ??= Timer.periodic(widget.pollInterval, (_) => _refresh());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _refresh() {
    unawaited(ref.read(unreadCountProvider.notifier).refresh());
  }

  /// Something may have changed on the server (a doctor cancelled, ...): reload the upcoming
  /// appointments, which resyncs the on-device reminders (patients only).
  void _reloadReminders() {
    if (ref.read(currentUserProvider)?.role == UserRole.patient) {
      ref.invalidate(upcomingConfirmedProvider);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _reloadReminders();
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  void _onCountChanged(AsyncValue<int>? previous, AsyncValue<int> next) {
    // Only real polls count: not the first load, and not the reload after an account switch
    // (it goes through a loading state; the other account's count is no "increase").
    if (previous == null || previous.isLoading || next.isLoading) return;
    final before = previous.value;
    final after = next.value;
    if (before == null || after == null || after <= before) return;
    // New notifications: reload the list if it is loaded, and tell the user.
    ref.invalidate(notificationsListProvider);
    ref.invalidate(appointmentsListProvider); // e.g. a doctor cancelled
    _reloadReminders();
    final role = ref.read(currentUserProvider)?.role;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.notifNewSnack(after - before)),
        action:
            role == null || role == UserRole.admin
                ? null
                : SnackBarAction(
                  label: l10n.notifViewAction,
                  onPressed: () => context.go('/${role.name}/notifications'),
                ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(reminderSyncProvider);
    ref.listen(unreadCountProvider, _onCountChanged);
    return widget.child;
  }
}
