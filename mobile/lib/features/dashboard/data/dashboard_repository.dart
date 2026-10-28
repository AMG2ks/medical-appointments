import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import 'models/dashboard_stats.dart';

/// `/api/v1/dashboard/stats/` (admin only). Errors come out as [ApiException].
class DashboardRepository {
  DashboardRepository(this._dio);

  final Dio _dio;

  Future<DashboardStats> stats() => guardApi(() async {
    final response = await _dio.get<Map<String, dynamic>>('dashboard/stats/');
    return DashboardStats.fromJson(response.data!);
  });
}

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => DashboardRepository(ref.watch(dioProvider)),
);
