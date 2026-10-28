import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/paginated.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/users_admin/data/users_admin_api.dart';
import 'package:medical_appointments/features/users_admin/presentation/users_admin_screen.dart';

import '../../support/fakes.dart';
import '../../support/test_app.dart';

class FakeUsersApi implements UsersAdminApi {
  FakeUsersApi(this.users);

  final List<User> users;

  @override
  Future<Paginated<User>> list({
    int page = 1,
    UserRole? role,
    String search = '',
  }) async => Paginated(count: users.length, hasNext: false, results: users);

  @override
  Future<User> setActive(int id, {required bool isActive}) async =>
      users.firstWhere((u) => u.id == id);
}

void main() {
  Future<void> openDialogFor(
    WidgetTester tester,
    UserRole role,
    String language,
  ) async {
    final target = fakeUser(role: role); // id 1
    await tester.pumpWidget(
      testApp(
        const UsersAdminScreen(),
        locale: Locale(language),
        overrides: [
          ...await baseOverrides(),
          usersAdminApiProvider.overrideWithValue(FakeUsersApi([target])),
          currentUserIdProvider.overrideWithValue(99),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
  }

  for (final role in [UserRole.patient, UserRole.doctor]) {
    testWidgets('deactivating a ${role.name} warns about their appointments', (
      tester,
    ) async {
      await openDialogFor(tester, role, 'en');
      expect(find.text('Deactivate this account?'), findsOneWidget);
      expect(
        find.textContaining(
          'Their future appointments will be cancelled and the other person will be notified.',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('French warning', (tester) async {
    await openDialogFor(tester, UserRole.patient, 'fr');
    expect(
      find.textContaining('Ses rendez-vous à venir seront annulés'),
      findsOneWidget,
    );
  });

  testWidgets('no appointment warning for an admin account', (tester) async {
    await openDialogFor(tester, UserRole.admin, 'en');
    expect(find.text('Deactivate this account?'), findsOneWidget);
    expect(find.textContaining('future appointments'), findsNothing);
  });
}
