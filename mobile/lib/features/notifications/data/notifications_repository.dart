import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/paginated.dart';
import 'models/app_notification.dart';

/// All `/api/v1/notifications/` calls. Errors come out as [ApiException]. Tests swap in a
/// fake (`implements NotificationsRepository`).
class NotificationsRepository {
  NotificationsRepository(this._dio);

  final Dio _dio;

  /// My notifications, newest first.
  Future<Paginated<AppNotification>> list({
    int page = 1,
    bool unreadOnly = false,
    int pageSize = 20,
  }) => guardApi(() async {
    final response = await _dio.get<Map<String, dynamic>>(
      'notifications/',
      queryParameters: {
        'page': page,
        'page_size': pageSize,
        if (unreadOnly) 'unread': 'true',
      },
    );
    return Paginated.fromJson(response.data!, AppNotification.fromJson);
  });

  Future<int> unreadCount() => guardApi(() async {
    final response = await _dio.get<Map<String, dynamic>>(
      'notifications/unread-count/',
    );
    return response.data!['count'] as int;
  });

  Future<AppNotification> markRead(int id) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      'notifications/$id/read/',
    );
    return AppNotification.fromJson(response.data!);
  });

  Future<void> markAllRead() => guardApi(() async {
    await _dio.post<Map<String, dynamic>>('notifications/read-all/');
  });
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => NotificationsRepository(ref.watch(dioProvider)),
);
