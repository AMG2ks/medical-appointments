import '../../../doctors/data/models/time_off.dart' show parseClinicTime;

/// What a notification is about. The server stores no text: the app builds it from this
/// kind and [AppNotification.data] with its own translations.
enum NotificationKind {
  appointmentConfirmed('appointment_confirmed'),
  appointmentBooked('appointment_booked'),
  appointmentCancelled('appointment_cancelled'),
  appointmentReminder('appointment_reminder'),

  /// A kind this app version does not know: shown with a generic text.
  unknown('unknown');

  const NotificationKind(this.apiValue);

  final String apiValue;

  static NotificationKind fromJson(String value) => values.firstWhere(
    (k) => k.apiValue == value,
    orElse: () => NotificationKind.unknown,
  );
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.data,
    required this.createdAt,
    this.readAt,
  });

  final int id;
  final NotificationKind kind;

  /// Kind-specific payload (`appointment_id`, `start_at`, `doctor_name`, `patient_name`,
  /// `cancelled_by`, `reason`).
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get isRead => readAt != null;

  int? get appointmentId => data['appointment_id'] as int?;

  String get doctorName => (data['doctor_name'] as String?) ?? '';
  String get patientName => (data['patient_name'] as String?) ?? '';

  /// `patient`, `doctor` or `admin` for a cancellation.
  String? get cancelledBy => data['cancelled_by'] as String?;
  String get reason => (data['reason'] as String?) ?? '';

  /// Start of the appointment as clinic wall-clock time (see `Appointment.start`).
  DateTime? get start {
    final iso = data['start_at'] as String?;
    return iso == null ? null : parseClinicTime(iso);
  }

  AppNotification copyWith({DateTime? readAt}) => AppNotification(
    id: id,
    kind: kind,
    data: data,
    createdAt: createdAt,
    readAt: readAt ?? this.readAt,
  );

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] as int,
        kind: NotificationKind.fromJson(json['kind'] as String),
        data: (json['data'] as Map<String, dynamic>?) ?? const {},
        createdAt: DateTime.parse(json['created_at'] as String),
        readAt:
            json['read_at'] == null
                ? null
                : DateTime.parse(json['read_at'] as String),
      );
}
