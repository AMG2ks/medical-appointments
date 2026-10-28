import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/api_client.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/auth/data/auth_api.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/notifications/local_reminders.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_local_reminders.dart';
import '../../support/fakes.dart';
import '../../support/test_app.dart';

class MockAuthApi extends Mock implements AuthApi {}

class ThrowingReminders extends FakeLocalReminders {
  @override
  Future<void> cancelAll() async => throw StateError('hook failed');
}

void main() {
  late MockAuthApi api;
  late FakeTokenStorage tokens;

  Future<ProviderContainer> container() async => makeContainer([
    ...await baseOverrides(),
    authApiProvider.overrideWithValue(api),
    tokenStorageProvider.overrideWithValue(tokens),
  ]);

  setUp(() {
    api = MockAuthApi();
    tokens = FakeTokenStorage();
  });

  test('no stored tokens: logged out, /me is not called', () async {
    final c = await container();
    expect(await c.read(authControllerProvider.future), isNull);
    verifyNever(() => api.me());
  });

  test('tokens and /me ok: the user is loaded', () async {
    tokens.refresh = 'r1';
    when(() => api.me()).thenAnswer((_) async => fakeUser());
    final c = await container();
    final user = await c.read(authControllerProvider.future);
    expect(user!.email, 'amira@example.com');
    expect(c.read(currentUserProvider), user);
  });

  test('tokens but /me answers 401: tokens cleared, logged out', () async {
    tokens
      ..access = 'a1'
      ..refresh = 'r1';
    when(
      () => api.me(),
    ).thenThrow(const ApiException(statusCode: 401, code: 'token_not_valid'));
    final c = await container();
    expect(await c.read(authControllerProvider.future), isNull);
    expect(tokens.refresh, isNull);
  });

  test('login stores both tokens and sets the user', () async {
    when(() => api.login('a@b.c', 'pw')).thenAnswer(
      (_) async => AuthSession(access: 'a1', refresh: 'r1', user: fakeUser()),
    );
    final c = await container();
    await c.read(authControllerProvider.future);
    await c.read(authControllerProvider.notifier).login('a@b.c', 'pw');
    expect(tokens.access, 'a1');
    expect(tokens.refresh, 'r1');
    expect(c.read(currentUserProvider), isNotNull);
  });

  test('a failed login leaves the state untouched', () async {
    when(() => api.login(any(), any())).thenThrow(
      const ApiException(statusCode: 401, code: 'authentication_failed'),
    );
    final c = await container();
    await c.read(authControllerProvider.future);
    await expectLater(
      c.read(authControllerProvider.notifier).login('a@b.c', 'bad'),
      throwsA(isA<ApiException>()),
    );
    expect(c.read(currentUserProvider), isNull);
    expect(tokens.access, isNull);
  });

  test('logout clears the storage even if the API call fails', () async {
    tokens
      ..access = 'a1'
      ..refresh = 'r1';
    when(() => api.me()).thenAnswer((_) async => fakeUser());
    when(
      () => api.logout(any()),
    ).thenThrow(const ApiException(code: 'network_error'));
    final c = await container();
    await c.read(authControllerProvider.future);

    await c.read(authControllerProvider.notifier).logout();
    await Future<void>.delayed(
      Duration.zero,
    ); // the server call is fire-and-forget

    expect(tokens.access, isNull);
    expect(tokens.refresh, isNull);
    expect(c.read(currentUserProvider), isNull);
    verify(() => api.logout('r1')).called(1);
  });

  test('logout cancels the on-device reminders', () async {
    tokens
      ..access = 'a1'
      ..refresh = 'r1';
    when(() => api.me()).thenAnswer((_) async => fakeUser());
    when(() => api.logout(any())).thenAnswer((_) async {});
    final reminders = FakeLocalReminders();
    final c = makeContainer([
      ...await baseOverrides(),
      authApiProvider.overrideWithValue(api),
      tokenStorageProvider.overrideWithValue(tokens),
      localRemindersProvider.overrideWithValue(reminders),
    ]);
    await c.read(authControllerProvider.future);

    await c.read(authControllerProvider.notifier).logout();

    expect(reminders.cancelAllCalls, 1);
    expect(c.read(currentUserProvider), isNull);
  });

  test(
    'an expired session and discarding the session cancel the reminders',
    () async {
      tokens
        ..access = 'a1'
        ..refresh = 'r1';
      when(() => api.me()).thenAnswer((_) async => fakeUser());
      final reminders = FakeLocalReminders();
      final c = makeContainer([
        ...await baseOverrides(),
        authApiProvider.overrideWithValue(api),
        tokenStorageProvider.overrideWithValue(tokens),
        localRemindersProvider.overrideWithValue(reminders),
      ]);
      await c.read(authControllerProvider.future);

      c.read(authControllerProvider.notifier).sessionExpired();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(currentUserProvider), isNull);
      expect(reminders.cancelAllCalls, 1);

      await c.read(authControllerProvider.notifier).discardSession();
      await Future<void>.delayed(Duration.zero);
      expect(reminders.cancelAllCalls, 2);
    },
  );

  test(
    'logout completes even if a hook throws, and a double tap is ignored',
    () async {
      tokens
        ..access = 'a1'
        ..refresh = 'r1';
      when(() => api.me()).thenAnswer((_) async => fakeUser());
      when(() => api.logout(any())).thenAnswer((_) async {});
      final c = makeContainer([
        ...await baseOverrides(),
        authApiProvider.overrideWithValue(api),
        tokenStorageProvider.overrideWithValue(tokens),
        localRemindersProvider.overrideWithValue(ThrowingReminders()),
      ]);
      await c.read(authControllerProvider.future);

      final controller = c.read(authControllerProvider.notifier);
      await Future.wait([controller.logout(), controller.logout()]);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(currentUserProvider), isNull);
      expect(tokens.refresh, isNull);
      verify(() => api.logout('r1')).called(1);
    },
  );

  test(
    'a network error while restoring keeps the tokens and shows an error',
    () async {
      tokens.refresh = 'r1';
      when(() => api.me()).thenThrow(const ApiException(code: 'network_error'));
      final c = await container();
      c.listen(authControllerProvider, (_, _) {});
      await expectLater(
        c.read(authControllerProvider.future),
        throwsA(isA<ApiException>()),
      );
      expect(c.read(authControllerProvider).hasError, isTrue);
      expect(tokens.refresh, 'r1');
    },
  );

  test(
    'a server error or unreadable answer while restoring logs out',
    () async {
      tokens.refresh = 'r1';
      when(
        () => api.me(),
      ).thenThrow(const ApiException(statusCode: 500, code: 'server_error'));
      var c = await container();
      expect(await c.read(authControllerProvider.future), isNull);
      expect(tokens.refresh, isNull);

      tokens.refresh = 'r2';
      when(() => api.me()).thenThrow(StateError('unknown role'));
      c = await container();
      expect(await c.read(authControllerProvider.future), isNull);
      expect(tokens.refresh, isNull);
    },
  );

  test('discardSession (splash "back to login") clears everything', () async {
    tokens.refresh = 'r1';
    when(() => api.me()).thenThrow(const ApiException(code: 'network_error'));
    final c = await container();
    c.listen(authControllerProvider, (_, _) {});
    await c.read(authControllerProvider.future).then((_) {}, onError: (_) {});
    await c.read(authControllerProvider.notifier).discardSession();
    expect(tokens.refresh, isNull);
    expect(c.read(authControllerProvider).value, isNull);
    expect(c.read(authControllerProvider).hasError, isFalse);
  });

  test('sessionExpired logs out locally', () async {
    tokens.refresh = 'r1';
    when(() => api.me()).thenAnswer((_) async => fakeUser());
    final c = await container();
    await c.read(authControllerProvider.future);
    c.read(authControllerProvider.notifier).sessionExpired();
    expect(c.read(currentUserProvider), isNull);
  });
}
