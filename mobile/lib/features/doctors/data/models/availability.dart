import 'package:flutter/material.dart' show TimeOfDay;

/// One weekly window, in the clinic's wall-clock time. `weekday` 0 = Monday ... 6 = Sunday.
class Availability {
  const Availability({
    required this.id,
    required this.weekday,
    required this.start,
    required this.end,
  });

  final int id;
  final int weekday;
  final TimeOfDay start;
  final TimeOfDay end;

  factory Availability.fromJson(Map<String, dynamic> json) => Availability(
    id: json['id'] as int,
    weekday: json['weekday'] as int,
    start: parseApiTime(json['start_time'] as String),
    end: parseApiTime(json['end_time'] as String),
  );
}

/// `09:00:00` or `09:00` -> TimeOfDay.
TimeOfDay parseApiTime(String value) {
  final parts = value.split(':');
  return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
}

/// TimeOfDay -> `HH:mm`, the format sent to the API.
String apiTime(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
