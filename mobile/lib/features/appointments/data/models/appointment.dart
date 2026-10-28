import '../../../doctors/data/models/specialty.dart';
import '../../../doctors/data/models/time_off.dart' show parseClinicTime;

/// `confirmed -> cancelled | completed | no_show` (no other transition).
enum AppointmentStatus {
  confirmed('confirmed'),
  cancelled('cancelled'),
  completed('completed'),
  noShow('no_show'),

  /// A status this app version does not know: shown, but no action is offered.
  unknown('unknown');

  const AppointmentStatus(this.apiValue);

  final String apiValue;

  static AppointmentStatus fromJson(String value) => AppointmentStatus.values
      .firstWhere((s) => s.apiValue == value, orElse: () => unknown);
}

/// `?scope=` of the list endpoint: upcoming = confirmed and not started yet (earliest
/// first); past = everything else (latest first).
enum AppointmentScope { upcoming, past }

/// The patient or the doctor of an appointment (`id` is the user id).
class AppointmentPerson {
  const AppointmentPerson({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.specialty,
    this.phone,
  });

  final int id;
  final String firstName;
  final String lastName;

  /// Doctors only.
  final Specialty? specialty;

  /// Patients only (seen by the doctor and the admin).
  final String? phone;

  String get fullName => '$firstName $lastName'.trim();

  factory AppointmentPerson.fromJson(Map<String, dynamic> json) =>
      AppointmentPerson(
        id: json['id'] as int,
        firstName: json['first_name'] as String,
        lastName: json['last_name'] as String,
        specialty:
            json['specialty'] == null
                ? null
                : Specialty.fromJson(json['specialty'] as Map<String, dynamic>),
        phone: json['phone'] as String?,
      );
}

class Appointment {
  const Appointment({
    required this.id,
    required this.patient,
    required this.doctor,
    required this.startAt,
    required this.endAt,
    required this.start,
    required this.end,
    required this.status,
    this.reason = '',
    this.cancelledByRole,
    this.cancellationReason = '',
  });

  final int id;
  final AppointmentPerson patient;
  final AppointmentPerson doctor;

  /// Absolute instants (UTC). Use these to compare with "now" and to schedule reminders.
  final DateTime startAt;
  final DateTime endAt;

  /// The same moments as wall-clock time of the clinic (zone-less). Use these to display,
  /// so a phone in another time zone still shows the clinic's hours.
  final DateTime start;
  final DateTime end;

  final AppointmentStatus status;
  final String reason;

  /// `patient`, `doctor` or `admin` when cancelled.
  final String? cancelledByRole;
  final String cancellationReason;

  bool get isConfirmed => status == AppointmentStatus.confirmed;

  bool hasStarted(DateTime now) => !startAt.isAfter(now);

  factory Appointment.fromJson(Map<String, dynamic> json) {
    final startIso = json['start_at'] as String;
    final endIso = json['end_at'] as String;
    final cancelledBy = json['cancelled_by'] as Map<String, dynamic>?;
    return Appointment(
      id: json['id'] as int,
      patient: AppointmentPerson.fromJson(
        json['patient'] as Map<String, dynamic>,
      ),
      doctor: AppointmentPerson.fromJson(
        json['doctor'] as Map<String, dynamic>,
      ),
      startAt: DateTime.parse(startIso).toUtc(),
      endAt: DateTime.parse(endIso).toUtc(),
      start: parseClinicTime(startIso),
      end: parseClinicTime(endIso),
      status: AppointmentStatus.fromJson(json['status'] as String),
      reason: (json['reason'] as String?) ?? '',
      cancelledByRole: cancelledBy?['role'] as String?,
      cancellationReason: (json['cancellation_reason'] as String?) ?? '',
    );
  }
}

/// A free slot of a doctor. [startIso] is sent back unchanged to book it.
class Slot {
  const Slot({required this.startIso, required this.start, required this.end});

  final String startIso;

  /// Clinic wall-clock time (see [Appointment.start]).
  final DateTime start;
  final DateTime end;

  factory Slot.fromJson(Map<String, dynamic> json) => Slot(
    startIso: json['start_at'] as String,
    start: parseClinicTime(json['start_at'] as String),
    end: parseClinicTime(json['end_at'] as String),
  );
}
