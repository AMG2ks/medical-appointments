import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/l10n/locale_controller.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/appointments/data/appointments_repository.dart';
import 'package:medical_appointments/features/appointments/presentation/appointments_providers.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/notifications/data/notifications_repository.dart';
import 'package:medical_appointments/features/notifications/local_reminders.dart';
import 'package:medical_appointments/features/notifications/presentation/notifications_providers.dart';

import '../../support/fake_appointments_repository.dart';
import '../../support/fake_local_reminders.dart';
import '../../support/fake_notifications_repository.dart';
import '../../support/fakes.dart';
import '../../support/test_app.dart';

class SlowCountRepository extends FakeNotificationsRepository {
  SlowCountRepository(FakeNotificationsRepository base)
    : super(items: base.items);

  Completer<void>? hold;

  @override
  Future<int> unreadCount() async {
    final count = await super.unreadCount();
    await hold?.future;
    return count;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeNotificationsRepository repo;
  late FakeLocalReminders reminders;
  late FakeAppointmentsRepository appointments;

  Future<ProviderContainer> container({
    UserRole? role = UserRole.patient,
  }) async => makeContainer([
    ...await baseOverrides(),
    notificationsRepositoryProvider.overrideWithValue(repo),
    appointmentsRepositoryProvider.overrideWithValue(appointments),
    localRemindersProvider.overrideWithValue(reminders),
    currentUserIdProvider.overrideWithValue(role == null ? null : 1),
    currentUserProvider.overrideWithValue(
      role == null ? null : fakeUser(role: role),
    ),
  ]);

  setUp(() {
    repo = FakeNotificationsRepository(
      items: [
        fakeNotification(id: 3),
        fakeNotification(id: 2),
        fakeNotification(id: 1, read: true),
      ],
    );
    reminders = FakeLocalReminders();
    appointments = FakeAppointmentsRepository(
      appointments: [
        fakeAppointment(
          id: 41,
          startAt: DateTime.now().toUtc().add(const Duration(days: 3)),
        ),
      ],
    );
  });

  group('unread count', () {
    test('loads the count; refresh picks up new ones silently', () async {
      final c = await container();
      expect(await c.read(unreadCountProvider.future), 2);
      repo.items.add(fakeNotification(id: 4));
      await c.read(unreadCountProvider.notifier).refresh();
      expect(c.read(unreadCountProvider).value, 3);
    });

    test('a failing refresh keeps the last count and shows no error', () async {
      final c = await container();
      await c.read(unreadCountProvider.future);
      repo.countError = const ApiException(code: 'network_error');
      await c.read(unreadCountProvider.notifier).refresh();
      expect(c.read(unreadCountProvider).value, 2);
      expect(c.read(unreadCountProvider).hasError, isFalse);
    });

    test('admins and logged-out users: 0, nothing fetched', () async {
      for (final role in [UserRole.admin, null]) {
        repo.calls.clear();
        final c = await container(role: role);
        expect(await c.read(unreadCountProvider.future), 0);
        await c.read(unreadCountProvider.notifier).refresh();
        expect(repo.calls, isEmpty);
      }
    });
  });

  test('a poll that was in flight cannot undo "mark all as read"', () async {
    final slow = SlowCountRepository(repo);
    final c = makeContainer([
      ...await baseOverrides(),
      notificationsRepositoryProvider.overrideWithValue(slow),
      currentUserIdProvider.overrideWithValue(1),
      currentUserProvider.overrideWithValue(fakeUser()),
    ]);
    await c.read(unreadCountProvider.future);
    slow.hold = Completer<void>();
    final poll =
        c.read(unreadCountProvider.notifier).refresh(); // sees 2 (stale)
    await Future<void>.delayed(Duration.zero);
    c.read(unreadCountProvider.notifier).set(0); // read-all finished meanwhile
    slow.hold!.complete();
    await poll;
    expect(c.read(unreadCountProvider).value, 0);
  });

  group('list', () {
    test('loads, marks one read (and refreshes the badge)', () async {
      final c = await container();
      await c.read(unreadCountProvider.future);
      final list = await c.read(notificationsListProvider.future);
      expect(list.items.map((n) => n.id), [3, 2, 1]);

      await c
          .read(notificationsListProvider.notifier)
          .markRead(list.items.first);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(notificationsListProvider).value!.items.first.isRead, true);
      expect(c.read(unreadCountProvider).value, 1);
      expect(repo.calls, contains('markRead 3'));
    });

    test('marking an already read one does not call the server', () async {
      final c = await container();
      final list = await c.read(notificationsListProvider.future);
      await c
          .read(notificationsListProvider.notifier)
          .markRead(list.items.last);
      expect(repo.calls.where((x) => x.startsWith('markRead')), isEmpty);
    });

    test('mark all read: items read, badge 0', () async {
      final c = await container();
      await c.read(unreadCountProvider.future);
      await c.read(notificationsListProvider.future);
      await c.read(notificationsListProvider.notifier).markAllRead();
      expect(
        c.read(notificationsListProvider).value!.items.every((n) => n.isRead),
        isTrue,
      );
      expect(c.read(unreadCountProvider).value, 0);
    });

    test('pages: loadMore appends the next page', () async {
      repo = FakeNotificationsRepository(
        items: [for (var i = 5; i > 0; i--) fakeNotification(id: i)],
        pageSize: 2,
      );
      final c = await container();
      final first = await c.read(notificationsListProvider.future);
      expect(first.items.length, 2);
      expect(first.hasNext, isTrue);
      await c.read(notificationsListProvider.notifier).loadMore();
      expect(c.read(notificationsListProvider).value!.items.length, 4);
    });

    test('refresh reloads the list and the badge', () async {
      final c = await container();
      await c.read(unreadCountProvider.future);
      await c.read(notificationsListProvider.future);
      repo.items.insert(0, fakeNotification(id: 9));
      await c.read(notificationsListProvider.notifier).refresh();
      expect(c.read(notificationsListProvider).value!.items.first.id, 9);
      expect(c.read(unreadCountProvider).value, 3);
    });
  });

  group('reminder sync (patient)', () {
    test(
      'resyncs from the upcoming appointments, in the current language',
      () async {
        final c = await container();
        c.listen(reminderSyncProvider, (_, _) {});
        await c.read(upcomingConfirmedProvider.future);
        await settle();

        expect(reminders.resyncs, [
          [41],
        ]);
        expect(
          reminders.lastTexts!.title,
          'Rappel de rendez-vous',
        ); // device = fr
      },
    );

    test('every new fetch (a booking, a cancellation) resyncs again', () async {
      final c = await container();
      c.listen(reminderSyncProvider, (_, _) {});
      await c.read(upcomingConfirmedProvider.future);
      await settle();
      appointments.appointments.clear(); // cancelled meanwhile
      c.invalidate(upcomingConfirmedProvider);
      await c.read(upcomingConfirmedProvider.future);
      await settle();

      expect(reminders.resyncs, [
        [41],
        <int>[],
      ]);
    });

    test('a language change reschedules with the new texts', () async {
      final c = await container();
      c.listen(reminderSyncProvider, (_, _) {});
      await c.read(upcomingConfirmedProvider.future);
      await settle();
      expect(reminders.lastTexts!.title, 'Rappel de rendez-vous');

      c.read(localeControllerProvider.notifier).applyServerLanguage('en');
      await settle();

      expect(reminders.resyncs.length, 2);
      expect(reminders.lastTexts!.title, 'Appointment reminder');
    });

    test('doctors and admins get no on-device reminders', () async {
      for (final role in [UserRole.doctor, UserRole.admin]) {
        final c = await container(role: role);
        c.listen(reminderSyncProvider, (_, _) {});
        await settle();
      }
      expect(reminders.resyncs, isEmpty);
      expect(
        reminders.cancelAllCalls,
        2,
      ); // leftovers of an earlier patient session
    });

    test('a failing fetch leaves the schedule alone', () async {
      appointments.listError = const ApiException(code: 'network_error');
      final c = await container();
      c.listen(reminderSyncProvider, (_, _) {});
      await c
          .read(upcomingConfirmedProvider.future)
          .then<void>((_) {}, onError: (Object _) {});
      await settle();
      expect(reminders.resyncs, isEmpty);
      expect(reminders.cancelAllCalls, 0);
    });
  });
}
