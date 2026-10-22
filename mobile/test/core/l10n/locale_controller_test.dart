import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/l10n/locale_controller.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/auth/data/auth_repository.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fakes.dart';
import '../../support/test_app.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  group('start-up order', () {
    test('stored choice wins', () async {
      final c = makeContainer(
        await baseOverrides(
          prefs: {'app_locale': 'en'},
          device: const Locale('fr'),
        ),
      );
      expect(c.read(localeControllerProvider), const Locale('en'));
    });

    test('then the device language if supported', () async {
      final c = makeContainer(
        await baseOverrides(device: const Locale('en', 'US')),
      );
      expect(c.read(localeControllerProvider), const Locale('en'));
    });

    test('otherwise French', () async {
      final c = makeContainer(await baseOverrides(device: const Locale('de')));
      expect(c.read(localeControllerProvider), const Locale('fr'));
    });
  });

  group('with a session', () {
    late MockAuthRepository repo;
    late ProviderContainer container;

    setUp(() async {
      repo = MockAuthRepository();
      when(() => repo.restoreSession()).thenAnswer((_) async => null);
      container = makeContainer([
        ...await baseOverrides(device: const Locale('fr')),
        authRepositoryProvider.overrideWithValue(repo),
      ]);
      when(
        () => repo.login(any(), any()),
      ).thenAnswer((_) async => fakeUser(language: 'en'));
    });

    test('the server language wins after login and is stored', () async {
      await container.read(authControllerProvider.future);
      await container.read(authControllerProvider.notifier).login('a@b.c', 'x');
      expect(container.read(localeControllerProvider), const Locale('en'));
      expect(
        container.read(sharedPreferencesProvider).getString('app_locale'),
        'en',
      );
    });

    test('a failed PATCH reverts the language', () async {
      await container.read(authControllerProvider.future);
      await container.read(authControllerProvider.notifier).login('a@b.c', 'x');
      when(
        () => repo.updateProfile(any()),
      ).thenThrow(const ApiException(code: 'network_error'));

      await expectLater(
        container.read(localeControllerProvider.notifier).setLanguage('fr'),
        throwsA(isA<ApiException>()),
      );
      expect(container.read(localeControllerProvider), const Locale('en'));
      expect(
        container.read(sharedPreferencesProvider).getString('app_locale'),
        'en',
      );
    });

    test('a successful change is applied and saved on the server', () async {
      await container.read(authControllerProvider.future);
      await container.read(authControllerProvider.notifier).login('a@b.c', 'x');
      when(
        () => repo.updateProfile({'preferred_language': 'fr'}),
      ).thenAnswer((_) async => fakeUser(language: 'fr'));

      await container.read(localeControllerProvider.notifier).setLanguage('fr');
      expect(container.read(localeControllerProvider), const Locale('fr'));
      verify(() => repo.updateProfile({'preferred_language': 'fr'})).called(1);
    });
  });

  test('logged out, a change stays local', () async {
    final repo = MockAuthRepository();
    when(() => repo.restoreSession()).thenAnswer((_) async => null);
    final c = makeContainer([
      ...await baseOverrides(),
      authRepositoryProvider.overrideWithValue(repo),
    ]);
    await c.read(authControllerProvider.future);
    await c.read(localeControllerProvider.notifier).setLanguage('en');
    expect(c.read(localeControllerProvider), const Locale('en'));
    verifyNever(() => repo.updateProfile(any()));
  });
}
