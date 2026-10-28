import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/core/network/paginated.dart';
import 'package:medical_appointments/features/notifications/data/models/app_notification.dart';
import 'package:medical_appointments/features/notifications/data/notifications_repository.dart';

AppNotification fakeNotification({
  int id = 1,
  NotificationKind kind = NotificationKind.appointmentConfirmed,
  bool read = false,
  String doctorName = 'Sarah Miller',
  String patientName = 'Amira Ben Salah',
  String? cancelledBy,
  String? reason,
  int appointmentId = 7,
}) => AppNotification(
  id: id,
  kind: kind,
  data: {
    'appointment_id': appointmentId,
    'start_at': '2026-11-05T10:00:00+01:00',
    'doctor_name': doctorName,
    'patient_name': patientName,
    if (cancelledBy != null) 'cancelled_by': cancelledBy,
    if (reason != null) 'reason': reason,
  },
  createdAt: DateTime.utc(2026, 11, 2, 8),
  readAt: read ? DateTime.utc(2026, 11, 2, 9) : null,
);

/// In-memory stand-in for [NotificationsRepository].
class FakeNotificationsRepository implements NotificationsRepository {
  FakeNotificationsRepository({
    List<AppNotification>? items,
    this.pageSize = 20,
  }) : items = items ?? [];

  final List<AppNotification> items;
  final int pageSize;

  /// Set to make the matching call fail (it keeps failing until cleared).
  ApiException? listError;
  ApiException? countError;

  final calls = <String>[];

  @override
  Future<Paginated<AppNotification>> list({
    int page = 1,
    bool unreadOnly = false,
    int pageSize = 20,
  }) async {
    calls.add('list page=$page');
    if (listError != null) throw listError!;
    final matching = [
      for (final n in items)
        if (!unreadOnly || !n.isRead) n,
    ];
    final from = (page - 1) * this.pageSize;
    return Paginated(
      count: matching.length,
      hasNext: from + this.pageSize < matching.length,
      results: matching.skip(from).take(this.pageSize).toList(),
    );
  }

  @override
  Future<int> unreadCount() async {
    calls.add('unreadCount');
    if (countError != null) throw countError!;
    return items.where((n) => !n.isRead).length;
  }

  @override
  Future<AppNotification> markRead(int id) async {
    calls.add('markRead $id');
    final index = items.indexWhere((n) => n.id == id);
    if (index < 0) {
      throw const ApiException(statusCode: 404, code: 'not_found');
    }
    return items[index] = items[index].copyWith(readAt: DateTime.now());
  }

  @override
  Future<void> markAllRead() async {
    calls.add('markAllRead');
    for (var i = 0; i < items.length; i++) {
      items[i] = items[i].copyWith(readAt: DateTime.now());
    }
  }
}
