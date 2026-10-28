import 'package:medical_appointments/features/appointments/data/models/appointment.dart';
import 'package:medical_appointments/features/notifications/local_reminders.dart';

/// Records what the app asks of the on-device reminders; schedules nothing.
class FakeLocalReminders implements LocalReminders {
  int cancelAllCalls = 0;
  int permissionRequests = 0;

  /// One entry per [resync]: the ids of the appointments it was given.
  final resyncs = <List<int>>[];

  /// Texts of the last resync, to check the language.
  ReminderTexts? lastTexts;

  bool permissionGranted = true;

  @override
  Future<void> cancelAll() async => cancelAllCalls++;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<int> resync(
    List<Appointment> upcoming, {
    required ReminderTexts texts,
    DateTime? now,
    int minutesBefore = 1440,
  }) async {
    resyncs.add([for (final a in upcoming) a.id]);
    lastTexts = texts;
    return upcoming.length;
  }
}
