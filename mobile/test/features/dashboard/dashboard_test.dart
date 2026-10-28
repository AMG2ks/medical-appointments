import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/appointments/data/models/appointment.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/dashboard/data/dashboard_repository.dart';
import 'package:medical_appointments/features/dashboard/data/models/dashboard_stats.dart';
import 'package:medical_appointments/features/dashboard/presentation/screens/dashboard_screen.dart';

import '../../support/fakes.dart';
import '../../support/test_app.dart';

const statsJson = {
  'patients': {'total': 12, 'active': 10},
  'doctors': {'total': 3, 'active': 3},
  'appointments': {
    'total': 40,
    'today': 4,
    'this_week': 9,
    'by_status': {
      'confirmed': 20,
      'cancelled': 8,
      'completed': 10,
      'no_show': 2,
    },
  },
};

class FakeDashboardRepository implements DashboardRepository {
  FakeDashboardRepository({this.error});

  ApiException? error;
  int calls = 0;

  @override
  Future<DashboardStats> stats() async {
    calls++;
    if (error != null) throw error!;
    return DashboardStats.fromJson(statsJson);
  }
}

void main() {
  test('repository parses the stats payload', () async {
    final adapter = StubAdapter((_) async => jsonResponse(statsJson));
    final repo = DashboardRepository(
      Dio(BaseOptions(baseUrl: 'http://test/api/v1/'))
        ..httpClientAdapter = adapter,
    );
    final stats = await repo.stats();
    expect(adapter.requests.single.path, 'dashboard/stats/');
    expect(stats.patients.active, 10);
    expect(stats.doctors.total, 3);
    expect(stats.appointmentsToday, 4);
    expect(stats.appointmentsThisWeek, 9);
    expect(stats.byStatus[AppointmentStatus.noShow], 2);
  });

  Future<void> pump(
    WidgetTester tester,
    FakeDashboardRepository repo, {
    String language = 'en',
  }) async {
    await tester.pumpWidget(
      testApp(
        const DashboardScreen(),
        locale: Locale(language),
        overrides: [
          ...await baseOverrides(),
          dashboardRepositoryProvider.overrideWithValue(repo),
          currentUserIdProvider.overrideWithValue(1),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the counts (English)', (tester) async {
    await pump(tester, FakeDashboardRepository());
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('10 active of 12'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
  });

  testWidgets('French labels', (tester) async {
    await pump(tester, FakeDashboardRepository(), language: 'fr');
    expect(find.text('Tableau de bord'), findsOneWidget);
    expect(find.text('10 actifs sur 12'), findsOneWidget);
    expect(find.text("Aujourd'hui"), findsOneWidget);
  });

  testWidgets('error with retry', (tester) async {
    final repo = FakeDashboardRepository(
      error: const ApiException(code: 'network_error'),
    );
    await pump(tester, repo);
    expect(find.text('Retry'), findsOneWidget);
    repo.error = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(repo.calls, 2);
  });
}
