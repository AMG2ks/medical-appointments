import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/notifications/data/models/app_notification.dart';
import 'package:medical_appointments/features/notifications/data/notifications_repository.dart';
import 'package:medical_appointments/features/notifications/presentation/screens/notifications_screen.dart';

import '../../support/fake_notifications_repository.dart';
import '../../support/fakes.dart';
import '../../support/test_app.dart';

void main() {
  late FakeNotificationsRepository repo;

  Future<void> pump(
    WidgetTester tester, {
    String language = 'en',
    UserRole role = UserRole.patient,
  }) async {
    final router = GoRouter(
      initialLocation: '/notifications',
      routes: [
        GoRoute(
          path: '/notifications',
          builder: (_, _) => const NotificationsScreen(),
        ),
        GoRoute(
          path: '/patient/appointments',
          builder: (_, _) => const Scaffold(body: Text('patient list')),
        ),
        GoRoute(
          path: '/doctor',
          builder: (_, _) => const Scaffold(body: Text('doctor list')),
        ),
        GoRoute(
          path: '/patient/appointments/:id',
          builder:
              (_, state) => Scaffold(
                body: Text('patient detail ${state.pathParameters['id']}'),
              ),
        ),
        GoRoute(
          path: '/doctor/appointments/:id',
          builder:
              (_, state) => Scaffold(
                body: Text('doctor detail ${state.pathParameters['id']}'),
              ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      testRouterApp(
        router,
        locale: Locale(language),
        overrides: [
          ...await baseOverrides(),
          notificationsRepositoryProvider.overrideWithValue(repo),
          currentUserIdProvider.overrideWithValue(1),
          currentUserProvider.overrideWithValue(fakeUser(role: role)),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => repo = FakeNotificationsRepository());

  testWidgets('empty state', (tester) async {
    await pump(tester);
    expect(find.text('No notifications yet.'), findsOneWidget);
  });

  testWidgets('error with retry', (tester) async {
    repo.listError = const ApiException(code: 'network_error');
    await pump(tester);
    expect(
      find.text('Cannot reach the server. Check your connection.'),
      findsOneWidget,
    );
    repo.listError = null;
    repo.items.add(fakeNotification());
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Appointment confirmed'), findsOneWidget);
  });

  testWidgets('texts are built from kind + data, in English', (tester) async {
    repo.items.addAll([
      fakeNotification(id: 4, kind: NotificationKind.appointmentReminder),
      fakeNotification(
        id: 3,
        kind: NotificationKind.appointmentCancelled,
        cancelledBy: 'doctor',
        reason: 'Congé',
        read: true,
      ),
      fakeNotification(
        id: 2,
        kind: NotificationKind.appointmentCancelled,
        cancelledBy: 'admin',
        read: true,
      ),
      fakeNotification(id: 1, kind: NotificationKind.unknown, read: true),
    ]);
    await pump(tester);

    expect(find.text('Appointment reminder'), findsOneWidget);
    expect(find.textContaining('With Dr Sarah Miller on'), findsOneWidget);
    expect(
      find.textContaining(
        'Dr Sarah Miller cancelled your appointment planned for',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Cancellation reason: Congé'), findsOneWidget);
    expect(
      find.textContaining(
        'The clinic cancelled your appointment with Dr Sarah Miller',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Update the app to read this notification.'),
      findsOneWidget,
    );
  });

  testWidgets('the same data reads in French when the language changes', (
    tester,
  ) async {
    repo.items.add(fakeNotification());
    await pump(tester, language: 'fr');
    expect(find.text('Rendez-vous confirmé'), findsOneWidget);
    expect(find.textContaining('Avec le Dr Sarah Miller le'), findsOneWidget);
    expect(find.textContaining('nov.'), findsWidgets);
  });

  testWidgets('a doctor reads a patient cancellation / clinic cancellation', (
    tester,
  ) async {
    repo.items.addAll([
      fakeNotification(
        id: 2,
        kind: NotificationKind.appointmentCancelled,
        cancelledBy: 'patient',
      ),
      fakeNotification(
        id: 1,
        kind: NotificationKind.appointmentCancelled,
        cancelledBy: 'admin',
      ),
    ]);
    await pump(tester, role: UserRole.doctor);
    expect(
      find.textContaining(
        'Amira Ben Salah cancelled the appointment planned for',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'The clinic cancelled your appointment with Amira Ben Salah',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tap marks it read and opens the appointment of the role', (
    tester,
  ) async {
    repo.items.add(fakeNotification(id: 5, appointmentId: 77));
    await pump(tester);
    await tester.tap(find.text('Appointment confirmed'));
    await tester.pumpAndSettle();
    expect(repo.calls, contains('markRead 5'));
    expect(find.text('patient detail 77'), findsOneWidget);
  });

  testWidgets('a doctor is sent to the doctor routes', (tester) async {
    repo.items.add(
      fakeNotification(
        id: 5,
        kind: NotificationKind.appointmentBooked,
        appointmentId: 8,
      ),
    );
    await pump(tester, role: UserRole.doctor);
    await tester.tap(find.text('New appointment'));
    await tester.pumpAndSettle();
    expect(find.text('doctor detail 8'), findsOneWidget);
  });

  testWidgets('mark all as read', (tester) async {
    repo.items.addAll([fakeNotification(id: 2), fakeNotification(id: 1)]);
    await pump(tester);
    await tester.tap(find.text('Mark all as read'));
    await tester.pumpAndSettle();
    expect(repo.calls, contains('markAllRead'));
    expect(
      find.text('Mark all as read'),
      findsNothing,
    ); // nothing unread any more
  });

  testWidgets('load more appends the next page', (tester) async {
    repo = FakeNotificationsRepository(
      items: [for (var i = 3; i > 0; i--) fakeNotification(id: i)],
      pageSize: 2,
    );
    await pump(tester);
    expect(find.text('Appointment confirmed'), findsNWidgets(2));
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('Appointment confirmed'), findsNWidgets(3));
  });
}
