import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

import '../../../core/l10n/locale_controller.dart';
import '../../appointments/data/models/appointment.dart';
import '../../appointments/presentation/appointments_providers.dart';
import '../../auth/data/models/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/models/app_notification.dart';
import '../data/notifications_repository.dart';
import '../local_reminders.dart';

// Every user-scoped provider watches currentUserIdProvider so its data resets on logout.

/// Number of unread notifications (the badge). Refreshed by the poller in
/// `NotificationsHost` (foreground only), on resume and after reading.
class UnreadCountController extends AsyncNotifier<int> {
  /// Admins receive no notifications: nothing to poll for them.
  bool get _hasNotifications {
    final role = ref.read(currentUserProvider)?.role;
    return role != null && role != UserRole.admin;
  }

  /// Bumped by every `set` and rebuild: a poll that started before one of them is stale
  /// (it must not bring back a count the user just cleared with "mark all as read").
  int _epoch = 0;

  @override
  Future<int> build() async {
    _epoch++;
    ref.watch(currentUserIdProvider);
    if (!_hasNotifications) return 0;
    return ref.read(notificationsRepositoryProvider).unreadCount();
  }

  /// Silent reload (no loading state, errors ignored): polling must not flash the badge
  /// or show an error every 30 seconds while offline. The last known count stays.
  Future<void> refresh() async {
    if (!_hasNotifications) return;
    final epoch = _epoch;
    try {
      final count =
          await ref.read(notificationsRepositoryProvider).unreadCount();
      if (ref.mounted && epoch == _epoch) state = AsyncData(count);
    } catch (_) {
      // Keep the previous value.
    }
  }

  void set(int count) {
    _epoch++;
    state = AsyncData(count < 0 ? 0 : count);
  }
}

final unreadCountProvider = AsyncNotifierProvider<UnreadCountController, int>(
  UnreadCountController.new,
);

class NotificationsListState {
  const NotificationsListState({
    this.items = const [],
    this.page = 1,
    this.hasNext = false,
  });

  final List<AppNotification> items;
  final int page;
  final bool hasNext;

  NotificationsListState copyWith({List<AppNotification>? items}) =>
      NotificationsListState(
        items: items ?? this.items,
        page: page,
        hasNext: hasNext,
      );
}

/// The notifications list, paged (newest first).
class NotificationsListController
    extends AsyncNotifier<NotificationsListState> {
  bool _loadingMore = false;
  int _generation = 0;

  NotificationsRepository get _repo =>
      ref.read(notificationsRepositoryProvider);

  @override
  Future<NotificationsListState> build() {
    ref.watch(currentUserIdProvider);
    _generation++;
    return _fetch(1, const []);
  }

  Future<NotificationsListState> _fetch(
    int page,
    List<AppNotification> previous,
  ) async {
    final result = await _repo.list(page: page);
    return NotificationsListState(
      items: [...previous, ...result.results],
      page: page,
      hasNext: result.hasNext,
    );
  }

  /// Pull to refresh: reloads the list and the badge together.
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
    await ref.read(unreadCountProvider.notifier).refresh();
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasNext || _loadingMore) return;
    _loadingMore = true;
    final generation = _generation;
    try {
      final next = await _fetch(current.page + 1, current.items);
      if (!ref.mounted || generation != _generation) return;
      state = AsyncData(next);
    } finally {
      _loadingMore = false;
    }
  }

  /// Marks one as read (no-op if it already is). Throws ApiException.
  Future<void> markRead(AppNotification notification) async {
    if (notification.isRead) return;
    final updated = await _repo.markRead(notification.id);
    final current = state.value;
    if (ref.mounted && current != null) {
      state = AsyncData(
        current.copyWith(
          items: [
            for (final n in current.items) n.id == updated.id ? updated : n,
          ],
        ),
      );
    }
    unawaited(ref.read(unreadCountProvider.notifier).refresh());
  }

  Future<void> markAllRead() async {
    await _repo.markAllRead();
    final current = state.value;
    if (ref.mounted && current != null) {
      final now = DateTime.now();
      state = AsyncData(
        current.copyWith(
          items: [for (final n in current.items) n.copyWith(readAt: now)],
        ),
      );
    }
    ref.read(unreadCountProvider.notifier).set(0);
  }
}

final notificationsListProvider =
    AsyncNotifierProvider<NotificationsListController, NotificationsListState>(
      NotificationsListController.new,
    );

/// Keeps the on-device reminders equal to the server's upcoming appointments (patients).
/// Watch it from a widget that lives while the user is logged in. It re-runs whenever the
/// list is fetched again (every booking / cancellation invalidates it) and when the language
/// changes (the reminder texts are in the current language).
final reminderSyncProvider = Provider<void>((ref) {
  final role = ref.watch(currentUserProvider.select((u) => u?.role));
  if (role != UserRole.patient) {
    // Doctors and admins get none: drop what a previous patient session left behind.
    unawaited(_cancelAll(ref.read(localRemindersProvider)));
    return;
  }
  final locale = ref.watch(localeControllerProvider);
  final upcoming = ref.watch(upcomingConfirmedProvider);
  // Loading (also while reloading with the previous list) or failed: keep what is scheduled.
  final appointments = upcoming.isLoading ? null : upcoming.value;
  if (appointments == null) return;
  unawaited(_resync(ref.read(localRemindersProvider), appointments, locale));
});

Future<void> _cancelAll(LocalReminders reminders) async {
  try {
    await reminders.cancelAll();
  } catch (_) {}
}

Future<void> _resync(
  LocalReminders reminders,
  List<Appointment> appointments,
  Locale locale,
) async {
  try {
    // The date data of the language may not be loaded yet (right after a language switch).
    await initializeDateFormatting(locale.toString());
    final l10n = lookupAppLocalizations(locale);
    final format = DateFormat.yMMMEd(locale.toString()).add_Hm();
    await reminders.resync(
      appointments,
      texts: ReminderTexts(
        title: l10n.notifReminderTitle,
        channelName: l10n.notifReminderChannel,
        body:
            (a) => l10n.notifReminderBody(
              a.doctor.fullName,
              format.format(a.start),
            ),
      ),
    );
  } catch (_) {
    // Best effort: reminders are rebuilt at the next fetch.
  }
}
