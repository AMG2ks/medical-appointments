import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/features/notifications/data/models/app_notification.dart';
import 'package:medical_appointments/features/notifications/data/notifications_repository.dart';

import '../../support/fakes.dart';

Map<String, dynamic> notificationJson({
  int id = 5,
  String kind = 'appointment_cancelled',
  bool read = false,
}) => {
  'id': id,
  'kind': kind,
  'data': {
    'appointment_id': 7,
    'start_at': '2026-11-05T10:00:00+01:00',
    'doctor_name': 'Sarah Miller',
    'patient_name': 'Amira Ben Salah',
    'cancelled_by': 'admin',
  },
  'read_at': read ? '2026-11-02T09:00:00Z' : null,
  'created_at': '2026-11-02T08:00:00Z',
};

void main() {
  late StubAdapter adapter;
  late NotificationsRepository repo;

  void answer(Object? Function(RequestOptions) body, [int status = 200]) {
    adapter = StubAdapter(
      (options) async => jsonResponse(body(options), status),
    );
    repo = NotificationsRepository(
      Dio(BaseOptions(baseUrl: 'http://test/api/v1/'))
        ..httpClientAdapter = adapter,
    );
  }

  test('list: paged, unread filter, parsed', () async {
    answer(
      (_) => {
        'count': 1,
        'next': 'http://test/api/v1/notifications/?page=2',
        'previous': null,
        'results': [notificationJson()],
      },
    );
    final page = await repo.list(page: 1, unreadOnly: true);
    final request = adapter.requests.single;
    expect(request.path, 'notifications/');
    expect(request.queryParameters, {
      'page': 1,
      'page_size': 20,
      'unread': 'true',
    });
    expect(page.hasNext, isTrue);
    final n = page.results.single;
    expect(n.kind, NotificationKind.appointmentCancelled);
    expect(n.isRead, isFalse);
    expect(n.appointmentId, 7);
    expect(n.cancelledBy, 'admin');
    expect(n.start, DateTime(2026, 11, 5, 10)); // clinic wall clock
  });

  test('an unknown kind does not break parsing', () async {
    answer(
      (_) => {
        'count': 1,
        'next': null,
        'previous': null,
        'results': [notificationJson(kind: 'something_new')],
      },
    );
    final page = await repo.list();
    expect(page.results.single.kind, NotificationKind.unknown);
    expect(
      adapter.requests.single.queryParameters.containsKey('unread'),
      false,
    );
  });

  test('unreadCount', () async {
    answer((_) => {'count': 4});
    expect(await repo.unreadCount(), 4);
    expect(adapter.requests.single.path, 'notifications/unread-count/');
  });

  test('markRead posts to the item and returns it read', () async {
    answer((_) => notificationJson(id: 9, read: true));
    final n = await repo.markRead(9);
    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.path, 'notifications/9/read/');
    expect(n.isRead, isTrue);
  });

  test('markAllRead posts to read-all', () async {
    answer((_) => {'updated': 3});
    await repo.markAllRead();
    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.path, 'notifications/read-all/');
  });
}
