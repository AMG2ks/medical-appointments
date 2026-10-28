import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/app/app.dart';
import 'package:medical_appointments/core/l10n/locale_controller.dart';
import 'package:medical_appointments/features/appointments/data/appointments_repository.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/dashboard/data/dashboard_repository.dart';
import 'package:medical_appointments/features/dashboard/data/models/dashboard_stats.dart';
import 'package:medical_appointments/features/doctors/data/doctors_repository.dart';
import 'package:medical_appointments/features/notifications/data/notifications_repository.dart';
import 'package:medical_appointments/features/notifications/local_reminders.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../features/dashboard/dashboard_test.dart' show statsJson;
import '../support/fake_appointments_repository.dart';
import '../support/fake_doctors_repository.dart';
import '../support/fake_local_reminders.dart';
import '../support/fake_notifications_repository.dart';
import '../support/fakes.dart';
import '../support/test_app.dart';

class FakeAuth extends AuthController {
  FakeAuth(this.role);

  final UserRole role;

  @override
  Future<User?> build() async => fakeUser(role: role);
}

/// Starts logged out; `signIn()` is what a successful login does to the state.
class FakeLoggedOutAuth extends AuthController {
  @override
  Future<User?> build() async => null;

  void signIn(UserRole role) => state = AsyncData(fakeUser(role: role));

  void signOut() => state = const AsyncData(null);
}

class FakeDashboard implements DashboardRepository {
  @override
  Future<DashboardStats> stats() async => DashboardStats.fromJson(statsJson);
}

/// The real app (router, shells, host, screens) with fake repositories.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  required UserRole role,
  String device = 'en',
  FakeAppointmentsRepository? appointments,
  bool loggedOut = false,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...await baseOverrides(device: Locale(device)),
        authControllerProvider.overrideWith(
          () => loggedOut ? FakeLoggedOutAuth() : FakeAuth(role),
        ),
        doctorsRepositoryProvider.overrideWithValue(FakeDoctorsRepository()),
        appointmentsRepositoryProvider.overrideWithValue(
          appointments ?? FakeAppointmentsRepository(),
        ),
        notificationsRepositoryProvider.overrideWithValue(
          FakeNotificationsRepository(
            items: [fakeNotification(id: 2), fakeNotification(id: 1)],
          ),
        ),
        dashboardRepositoryProvider.overrideWithValue(FakeDashboard()),
        localRemindersProvider.overrideWithValue(FakeLocalReminders()),
      ],
      child: const App(),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(App)));
}

void main() {
  testWidgets('book, read notifications, switch language, tab around: '
      'every tab keeps working and nothing throws', (tester) async {
    final container = await pumpApp(tester, role: UserRole.patient);

    // Doctors tab -> doctor -> booking flow (above the tab bar) -> confirm.
    await tester.tap(find.text('Sarah Miller'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book an appointment'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing); // modal flow
    await tester.tap(find.text('09:30'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm the appointment'));
    await tester.tap(find.text('Confirm the appointment'));
    await tester.pumpAndSettle();

    // Landed on the new appointment, in the Appointments tab, tab bar back.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Appointment'), findsWidgets);
    expect(find.text('Sarah Miller'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Notifications tab: mark all as read.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Notifications'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark all as read'));
    await tester.pumpAndSettle();

    // Language switch (what the profile screen does through the locale controller).
    container.read(localeControllerProvider.notifier).applyServerLanguage('fr');
    await tester.pumpAndSettle();

    // Doctors tab: back where we were (list or detail, but not blank).
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Médecins'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sarah Miller'), findsOneWidget);

    // Appointments tab: still the detail; back goes to the list; tapping works again.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Rendez-vous'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sarah Miller'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Sarah Miller'), findsOneWidget); // the list row
    await tester.tap(find.text('Sarah Miller'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final role in UserRole.values) {
    testWidgets('logging in as ${role.name} builds the shell without errors', (
      tester,
    ) async {
      // Regression: "setState() or markNeedsBuild() called during build" on every login.
      final container = await pumpApp(tester, role: role, loggedOut: true);
      expect(find.byType(NavigationBar), findsNothing);
      (container.read(authControllerProvider.notifier) as FakeLoggedOutAuth)
          .signIn(role);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);

      // ... and again after a logout: the providers of the first session still exist.
      final auth = container.read(authControllerProvider.notifier);
      (auth as FakeLoggedOutAuth).signOut();
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      auth.signIn(role);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a notification opens its appointment in the Appointments tab', (
    tester,
  ) async {
    final appointments = FakeAppointmentsRepository(
      appointments: [fakeAppointment(id: 7)],
    );
    await pumpApp(tester, role: UserRole.patient, appointments: appointments);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Notifications'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appointment confirmed').first);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Sarah Miller'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // Tests use a fixed-width font, so wrapping cannot be measured here. Guard the cause
  // instead: with 5 tabs on a 360dp phone each label has ~72dp, about 13 characters at 12sp.
  test('every tab label fits a 5-tab bar in both languages', () {
    for (final code in ['fr', 'en']) {
      final l10n = lookupAppLocalizations(Locale(code));
      final labels = {
        l10n.navDoctors,
        l10n.navAppointments,
        l10n.navAgenda,
        l10n.navAvailability,
        l10n.navPractice,
        l10n.navNotifications,
        l10n.navProfile,
        l10n.navUsers,
        l10n.navSpecialties,
        l10n.navDashboard,
      };
      for (final label in labels) {
        expect(
          label.length,
          lessThanOrEqualTo(14),
          reason: '"$label" ($code) is too long for a tab',
        );
        expect(
          label,
          isNot(contains(' ')),
          reason: '"$label" ($code) would wrap',
        );
      }
    }
  });
}
