import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/app/router.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';

import '../support/fakes.dart';

void main() {
  const loading = AsyncLoading<User?>();
  const loggedOut = AsyncData<User?>(null);
  AsyncValue<User?> loggedIn(UserRole role) => AsyncData(fakeUser(role: role));

  group('loading', () {
    test('goes to /splash from anywhere', () {
      expect(authRedirect(loading, '/login'), '/splash');
      expect(authRedirect(loading, '/patient'), '/splash');
    });
    test(
      'stays on /splash',
      () => expect(authRedirect(loading, '/splash'), isNull),
    );
    test('a failed session check also waits on the splash', () {
      final error = AsyncError<User?>(StateError('offline'), StackTrace.empty);
      expect(authRedirect(error, '/login'), '/splash');
      expect(authRedirect(error, '/splash'), isNull);
    });
  });

  group('logged out', () {
    test('stays on public routes', () {
      for (final path in [
        '/login',
        '/register',
        '/forgot-password',
        '/reset-password',
      ]) {
        expect(authRedirect(loggedOut, path), isNull, reason: path);
      }
    });
    test('everything else goes to /login', () {
      for (final path in [
        '/splash',
        '/patient',
        '/doctor/profile',
        '/admin',
        '/change-password',
      ]) {
        expect(authRedirect(loggedOut, path), '/login', reason: path);
      }
    });
  });

  group('logged in', () {
    test('public routes and splash go to the role home', () {
      expect(authRedirect(loggedIn(UserRole.patient), '/login'), '/patient');
      expect(authRedirect(loggedIn(UserRole.doctor), '/splash'), '/doctor');
      expect(authRedirect(loggedIn(UserRole.admin), '/register'), '/admin');
    });
    test("another role's area goes to the role home", () {
      expect(authRedirect(loggedIn(UserRole.patient), '/admin'), '/patient');
      expect(
        authRedirect(loggedIn(UserRole.patient), '/doctor/profile'),
        '/patient',
      );
      expect(
        authRedirect(loggedIn(UserRole.doctor), '/patient/profile'),
        '/doctor',
      );
      expect(authRedirect(loggedIn(UserRole.admin), '/doctor'), '/admin');
    });
    test('own area and shared pages stay', () {
      expect(authRedirect(loggedIn(UserRole.patient), '/patient'), isNull);
      expect(
        authRedirect(loggedIn(UserRole.doctor), '/doctor/profile'),
        isNull,
      );
      expect(authRedirect(loggedIn(UserRole.admin), '/admin'), isNull);
      expect(
        authRedirect(loggedIn(UserRole.patient), '/change-password'),
        isNull,
      );
    });
  });
}
