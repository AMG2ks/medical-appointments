import '../../../../core/network/api_exception.dart';

/// The API returns instants in the clinic's time zone (`2026-11-03T00:00:00+01:00`). Keep the
/// wall-clock part and drop the offset, so a phone in another zone still shows the clinic's
/// days. The result is a plain (zone-less) DateTime: never convert it with `toUtc()`.
DateTime parseClinicTime(String iso) => DateTime.parse(iso.substring(0, 19));

/// Wall-clock `YYYY-MM-DDTHH:mm:ss` without offset: the server reads it in `TIME_ZONE`.
String apiDateTime(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-${two(value.day)}'
      'T${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

/// A period during which the doctor takes no appointments.
class TimeOff {
  const TimeOff({
    required this.id,
    required this.startAt,
    required this.endAt,
    required this.reason,
  });

  final int id;
  final DateTime startAt;
  final DateTime endAt;
  final String reason;

  factory TimeOff.fromJson(Map<String, dynamic> json) => TimeOff(
    id: json['id'] as int,
    startAt: parseClinicTime(json['start_at'] as String),
    endAt: parseClinicTime(json['end_at'] as String),
    reason: (json['reason'] as String?) ?? '',
  );
}

/// An appointment that blocks a time off (409 `time_off_conflict`, `error.details`).
class ConflictingAppointment {
  const ConflictingAppointment({
    required this.id,
    required this.startAt,
    required this.patientName,
  });

  final int id;

  /// Clinic wall-clock start.
  final DateTime startAt;
  final String patientName;

  factory ConflictingAppointment.fromJson(Map<String, dynamic> json) =>
      ConflictingAppointment(
        id: json['id'] as int,
        startAt: parseClinicTime(json['start_at'] as String),
        patientName: (json['patient_name'] as String?) ?? '',
      );
}

/// The appointments that block a time off: the first ones in [items], the exact total in
/// [count] (the server lists at most a few dozen).
class TimeOffConflict {
  const TimeOffConflict({required this.count, required this.items});

  final int count;
  final List<ConflictingAppointment> items;

  /// Null unless [error] is a `time_off_conflict` carrying details.
  static TimeOffConflict? from(Object? error) {
    if (error is! ApiException || error.code != 'time_off_conflict') {
      return null;
    }
    final list = error.details['appointments'];
    if (list is! List) return null;
    final items = [
      for (final item in list)
        ConflictingAppointment.fromJson(item as Map<String, dynamic>),
    ];
    return TimeOffConflict(
      count: (error.details['count'] as int?) ?? items.length,
      items: items,
    );
  }
}
