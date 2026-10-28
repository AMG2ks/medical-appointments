import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/appointments/data/appointments_repository.dart';
import 'package:medical_appointments/features/appointments/data/models/appointment.dart';
import 'package:medical_appointments/features/appointments/presentation/screens/appointment_detail_screen.dart';
import 'package:medical_appointments/features/appointments/presentation/screens/appointments_tabs_screen.dart';
import 'package:medical_appointments/features/appointments/presentation/screens/booking_screen.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/doctors/data/doctors_repository.dart';
import 'package:medical_appointments/features/doctors/data/models/time_off.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/time_off_screen.dart';
import 'package:medical_appointments/features/notifications/local_reminders.dart';

import '../../support/fake_appointments_repository.dart';
import '../../support/fake_doctors_repository.dart';
import '../../support/fake_local_reminders.dart';
import '../../support/fakes.dart';
import '../../support/test_app.dart';

void main() {
  late FakeAppointmentsRepository repo;
  late FakeLocalReminders reminders;

  setUp(() => reminders = FakeLocalReminders());

  Future<List<dynamic>> overrides({UserRole role = UserRole.patient}) async => [
    ...await baseOverrides(),
    appointmentsRepositoryProvider.overrideWithValue(repo),
    doctorsRepositoryProvider.overrideWithValue(FakeDoctorsRepository()),
    currentUserIdProvider.overrideWithValue(1),
    currentUserProvider.overrideWithValue(fakeUser(role: role)),
    localRemindersProvider.overrideWithValue(reminders),
  ];

  Future<void> pumpRouter(
    WidgetTester tester,
    String initial,
    List<GoRoute> routes, {
    String language = 'en',
    UserRole role = UserRole.patient,
  }) async {
    final router = GoRouter(initialLocation: initial, routes: routes);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      testRouterApp(
        router,
        locale: Locale(language),
        overrides: List.from(await overrides(role: role)),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('booking flow', () {
    setUp(() => repo = FakeAppointmentsRepository());

    Future<void> pump(WidgetTester tester, {String language = 'en'}) =>
        pumpRouter(tester, '/book', [
          GoRoute(
            path: '/book',
            builder: (_, _) => const BookingScreen(doctorId: 10),
          ),
          GoRoute(
            path: '/patient/appointments/:id',
            builder:
                (_, state) => Scaffold(
                  body: Text('detail ${state.pathParameters['id']}'),
                ),
          ),
        ], language: language);

    testWidgets('date, slot grid, confirm: books the chosen slot', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Sarah Miller'), findsOneWidget);
      expect(find.text('09:00'), findsOneWidget);
      expect(find.text('09:30'), findsOneWidget);
      expect(find.text('Confirm the appointment'), findsNothing);

      await tester.tap(find.text('09:30'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Cough');
      await tester.ensureVisible(find.text('Confirm the appointment'));
      await tester.tap(find.text('Confirm the appointment'));
      await tester.pumpAndSettle();

      expect(
        repo.calls.where((c) => c.startsWith('book')).single,
        'book doctor=10 start=2026-11-05T09:30:00+01:00 reason=Cough',
      );
      expect(find.textContaining('detail 500'), findsOneWidget);
      // First booking: the notification permission is asked in context.
      expect(reminders.permissionRequests, 1);
    });

    testWidgets('slot_taken shows the message and reloads the slots', (
      tester,
    ) async {
      await pump(tester);
      repo.bookError = const ApiException(statusCode: 409, code: 'slot_taken');
      await tester.tap(find.text('09:00'));
      await tester.pumpAndSettle();
      final slotCalls = repo.calls.where((c) => c.startsWith('slots')).length;
      await tester.ensureVisible(find.text('Confirm the appointment'));
      await tester.tap(find.text('Confirm the appointment'));
      await tester.pumpAndSettle();

      expect(
        find.text('This time was just taken. Please choose another one.'),
        findsOneWidget,
      );
      expect(
        repo.calls.where((c) => c.startsWith('slots')).length,
        greaterThan(slotCalls),
      );
      expect(
        find.text('Confirm the appointment'),
        findsNothing,
      ); // selection cleared
    });

    testWidgets('no free slot: empty message', (tester) async {
      repo.freeSlots = [];
      await pump(tester);
      expect(
        find.text('No free time on this day. Try another date.'),
        findsOneWidget,
      );
    });

    testWidgets('slots failing shows the error with a working retry', (
      tester,
    ) async {
      repo.slotsError = const ApiException(code: ApiException.networkError);
      await pump(tester);
      expect(
        find.text('Cannot reach the server. Check your connection.'),
        findsOneWidget,
      );
      repo.slotsError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('09:00'), findsOneWidget);
    });

    testWidgets('French labels', (tester) async {
      await pump(tester, language: 'fr');
      expect(find.text('Prendre rendez-vous'), findsOneWidget);
      expect(find.text('Horaires disponibles'), findsOneWidget);
    });
  });

  group('my appointments (patient)', () {
    Future<void> pump(WidgetTester tester, {String language = 'en'}) =>
        pumpRouter(tester, '/patient/appointments', [
          GoRoute(
            path: '/patient/appointments',
            builder:
                (_, _) => MyAppointmentsScreen(
                  detailPath: (id) => '/patient/appointments/$id',
                ),
          ),
          GoRoute(
            path: '/patient/appointments/:id',
            builder:
                (_, state) => AppointmentDetailScreen(
                  appointmentId: int.parse(state.pathParameters['id']!),
                ),
          ),
        ], language: language);

    setUp(() {
      repo = FakeAppointmentsRepository(
        appointments: [
          fakeAppointment(
            id: 1,
            startAt: DateTime.now().toUtc().add(const Duration(days: 4)),
          ),
          fakeAppointment(
            id: 2,
            startAt: DateTime.now().toUtc().subtract(const Duration(days: 4)),
            status: AppointmentStatus.completed,
            doctorName: 'Karim Haddad',
          ),
        ],
      );
    });

    testWidgets('upcoming and past tabs', (tester) async {
      await pump(tester);
      expect(find.text('Sarah Miller'), findsOneWidget);
      expect(find.text('Karim Haddad'), findsNothing);
      expect(find.text('Confirmed'), findsOneWidget);
      await tester.tap(find.text('Past'));
      await tester.pumpAndSettle();
      expect(find.text('Karim Haddad'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
    });

    testWidgets('empty state per tab', (tester) async {
      repo.appointments.clear();
      await pump(tester);
      expect(find.text('No upcoming appointments.'), findsOneWidget);
      await tester.tap(find.text('Past'));
      await tester.pumpAndSettle();
      expect(find.text('No past appointments.'), findsOneWidget);
    });

    testWidgets('error with retry', (tester) async {
      repo.listError = const ApiException(code: ApiException.networkError);
      await pump(tester);
      expect(find.text('Retry'), findsOneWidget);
      repo.listError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Sarah Miller'), findsOneWidget);
    });

    testWidgets('French tabs', (tester) async {
      await pump(tester, language: 'fr');
      expect(find.text('Mes rendez-vous'), findsOneWidget);
      expect(find.text('À venir'), findsOneWidget);
      expect(find.text('Passés'), findsOneWidget);
    });

    testWidgets('open the detail and cancel with a reason', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Sarah Miller'));
      await tester.pumpAndSettle();
      expect(find.text('Appointment'), findsOneWidget);
      expect(find.text('Cardiology'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Cancel the appointment'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Sick');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Cancel the appointment'),
      );
      await tester.pumpAndSettle();
      expect(repo.calls, contains('cancel 1 reason=Sick'));
      expect(find.text('Appointment cancelled.'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      // No more actions on a cancelled appointment.
      expect(
        find.widgetWithText(OutlinedButton, 'Cancel the appointment'),
        findsNothing,
      );
    });

    testWidgets('cancellation_too_late stays in the dialog', (tester) async {
      repo.actionError = const ApiException(
        statusCode: 400,
        code: 'cancellation_too_late',
      );
      await pump(tester);
      await tester.tap(find.text('Sarah Miller'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Cancel the appointment'),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Cancel the appointment'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'It is too late to cancel online. Please contact the doctor.',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancel this appointment?'), findsOneWidget);
    });

    testWidgets('a started appointment has no action for the patient', (
      tester,
    ) async {
      repo.appointments.add(
        fakeAppointment(
          id: 3,
          startAt: DateTime.now().toUtc().subtract(const Duration(minutes: 10)),
        ),
      );
      await pumpRouter(tester, '/a/3', [
        GoRoute(
          path: '/a/:id',
          builder: (_, _) => const AppointmentDetailScreen(appointmentId: 3),
        ),
      ]);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('doctor agenda and detail', () {
    setUp(() {
      repo = FakeAppointmentsRepository(
        appointments: [
          fakeAppointment(
            id: 1,
            startAt: DateTime.now().toUtc().add(const Duration(days: 2)),
          ),
          fakeAppointment(
            id: 2,
            startAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            patientName: 'John Smith',
          ),
        ],
      );
    });

    testWidgets('agenda shows patients in today / upcoming / past', (
      tester,
    ) async {
      await pumpRouter(tester, '/doctor', [
        GoRoute(
          path: '/doctor',
          builder:
              (_, _) => DoctorAgendaScreen(
                detailPath: (id) => '/doctor/appointments/$id',
              ),
        ),
      ], role: UserRole.doctor);
      expect(find.text('Agenda'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
      await tester.tap(find.text('Upcoming'));
      await tester.pumpAndSettle();
      expect(find.text('Amira Ben Salah'), findsOneWidget);
      await tester.tap(find.text('Past'));
      await tester.pumpAndSettle();
      expect(find.text('John Smith'), findsOneWidget);
    });

    Future<void> pumpDetail(WidgetTester tester, int id) =>
        pumpRouter(tester, '/a/$id', [
          GoRoute(
            path: '/a/:id',
            builder:
                (_, state) => AppointmentDetailScreen(
                  appointmentId: int.parse(state.pathParameters['id']!),
                ),
          ),
        ], role: UserRole.doctor);

    testWidgets('a started appointment: complete or no-show', (tester) async {
      await pumpDetail(tester, 2);
      expect(find.text('John Smith'), findsOneWidget);
      expect(find.text('Cancel the appointment'), findsNothing);
      await tester.tap(find.text('Mark as completed'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('complete 2'));
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Mark as completed'), findsNothing);
    });

    testWidgets('no-show', (tester) async {
      await pumpDetail(tester, 2);
      await tester.tap(find.text('Mark as no-show'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('noShow 2'));
      expect(find.text('No-show'), findsOneWidget);
    });

    testWidgets('a future appointment: cancel needs a reason', (tester) async {
      await pumpDetail(tester, 1);
      expect(find.text('Mark as completed'), findsNothing);
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Cancel the appointment'),
      );
      await tester.pumpAndSettle();
      FilledButton confirm() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Cancel the appointment'),
      );
      expect(confirm().onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Emergency');
      await tester.pump();
      expect(confirm().onPressed, isNotNull);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Cancel the appointment'),
      );
      await tester.pumpAndSettle();
      expect(repo.calls, contains('cancel 1 reason=Emergency'));
    });

    testWidgets('detail error shows retry', (tester) async {
      await pumpDetail(tester, 99);
      expect(find.text('Not found.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('after a booking (two tabs)', () {
    testWidgets('the booking screen does not stay alive in the Doctors tab', (
      tester,
    ) async {
      repo = FakeAppointmentsRepository();
      final router = GoRouter(
        initialLocation: '/patient/book',
        routes: [
          StatefulShellRoute.indexedStack(
            builder:
                (_, _, shell) => Scaffold(
                  body: shell,
                  bottomNavigationBar: NavigationBar(
                    selectedIndex: shell.currentIndex,
                    onDestinationSelected: shell.goBranch,
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.people),
                        label: 'Tab doctors',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.event),
                        label: 'Tab appointments',
                      ),
                    ],
                  ),
                ),
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/patient',
                    builder: (_, _) => const Text('doctors home'),
                    routes: [
                      GoRoute(
                        path: 'book',
                        builder: (_, _) => const BookingScreen(doctorId: 10),
                      ),
                    ],
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/patient/appointments',
                    builder: (_, _) => const Text('appointments list'),
                    routes: [
                      GoRoute(
                        path: ':id',
                        builder:
                            (_, state) =>
                                Text('detail ${state.pathParameters['id']}'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        testRouterApp(
          router,
          locale: const Locale('en'),
          overrides: List.from(await overrides()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('09:00'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Confirm the appointment'));
      await tester.tap(find.text('Confirm the appointment'));
      await tester.pumpAndSettle();
      expect(find.text('detail 500'), findsOneWidget);

      await tester.tap(find.text('Tab doctors'));
      await tester.pumpAndSettle();
      expect(find.byType(BookingScreen), findsNothing);
      expect(find.text('doctors home'), findsOneWidget);
    });
  });

  group('data changed by someone else', () {
    Future<void> pumpDetail(WidgetTester tester, int id, UserRole role) =>
        pumpRouter(tester, '/a/$id', [
          GoRoute(
            path: '/a/:id',
            builder:
                (_, state) => AppointmentDetailScreen(
                  appointmentId: int.parse(state.pathParameters['id']!),
                ),
          ),
        ], role: role);

    void changeExternally(int id, AppointmentStatus status) {
      final current = repo.appointments.firstWhere((a) => a.id == id);
      repo.appointments[repo.appointments.indexOf(current)] = fakeAppointment(
        id: id,
        startAt: current.startAt,
        status: status,
        cancelledByRole: 'doctor',
      );
    }

    testWidgets('pull to refresh reloads the detail', (tester) async {
      repo = FakeAppointmentsRepository(
        appointments: [
          fakeAppointment(
            id: 1,
            startAt: DateTime.now().toUtc().add(const Duration(days: 2)),
          ),
        ],
      );
      await pumpDetail(tester, 1, UserRole.patient);
      expect(find.text('Confirmed'), findsOneWidget);
      changeExternally(1, AppointmentStatus.cancelled);
      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Cancelled by the doctor.'), findsOneWidget);
    });

    testWidgets('a refused action reloads the detail', (tester) async {
      repo = FakeAppointmentsRepository(
        appointments: [
          fakeAppointment(
            id: 2,
            startAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
        ],
      );
      await pumpDetail(tester, 2, UserRole.doctor);
      changeExternally(2, AppointmentStatus.cancelled);
      repo.actionError = const ApiException(
        statusCode: 409,
        code: 'invalid_status_transition',
      );
      await tester.tap(find.text('Mark as completed'));
      await tester.pumpAndSettle();
      expect(
        find.text('This appointment cannot be changed this way.'),
        findsOneWidget,
      );
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Mark as completed'), findsNothing);
    });

    testWidgets('a double tap on Complete sends one request', (tester) async {
      final gated = _GatedRepository(
        appointments: [
          fakeAppointment(
            id: 2,
            startAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
        ],
      );
      repo = gated;
      await pumpDetail(tester, 2, UserRole.doctor);
      await tester.tap(find.text('Mark as completed'));
      await tester.pump();
      await tester.tap(find.text('Mark as completed'), warnIfMissed: false);
      await tester.pump();
      expect(repo.calls.where((c) => c == 'complete 2'), hasLength(1));
      gated.gate.complete();
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c == 'complete 2'), hasLength(1));
    });

    testWidgets('an empty list can be pulled to refresh', (tester) async {
      repo = FakeAppointmentsRepository();
      await pumpRouter(tester, '/p', [
        GoRoute(
          path: '/p',
          builder: (_, _) => MyAppointmentsScreen(detailPath: (id) => '/x/$id'),
        ),
      ]);
      expect(find.text('No upcoming appointments.'), findsOneWidget);
      repo.appointments.add(fakeAppointment(id: 9));
      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(find.text('Sarah Miller'), findsOneWidget);
    });

    testWidgets('an unknown status is shown but offers no action', (
      tester,
    ) async {
      repo = FakeAppointmentsRepository(
        appointments: [
          fakeAppointment(
            id: 3,
            startAt: DateTime.now().toUtc().add(const Duration(days: 2)),
            status: AppointmentStatus.unknown,
          ),
        ],
      );
      await pumpDetail(tester, 3, UserRole.patient);
      expect(find.text('Unknown'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('time off conflict list', () {
    testWidgets('shows the blocking appointments and the remainder', (
      tester,
    ) async {
      final conflict = TimeOffConflict(
        count: 4,
        items: [
          ConflictingAppointment(
            id: 1,
            startAt: DateTime(2026, 11, 5, 10),
            patientName: 'Pat Ient',
          ),
          ConflictingAppointment(
            id: 2,
            startAt: DateTime(2026, 11, 5, 11),
            patientName: 'Amira Ben Salah',
          ),
        ],
      );
      repo = FakeAppointmentsRepository();
      await tester.pumpWidget(
        testApp(
          Scaffold(body: TimeOffConflictList(conflict: conflict)),
          locale: const Locale('en'),
          overrides: List.from(await overrides()),
        ),
      );
      expect(find.text('Appointments in this period'), findsOneWidget);
      expect(find.text('Nov 5, 2026 10:00 · Pat Ient'), findsOneWidget);
      expect(find.text('Nov 5, 2026 11:00 · Amira Ben Salah'), findsOneWidget);
      expect(find.text('and 2 more'), findsOneWidget);
    });
  });
}

/// `complete` waits until the test releases [gate].
class _GatedRepository extends FakeAppointmentsRepository {
  _GatedRepository({super.appointments});

  final gate = Completer<void>();

  @override
  Future<Appointment> complete(int id) async {
    final result = super.complete(id);
    await gate.future;
    return result;
  }
}
