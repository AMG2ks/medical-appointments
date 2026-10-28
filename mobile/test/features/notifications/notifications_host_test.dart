import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/appointments/data/appointments_repository.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/notifications/data/notifications_repository.dart';
import 'package:medical_appointments/features/notifications/local_reminders.dart';
import 'package:medical_appointments/features/notifications/presentation/widgets/notifications_host.dart';
import 'package:medical_appointments/features/notifications/presentation/widgets/notifications_nav_icon.dart';

import '../../support/fake_appointments_repository.dart';
import '../../support/fake_local_reminders.dart';
import '../../support/fake_notifications_repository.dart';
import '../../support/fakes.dart';
import '../../support/test_app.dart';

void main() {
  late FakeNotificationsRepository repo;
  late FakeLocalReminders reminders;

  int polls() => repo.calls.where((c) => c == 'unreadCount').length;

  Future<void> pump(
    WidgetTester tester, {
    UserRole role = UserRole.patient,
  }) async {
    await tester.pumpWidget(
      testApp(
        const NotificationsHost(
          pollInterval: Duration(seconds: 30),
          child: Scaffold(body: Center(child: NotificationsNavIcon())),
        ),
        locale: const Locale('en'),
        overrides: [
          ...await baseOverrides(),
          notificationsRepositoryProvider.overrideWithValue(repo),
          appointmentsRepositoryProvider.overrideWithValue(
            FakeAppointmentsRepository(),
          ),
          localRemindersProvider.overrideWithValue(reminders),
          currentUserIdProvider.overrideWithValue(1),
          currentUserProvider.overrideWithValue(fakeUser(role: role)),
        ],
      ),
    );
    await tester.pump();
  }

  void lifecycle(AppLifecycleState state) {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  }

  setUp(() {
    repo = FakeNotificationsRepository(items: [fakeNotification(id: 1)]);
    reminders = FakeLocalReminders();
  });

  testWidgets(
    'polls every interval in the foreground, shows badge + snackbar when it grows',
    (tester) async {
      await pump(tester);
      expect(polls(), 1); // initial load
      expect(find.text('1'), findsOneWidget); // badge

      repo.items.add(fakeNotification(id: 2));
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();

      expect(polls(), 2);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('You have a new notification'), findsOneWidget);
    },
  );

  testWidgets('no snackbar when the count does not grow', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(polls(), 2);
    expect(find.textContaining('new notification'), findsNothing);
  });

  testWidgets(
    'the timer stops in the background and a resume refreshes at once',
    (tester) async {
      await pump(tester);
      lifecycle(AppLifecycleState.paused);
      final before = polls();
      await tester.pump(const Duration(seconds: 120));
      expect(polls(), before);

      repo.items.add(fakeNotification(id: 2));
      lifecycle(AppLifecycleState.resumed);
      await tester.pump();
      expect(polls(), before + 1);
      expect(find.text('You have a new notification'), findsOneWidget);

      await tester.pump(const Duration(seconds: 30)); // the timer runs again
      expect(polls(), before + 2);
    },
  );

  testWidgets(
    'a network error while polling keeps the badge and says nothing',
    (tester) async {
      await pump(tester);
      repo.countError = const ApiException(code: 'network_error');
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('admins are not polled', (tester) async {
    await pump(tester, role: UserRole.admin);
    await tester.pump(const Duration(seconds: 60));
    expect(polls(), 0);
  });

  testWidgets('keeps the reminders in sync for a patient', (tester) async {
    await pump(tester);
    await tester.pump();
    expect(reminders.resyncs, isNotEmpty);
  });

  testWidgets(
    'a new notification or a resume reloads the upcoming appointments',
    (tester) async {
      await pump(tester);
      await tester.pump();
      final loads = reminders.resyncs.length;

      repo.items.add(fakeNotification(id: 2)); // e.g. the doctor cancelled
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      await tester.pump();
      expect(reminders.resyncs.length, loads + 1);

      lifecycle(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(reminders.resyncs.length, loads + 2);
    },
  );

  testWidgets('switching account is no "increase": no snackbar', (
    tester,
  ) async {
    final accounts = ValueNotifier<int>(1);
    final byAccount = <int, FakeNotificationsRepository>{
      1: FakeNotificationsRepository(
        items: [fakeNotification(id: 1), fakeNotification(id: 2)],
      ),
      2: FakeNotificationsRepository(
        items: [for (var i = 1; i <= 5; i++) fakeNotification(id: i)],
      ),
    };
    final container = ProviderContainer(
      overrides: [
        ...await baseOverrides(),
        notificationsRepositoryProvider.overrideWith(
          (ref) => byAccount[ref.watch(currentUserIdProvider)]!,
        ),
        appointmentsRepositoryProvider.overrideWithValue(
          FakeAppointmentsRepository(),
        ),
        localRemindersProvider.overrideWithValue(reminders),
        currentUserIdProvider.overrideWith((ref) => accounts.value),
        currentUserProvider.overrideWith((ref) {
          ref.watch(currentUserIdProvider);
          return fakeUser();
        }),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: NotificationsHost(
            child: Scaffold(body: NotificationsNavIcon()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('2'), findsOneWidget);

    accounts.value = 2;
    container.invalidate(currentUserIdProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('5'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
