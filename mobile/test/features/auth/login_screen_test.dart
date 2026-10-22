import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/auth/data/auth_repository.dart';
import 'package:medical_appointments/features/auth/presentation/screens/login_screen.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/test_app.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late MockAuthRepository repo;

  Future<void> pump(WidgetTester tester, String language) async {
    repo = MockAuthRepository();
    when(() => repo.restoreSession()).thenAnswer((_) async => null);
    final overrides = [
      ...await baseOverrides(),
      authRepositoryProvider.overrideWithValue(repo),
    ];
    await tester.pumpWidget(
      testApp(
        const LoginScreen(),
        locale: Locale(language),
        overrides: overrides,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(FilledButton, label));
    await tester.pumpAndSettle();
  }

  testWidgets('empty form shows French validation messages', (tester) async {
    await pump(tester, 'fr');
    expect(find.text('Connexion'), findsOneWidget);
    await submit(tester, 'Se connecter');
    expect(find.text('Ce champ est obligatoire.'), findsNWidgets(2));
  });

  testWidgets('empty form shows English validation messages', (tester) async {
    await pump(tester, 'en');
    expect(find.text('Log in'), findsWidgets);
    await submit(tester, 'Log in');
    expect(find.text('This field is required.'), findsNWidgets(2));
  });

  testWidgets('an invalid email is explained in the current language', (
    tester,
  ) async {
    await pump(tester, 'fr');
    await tester.enterText(find.byType(TextFormField).first, 'not-an-email');
    await submit(tester, 'Se connecter');
    expect(find.text('Saisissez une adresse e-mail valide.'), findsOneWidget);
  });

  testWidgets('a server field error appears under the field', (tester) async {
    await pump(tester, 'en');
    when(() => repo.login(any(), any())).thenThrow(
      const ApiException(
        statusCode: 400,
        code: 'validation_error',
        fields: {
          'email': [ApiFieldError(code: 'invalid', message: 'server')],
        },
      ),
    );
    await tester.enterText(find.byType(TextFormField).first, 'a@b.co');
    await tester.enterText(find.byType(TextFormField).last, 'secret');
    await submit(tester, 'Log in');
    expect(find.text('This value is not valid.'), findsOneWidget);
  });

  testWidgets('a wrong password shows the translated 401 message', (
    tester,
  ) async {
    await pump(tester, 'fr');
    when(() => repo.login(any(), any())).thenThrow(
      const ApiException(
        statusCode: 401,
        code: 'authentication_failed',
        message: 'server',
      ),
    );
    await tester.enterText(find.byType(TextFormField).first, 'a@b.co');
    await tester.enterText(find.byType(TextFormField).last, 'secret');
    await submit(tester, 'Se connecter');
    expect(find.text('E-mail ou mot de passe incorrect.'), findsOneWidget);
  });
}
