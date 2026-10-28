import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/features/notifications/local_reminders.dart';
import 'package:mocktail/mocktail.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:medical_appointments/features/appointments/data/models/appointment.dart';

import '../../support/fake_appointments_repository.dart';

class MockPlugin extends Mock implements FlutterLocalNotificationsPlugin {}

void main() {
  final now = DateTime.utc(2026, 11, 2, 6);
  const day = Duration(days: 1);

  group('planReminders', () {
    test('keeps confirmed appointments whose reminder time is ahead', () {
      final later = fakeAppointment(id: 2, startAt: now.add(day * 5));
      final sooner = fakeAppointment(id: 1, startAt: now.add(day * 3));
      final planned = planReminders(
        [later, sooner],
        now: now,
        minutesBefore: 1440,
      );
      expect(planned.map((r) => r.id), [1, 2]); // by fire time
      expect(planned.first.fireAt, now.add(day * 2));
    });

    test(
      'skips what starts sooner than the lead time, or is not confirmed',
      () {
        final tooSoon = fakeAppointment(
          id: 1,
          startAt: now.add(const Duration(hours: 5)),
        );
        final cancelled = fakeAppointment(
          id: 2,
          startAt: now.add(day * 4),
          status: AppointmentStatus.cancelled,
        );
        expect(
          planReminders([tooSoon, cancelled], now: now, minutesBefore: 1440),
          isEmpty,
        );
      },
    );

    test('the lead time is a parameter', () {
      final soon = fakeAppointment(
        id: 1,
        startAt: now.add(const Duration(hours: 5)),
      );
      final planned = planReminders([soon], now: now, minutesBefore: 60);
      expect(planned.single.fireAt, now.add(const Duration(hours: 4)));
    });
  });

  group('LocalReminders', () {
    late MockPlugin plugin;
    late LocalReminders reminders;
    late List<String> events;
    final texts = ReminderTexts(
      title: 'Reminder',
      channelName: 'Reminders',
      body: (a) => 'with ${a.doctor.fullName}',
    );

    setUpAll(() {
      registerFallbackValue(const InitializationSettings());
      registerFallbackValue(const NotificationDetails());
      registerFallbackValue(tz.TZDateTime.utc(2026));
      registerFallbackValue(AndroidScheduleMode.inexactAllowWhileIdle);
      registerFallbackValue(UILocalNotificationDateInterpretation.absoluteTime);
    });

    setUp(() {
      plugin = MockPlugin();
      events = [];
      reminders = LocalReminders(plugin: plugin);
      when(() => plugin.initialize(any())).thenAnswer((_) async => true);
      when(() => plugin.cancelAll()).thenAnswer((_) async {
        events.add('cancelAll');
      });
      when(
        () => plugin.zonedSchedule(
          any(),
          any(),
          any(),
          any(),
          any(),
          androidScheduleMode: any(named: 'androidScheduleMode'),
          uiLocalNotificationDateInterpretation: any(
            named: 'uiLocalNotificationDateInterpretation',
          ),
        ),
      ).thenAnswer((_) async {
        events.add('schedule');
      });
    });

    test('resync cancels everything, then schedules each reminder', () async {
      final a = fakeAppointment(id: 41, startAt: now.add(day * 3));
      final b = fakeAppointment(id: 42, startAt: now.add(day * 4));
      final count = await reminders.resync([b, a], texts: texts, now: now);
      expect(count, 2);

      final calls =
          verify(
            () => plugin.zonedSchedule(
              captureAny(),
              'Reminder',
              'with Sarah Miller',
              captureAny(),
              any(),
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
            ),
          ).captured;
      expect(calls[0], 41); // notification id = appointment id
      final fireAt = calls[1] as tz.TZDateTime;
      expect(fireAt.isAtSameMomentAs(now.add(day * 2)), isTrue);
      expect(fireAt.location, tz.UTC);
      expect(calls[2], 42);
      expect(events, ['cancelAll', 'schedule', 'schedule']);
    });

    test('a resync started before a cancelAll (logout) is dropped', () async {
      final a = fakeAppointment(id: 41, startAt: now.add(day * 3));
      final stale = reminders.resync([a], texts: texts, now: now);
      final cancel = reminders.cancelAll(); // the session ended meanwhile
      expect(await stale, 0);
      await cancel;
      expect(events, ['cancelAll']); // nothing scheduled after the cancel
    });

    test('reminders are private on the lock screen', () async {
      final a = fakeAppointment(id: 41, startAt: now.add(day * 3));
      await reminders.resync([a], texts: texts, now: now);
      final details =
          verify(
                () => plugin.zonedSchedule(
                  any(),
                  any(),
                  any(),
                  any(),
                  captureAny(),
                  androidScheduleMode: any(named: 'androidScheduleMode'),
                  uiLocalNotificationDateInterpretation: any(
                    named: 'uiLocalNotificationDateInterpretation',
                  ),
                ),
              ).captured.single
              as NotificationDetails;
      expect(details.android!.visibility, NotificationVisibility.private);
    });

    test('an empty list just cancels everything', () async {
      expect(await reminders.resync([], texts: texts, now: now), 0);
      verify(() => plugin.cancelAll()).called(1);
      verifyNever(
        () => plugin.zonedSchedule(
          any(),
          any(),
          any(),
          any(),
          any(),
          androidScheduleMode: any(named: 'androidScheduleMode'),
          uiLocalNotificationDateInterpretation: any(
            named: 'uiLocalNotificationDateInterpretation',
          ),
        ),
      );
    });

    test('cancelAll (logout) cancels the plugin schedule', () async {
      await reminders.cancelAll();
      verify(() => plugin.cancelAll()).called(1);
    });

    test('calls run one after the other', () async {
      final order = <String>[];
      when(() => plugin.cancelAll()).thenAnswer((_) async {
        order.add('cancel start');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add('cancel end');
      });
      final first = reminders.resync([], texts: texts, now: now);
      final second = reminders.resync([], texts: texts, now: now);
      await Future.wait([first, second]);
      expect(order, [
        'cancel start',
        'cancel end',
        'cancel start',
        'cancel end',
      ]);
    });

    test('requestPermission never throws (denied = false)', () async {
      when(() => plugin.initialize(any())).thenThrow(StateError('no plugin'));
      expect(await reminders.requestPermission(), isFalse);
    });
  });
}
