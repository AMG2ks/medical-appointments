import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../core/config/env.dart';
import '../appointments/data/models/appointment.dart';

/// Texts of a reminder, already in the user's language (built where a locale is known).
class ReminderTexts {
  const ReminderTexts({
    required this.title,
    required this.channelName,
    required this.body,
  });

  final String title;
  final String channelName;
  final String Function(Appointment appointment) body;
}

/// One reminder to schedule: notification id = appointment id, fired at an absolute instant.
class PlannedReminder {
  const PlannedReminder(this.appointment, this.fireAt);

  final Appointment appointment;

  /// UTC instant (`start - minutesBefore`).
  final DateTime fireAt;

  int get id => appointment.id;
}

/// Which reminders to schedule: confirmed appointments whose reminder time is still ahead.
/// An appointment that starts sooner than [minutesBefore] gets none (a notification in the
/// past would fire at once, again on every resync). Pure, so it is easy to unit test.
List<PlannedReminder> planReminders(
  List<Appointment> upcoming, {
  required DateTime now,
  required int minutesBefore,
}) {
  final reminders = [
    for (final a in upcoming)
      if (a.isConfirmed &&
          a.startAt.subtract(Duration(minutes: minutesBefore)).isAfter(now))
        PlannedReminder(
          a,
          a.startAt.subtract(Duration(minutes: minutesBefore)).toUtc(),
        ),
  ]..sort((a, b) => a.fireAt.compareTo(b.fireAt));
  return reminders;
}

/// On-device reminders (no remote push). The whole schedule is rebuilt from the server's
/// list of upcoming appointments every time it is fetched ([resync]): cancel all, schedule
/// again. Cancellations, reboots and language changes then need no extra logic.
/// A provider ([localRemindersProvider]), so tests can fake it.
class LocalReminders {
  LocalReminders({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// Bumped by every [cancelAll]. A [resync] started before it (a fetch that was in flight
  /// when the session ended) is dropped, so it cannot schedule the old user's reminders
  /// after the cancel.
  int _epoch = 0;

  /// Calls run one after the other: a slow resync must not interleave with a newer one
  /// (or with the logout `cancelAll`) and leave stale reminders behind.
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _ensureReady() async {
    if (_ready) return;
    tz_data.initializeTimeZones();
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_reminder'),
      ),
    );
    _ready = true;
  }

  /// Asks for the Android 13+ `POST_NOTIFICATIONS` permission (the system dialog shows only
  /// when it can). Call it in context: the first time the user books. Returns whether
  /// notifications are allowed; denial just means no on-device reminders.
  Future<bool> requestPermission() async {
    try {
      await _ensureReady();
      final android =
          _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();
      return await android?.requestNotificationsPermission() ?? true;
    } catch (_) {
      return false;
    }
  }

  /// Cancels every scheduled reminder. Logout calls it so the next person using the phone
  /// does not get this user's reminders.
  Future<void> cancelAll() {
    _epoch++;
    return _serial(() async {
      await _ensureReady();
      await _plugin.cancelAll();
    });
  }

  /// Replaces the whole schedule with the reminders of [upcoming]. Returns how many were
  /// scheduled. `inexactAllowWhileIdle`: no exact-alarm permission needed (a reminder may
  /// be a few minutes late).
  Future<int> resync(
    List<Appointment> upcoming, {
    required ReminderTexts texts,
    DateTime? now,
    int minutesBefore = Env.reminderMinutesBefore,
  }) {
    final epoch = _epoch;
    return _serial(() async {
      if (epoch != _epoch) {
        return 0; // a cancelAll (logout) came after this call
      }
      await _ensureReady();
      await _plugin.cancelAll();
      final planned = planReminders(
        upcoming,
        now: now ?? DateTime.now().toUtc(),
        minutesBefore: minutesBefore,
      );
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          'appointment_reminders',
          texts.channelName,
          importance: Importance.high,
          priority: Priority.high,
          // Doctor name and time stay off a locked screen (the plugin has no "public version":
          // with `private` Android shows its generic notification there).
          visibility: NotificationVisibility.private,
        ),
      );
      for (final reminder in planned) {
        await _plugin.zonedSchedule(
          reminder.id,
          texts.title,
          texts.body(reminder.appointment),
          tz.TZDateTime.from(reminder.fireAt, tz.UTC),
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
      return planned.length;
    });
  }
}

final localRemindersProvider = Provider<LocalReminders>(
  (ref) => LocalReminders(),
);
