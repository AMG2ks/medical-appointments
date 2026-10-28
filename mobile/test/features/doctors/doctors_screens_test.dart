import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/doctors/data/models/time_off.dart';
import 'package:medical_appointments/features/doctors/data/doctors_repository.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/availability_screen.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/create_doctor_screen.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/specialties_admin_screen.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/time_off_screen.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/doctor_detail_screen.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/doctor_profile_screen.dart';
import 'package:medical_appointments/features/doctors/presentation/screens/doctors_list_screen.dart';
import 'package:medical_appointments/l10n/gen/app_localizations_en.dart';

import '../../support/fake_doctors_repository.dart';
import '../../support/test_app.dart';

void main() {
  late FakeDoctorsRepository repo;

  Future<List<dynamic>> overrides() async => [
    ...await baseOverrides(),
    doctorsRepositoryProvider.overrideWithValue(repo),
    currentUserIdProvider.overrideWithValue(1),
  ];

  group('doctors list', () {
    setUp(() {
      repo = FakeDoctorsRepository(
        doctors: [
          fakeDoctor(
            id: 1,
            firstName: 'Amira',
            lastName: 'Zouari',
            specialty: dermatology,
          ),
          fakeDoctor(id: 2, firstName: 'Sarah', lastName: 'Miller'),
        ],
      );
    });

    Future<void> pump(WidgetTester tester, String language) async {
      await tester.pumpWidget(
        testApp(
          DoctorsListScreen(detailPath: (id) => '/doctors/$id'),
          locale: Locale(language),
          overrides: List.from(await overrides()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows specialty names in French', (tester) async {
      await pump(tester, 'fr');
      expect(find.text('Médecins'), findsOneWidget);
      expect(find.text('Dermatologie'), findsNWidgets(2)); // chip + card
      expect(find.text('Cardiologie'), findsNWidgets(2));
      expect(find.text('Dermatology'), findsNothing);
    });

    testWidgets('shows specialty names in English', (tester) async {
      await pump(tester, 'en');
      expect(find.text('Dermatology'), findsNWidgets(2));
      expect(find.text('Dermatologie'), findsNothing);
    });

    testWidgets('tapping a specialty chip filters the list', (tester) async {
      await pump(tester, 'en');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Dermatology'));
      await tester.pumpAndSettle();
      expect(find.text('Amira Zouari'), findsOneWidget);
      expect(find.text('Sarah Miller'), findsNothing);
    });

    testWidgets('searching by name filters the list', (tester) async {
      await pump(tester, 'en');
      await tester.enterText(find.byType(TextField), 'mill');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('Sarah Miller'), findsOneWidget);
      expect(find.text('Amira Zouari'), findsNothing);
    });

    testWidgets('an empty result shows the empty state', (tester) async {
      await pump(tester, 'en');
      await tester.enterText(find.byType(TextField), 'nobody');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text(AppLocalizationsEn().doctorsEmpty), findsOneWidget);
    });
  });

  group('doctor detail', () {
    setUp(() => repo = FakeDoctorsRepository());

    Future<void> pump(WidgetTester tester, {required bool canBook}) async {
      await tester.pumpWidget(
        testApp(
          DoctorDetailScreen(doctorId: 10, canBook: canBook),
          locale: const Locale('en'),
          overrides: List.from(await overrides()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('patient sees the doctor and a Book button', (tester) async {
      await pump(tester, canBook: true);
      expect(find.text('Sarah Miller'), findsOneWidget);
      expect(find.text('Cardiology'), findsOneWidget);
      expect(find.text('Bio of the doctor.'), findsOneWidget);
      expect(find.text('Book an appointment'), findsOneWidget);
    });

    testWidgets('no Book button for other roles', (tester) async {
      await pump(tester, canBook: false);
      expect(find.text('Book an appointment'), findsNothing);
    });

    testWidgets('Book opens the booking route', (tester) async {
      final router = GoRouter(
        initialLocation: '/doctors/10',
        routes: [
          GoRoute(
            path: '/doctors/:id',
            builder:
                (_, _) => const DoctorDetailScreen(doctorId: 10, canBook: true),
          ),
          GoRoute(
            path: '/patient/doctors/10/book',
            builder: (_, _) => const Scaffold(body: Text('booking flow')),
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
      await tester.tap(find.text('Book an appointment'));
      await tester.pumpAndSettle();
      expect(find.text('booking flow'), findsOneWidget);
    });
  });

  group('availability editor', () {
    setUp(() => repo = FakeDoctorsRepository());

    Future<void> pump(WidgetTester tester, String language) async {
      await tester.pumpWidget(
        testApp(
          const AvailabilityScreen(),
          locale: Locale(language),
          overrides: List.from(await overrides()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> addDefaultHours(
      WidgetTester tester,
      String addLabel,
      String saveLabel,
    ) async {
      await tester.tap(find.text(addLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, saveLabel));
      await tester.pumpAndSettle();
    }

    testWidgets('empty state, then a window appears with a localized weekday', (
      tester,
    ) async {
      await pump(tester, 'fr');
      expect(
        find.text('Aucune disponibilité. Ajoutez vos horaires de travail.'),
        findsOneWidget,
      );
      await addDefaultHours(tester, 'Ajouter des horaires', 'Enregistrer');
      expect(find.text('lundi'), findsOneWidget);
      expect(repo.availability, hasLength(1));
    });

    testWidgets('an overlap is explained inside the dialog', (tester) async {
      await pump(tester, 'en');
      await addDefaultHours(tester, 'Add hours', 'Save');
      await addDefaultHours(
        tester,
        'Add hours',
        'Save',
      ); // same Monday window again
      expect(
        find.text('These hours overlap an existing availability.'),
        findsOneWidget,
      );
      expect(repo.availability, hasLength(1));
    });
  });

  group('doctor profile form', () {
    setUp(() => repo = FakeDoctorsRepository());

    testWidgets('rejects an out-of-range duration, then saves', (tester) async {
      await tester.pumpWidget(
        testApp(
          const DoctorProfileScreen(),
          locale: const Locale('en'),
          overrides: List.from(await overrides()),
        ),
      );
      await tester.pumpAndSettle();
      final minutes = find.widgetWithText(TextFormField, '30');
      await tester.enterText(minutes, '2');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a number between 5 and 240.'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, '2'), '45');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(repo.doctors.first.consultationMinutes, 45);
      expect(find.text('Professional profile saved.'), findsOneWidget);
    });
  });

  group('create doctor (admin)', () {
    setUp(() => repo = FakeDoctorsRepository(doctors: []));

    Future<GoRouter> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
          GoRoute(
            path: '/create',
            builder: (_, _) => const CreateDoctorScreen(),
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
      router.push('/create');
      await tester.pumpAndSettle();
      return router;
    }

    Future<void> fill(WidgetTester tester) async {
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'new.doc@example.com');
      await tester.enterText(fields.at(1), 'New');
      await tester.enterText(fields.at(2), 'Doc');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cardiology').last);
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester) async {
      await tester.tap(find.text('Create doctor'));
      await tester.pumpAndSettle();
    }

    testWidgets('an empty form is explained and nothing is sent', (
      tester,
    ) async {
      await pump(tester);
      await submit(tester);
      expect(find.text('This field is required.'), findsNWidgets(4));
      expect(repo.doctors, isEmpty);
    });

    testWidgets('a valid form creates the doctor and goes back', (
      tester,
    ) async {
      await pump(tester);
      await fill(tester);
      await submit(tester);
      expect(repo.doctors.single.lastName, 'Doc');
      expect(repo.doctors.single.specialty.id, cardiology.id);
      expect(find.text('home'), findsOneWidget);
      expect(
        find.text('Doctor created. An invitation email was sent.'),
        findsOneWidget,
      );
    });

    testWidgets('a duplicate email is shown under the email field', (
      tester,
    ) async {
      repo.createDoctorError = const ApiException(
        statusCode: 400,
        code: 'validation_error',
        fields: {
          'email': [ApiFieldError(code: 'unique', message: 'server')],
        },
      );
      await pump(tester);
      await fill(tester);
      await submit(tester);
      expect(find.text('This value is already used.'), findsOneWidget);
      expect(
        find.text('Doctor created. An invitation email was sent.'),
        findsNothing,
      );
    });

    testWidgets('a specialties load failure shows an error with retry', (
      tester,
    ) async {
      repo.listSpecialtiesError = const ApiException(code: 'network_error');
      await pump(tester);
      expect(
        find.text('Cannot reach the server. Check your connection.'),
        findsOneWidget,
      );
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);

      repo.listSpecialtiesError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    });
  });

  group('specialties admin', () {
    setUp(() => repo = FakeDoctorsRepository());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        testApp(
          const SpecialtiesAdminScreen(),
          locale: const Locale('en'),
          overrides: List.from(await overrides()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('lists both names of every specialty', (tester) async {
      await pump(tester);
      expect(find.text('Cardiologie'), findsOneWidget);
      expect(find.text('Cardiology'), findsOneWidget);
      expect(find.text('Dermatologie'), findsOneWidget);
    });

    testWidgets('adds a specialty (both names required)', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Add a specialty'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('This field is required.'), findsNWidgets(2));

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Pédiatrie');
      await tester.enterText(fields.at(1), 'Pediatrics');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Pédiatrie'), findsOneWidget);
      expect(repo.specialties, hasLength(3));
    });

    testWidgets('renames a specialty', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Cardiologie'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(1), 'Heart');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Heart'), findsOneWidget);
    });

    testWidgets('deleting a specialty in use explains why', (tester) async {
      await pump(tester); // the default fake doctor uses cardiology
      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(
        find.text('This specialty is used by doctors and cannot be deleted.'),
        findsOneWidget,
      );
      expect(find.text('Cardiologie'), findsOneWidget);
    });

    testWidgets('an unused specialty is deleted', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Delete').last); // dermatology
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Dermatologie'), findsNothing);
    });
  });

  group('time off', () {
    setUp(() => repo = FakeDoctorsRepository());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        testApp(
          const TimeOffScreen(),
          locale: const Locale('en'),
          overrides: List.from(await overrides()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('empty state', (tester) async {
      await pump(tester);
      expect(find.text('No time off planned.'), findsOneWidget);
    });

    testWidgets('whole days show as a date range ending on the last day', (
      tester,
    ) async {
      repo.timeOff.addAll([
        TimeOff(
          id: 1,
          startAt: DateTime(2026, 12, 24),
          endAt: DateTime(2026, 12, 27),
          reason: 'Holidays',
        ),
        TimeOff(
          id: 2,
          startAt: DateTime(2026, 12, 30),
          endAt: DateTime(2026, 12, 31),
          reason: '',
        ),
      ]);
      await pump(tester);
      expect(find.text('Dec 24, 2026 → Dec 26, 2026'), findsOneWidget);
      expect(find.text('Holidays'), findsOneWidget);
      expect(find.text('Dec 30, 2026'), findsOneWidget); // one day: no range
    });

    testWidgets('deletes an entry after confirmation', (tester) async {
      repo.timeOff.add(
        TimeOff(
          id: 1,
          startAt: DateTime(2026, 12, 24),
          endAt: DateTime(2026, 12, 25),
          reason: '',
        ),
      );
      await pump(tester);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(repo.timeOff, isEmpty);
      expect(find.text('No time off planned.'), findsOneWidget);
    });

    testWidgets('the add dialog cannot be saved before dates are chosen', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('Add time off'));
      await tester.pumpAndSettle();
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save.onPressed, isNull);
      expect(find.text('Choose the dates'), findsOneWidget);
    });
  });
}
