import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_controller.dart';
import '../data/dashboard_repository.dart';
import '../data/models/dashboard_stats.dart';

/// Not kept alive: opening the dashboard (or pulling to refresh) shows fresh figures.
final dashboardStatsProvider = FutureProvider.autoDispose<DashboardStats>((
  ref,
) {
  ref.watch(currentUserIdProvider); // reset on logout / account switch
  return ref.read(dashboardRepositoryProvider).stats();
});
