import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/auth/data/auth_repository.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/auth/presentation/screens/forgot_password_screen.dart';
import 'package:medical_appointments/features/auth/presentation/screens/profile_screen.dart';
import 'package:medical_appointments/features/auth/presentation/screens/reset_password_screen.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fakes.dart';
import '../../support/test_app.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late MockAuthRepository repo;

  setUp(() {
    repo = MockAuthRepository();
    when(() => repo.restoreSession()).thenAnswer((_) async => null);
  });

  Future<List<Override>> overrides() async => [
    ...await baseOverrides(),
    authRepositoryProvider.overrideWithValue(repo),
  ];

  GoRouter routerFor(Widget home) => GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => home),
      GoRoute(
        path: '/reset-password',
        builder:
            (_, state) => Text('RESET ${state.uri.queryParameters['email']}'),
      ),
    ],
  );

  testWidgets('forgot password: validates, sends the code, opens reset', (
    tester,
  ) async {
    when(() => repo.requestPasswordReset(any())).thenAnswer((_) async {});
    await tester.pumpWidget(
      testRouterApp(
        routerFor(const ForgotPasswordScreen()),
        locale: const Locale('fr'),
        overrides: await overrides(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Envoyer le code'));
    await tester.pumpAndSettle();
    expect(find.text('Ce champ est obligatoire.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'a@b.co');
    await tester.tap(find.widgetWithText(FilledButton, 'Envoyer le code'));
    await tester.pumpAndSettle();
    verify(() => repo.requestPasswordReset('a@b.co')).called(1);
    expect(find.text('RESET a@b.co'), findsOneWidget);
  });

  testWidgets('reset password: mismatch is explained, bad code is translated', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(
        const ResetPasswordScreen(email: 'a@b.co'),
        locale: const Locale('en'),
        overrides: await overrides(),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), '123456');
    await tester.enterText(fields.at(2), 'S3cure-pass!');
    await tester.enterText(fields.at(3), 'different-pass');
    await tester.tap(find.widgetWithText(FilledButton, 'Set the password'));
    await tester.pumpAndSettle();
    expect(find.text('The passwords do not match.'), findsOneWidget);

    when(
      () => repo.confirmPasswordReset(
        email: any(named: 'email'),
        code: any(named: 'code'),
        newPassword: any(named: 'newPassword'),
      ),
    ).thenThrow(const ApiException(statusCode: 400, code: 'invalid_code'));
    await tester.enterText(fields.at(3), 'S3cure-pass!');
    await tester.tap(find.widgetWithText(FilledButton, 'Set the password'));
    await tester.pumpAndSettle();
    expect(find.text('The code is invalid or has expired.'), findsOneWidget);
  });

  testWidgets('profile: shows the account, validates and saves', (
    tester,
  ) async {
    when(() => repo.restoreSession()).thenAnswer((_) async => fakeUser());
    when(() => repo.updateProfile(any())).thenAnswer((_) async => fakeUser());
    final container = makeContainer([...await overrides()]);
    await container.read(authControllerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('fr'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: ProfileScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('amira@example.com'), findsOneWidget);
    expect(find.text('Patient'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '');
    await tester.tap(find.widgetWithText(FilledButton, 'Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Ce champ est obligatoire.'), findsOneWidget);
    verifyNever(() => repo.updateProfile(any()));

    await tester.enterText(find.byType(TextFormField).first, 'Amira');
    await tester.tap(find.widgetWithText(FilledButton, 'Enregistrer'));
    await tester.pumpAndSettle();
    verify(() => repo.updateProfile(any())).called(1);
    expect(find.text('Profil enregistré.'), findsOneWidget);
  });
}
