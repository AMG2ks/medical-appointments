import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/appointments/data/appointments_repository.dart';
import 'package:medical_appointments/features/appointments/data/models/appointment.dart';
import 'package:medical_appointments/features/doctors/data/models/time_off.dart';

import '../../support/fakes.dart';

Map<String, dynamic> appointmentJson({
  int id = 7,
  String status = 'confirmed',
  Map<String, dynamic>? cancelledBy,
  String cancellationReason = '',
}) => {
  'id': id,
  'patient': {
    'id': 1,
    'first_name': 'Amira',
    'last_name': 'Ben Salah',
    'email': 'amira@medapp.local',
    'phone': '+21620123456',
  },
  'doctor': {
    'id': 10,
    'first_name': 'Sarah',
    'last_name': 'Miller',
    'specialty': {'id': 1, 'name_fr': 'Cardiologie', 'name_en': 'Cardiology'},
  },
  'start_at': '2026-11-05T10:00:00+01:00',
  'end_at': '2026-11-05T10:30:00+01:00',
  'status': status,
  'reason': 'Checkup',
  'cancelled_by': cancelledBy,
  'cancellation_reason': cancellationReason,
  'created_at': '2026-11-02T06:00:00Z',
  'updated_at': '2026-11-02T06:00:00Z',
};

Map<String, dynamic> pageJson(
  List<Map<String, dynamic>> items, {
  bool next = false,
}) => {
  'count': items.length,
  'next': next ? 'http://test/api/v1/appointments/?page=2' : null,
  'previous': null,
  'results': items,
};

void main() {
  late StubAdapter adapter;
  late AppointmentsRepository repo;

  void answer(Object? Function(RequestOptions) body, [int status = 200]) {
    adapter = StubAdapter(
      (options) async => jsonResponse(body(options), status),
    );
    repo = AppointmentsRepository(
      Dio(BaseOptions(baseUrl: 'http://test/api/v1/'))
        ..httpClientAdapter = adapter,
    );
  }

  test(
    'parses an appointment: absolute instants and clinic wall clock',
    () async {
      answer((_) => appointmentJson());
      final a = await repo.get(7);
      expect(adapter.requests.single.path, 'appointments/7/');
      expect(a.startAt, DateTime.utc(2026, 11, 5, 9)); // 10:00+01:00
      expect(a.startAt.isUtc, isTrue);
      expect(
        a.start,
        DateTime(2026, 11, 5, 10),
      ); // clinic wall clock, zone-less
      expect(a.end, DateTime(2026, 11, 5, 10, 30));
      expect(a.status, AppointmentStatus.confirmed);
      expect(a.doctor.specialty!.nameEn, 'Cardiology');
      expect(a.patient.fullName, 'Amira Ben Salah');
      expect(a.cancelledByRole, isNull);
    },
  );

  test('an unknown status is read as unknown, not as confirmed', () async {
    answer((_) => appointmentJson(status: 'something_new'));
    final a = await repo.get(7);
    expect(a.status, AppointmentStatus.unknown);
    expect(a.isConfirmed, isFalse);
  });

  test('parses a cancelled appointment', () async {
    answer(
      (_) => appointmentJson(
        status: 'no_show',
        cancelledBy: {'id': 10, 'role': 'doctor'},
        cancellationReason: 'Away',
      ),
    );
    final a = await repo.get(7);
    expect(a.status, AppointmentStatus.noShow);
    expect(a.cancelledByRole, 'doctor');
    expect(a.cancellationReason, 'Away');
  });

  test(
    'slots sends the doctor and the day and keeps the original instant',
    () async {
      answer(
        (_) => {
          'doctor': 10,
          'date': '2026-11-05',
          'consultation_minutes': 30,
          'slots': [
            {
              'start_at': '2026-11-05T09:00:00+01:00',
              'end_at': '2026-11-05T09:30:00+01:00',
            },
          ],
        },
      );
      final slots = await repo.slots(
        doctorId: 10,
        day: DateTime(2026, 11, 5, 13, 45),
      );
      final request = adapter.requests.single;
      expect(request.path, 'appointments/slots/');
      expect(request.queryParameters, {'doctor': 10, 'date': '2026-11-05'});
      expect(slots.single.startIso, '2026-11-05T09:00:00+01:00');
      expect(slots.single.start, DateTime(2026, 11, 5, 9));
    },
  );

  test(
    'book posts the slot instant as received and omits an empty reason',
    () async {
      answer((_) => appointmentJson(), 201);
      await repo.book(doctorId: 10, startAtIso: '2026-11-05T10:00:00+01:00');
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, 'appointments/');
      expect(request.data, {
        'doctor': 10,
        'start_at': '2026-11-05T10:00:00+01:00',
      });
      await repo.book(doctorId: 10, startAtIso: 'x', reason: 'Cough');
      expect(adapter.requests.last.data['reason'], 'Cough');
    },
  );

  test('slot_taken comes out as an ApiException', () async {
    answer(
      (_) => {
        'error': {'code': 'slot_taken', 'message': 'Taken', 'fields': {}},
      },
      409,
    );
    await expectLater(
      repo.book(doctorId: 10, startAtIso: 'x'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'slot_taken')
            .having((e) => e.statusCode, 'status', 409),
      ),
    );
  });

  test('list sends scope, status and day only when given', () async {
    answer((_) => pageJson([appointmentJson()], next: true));
    final page = await repo.list(
      page: 2,
      scope: AppointmentScope.past,
      status: AppointmentStatus.noShow,
      day: DateTime(2026, 11, 5),
    );
    expect(adapter.requests.single.queryParameters, {
      'page': 2,
      'page_size': 20,
      'scope': 'past',
      'status': 'no_show',
      'date': '2026-11-05',
    });
    expect(page.hasNext, isTrue);
    await repo.list();
    expect(adapter.requests.last.queryParameters, {'page': 1, 'page_size': 20});
  });

  test('cancel, complete and no-show hit their endpoints', () async {
    answer((_) => appointmentJson());
    await repo.cancel(7, reason: 'Sick');
    expect(adapter.requests.last.path, 'appointments/7/cancel/');
    expect(adapter.requests.last.data, {'reason': 'Sick'});
    await repo.complete(7);
    expect(adapter.requests.last.path, 'appointments/7/complete/');
    await repo.markNoShow(7);
    expect(adapter.requests.last.path, 'appointments/7/no-show/');
    expect(adapter.requests.last.method, 'POST');
  });

  test(
    'fetchUpcoming (for M4 reminders) reads every page of confirmed upcoming',
    () async {
      answer((options) {
        final page = options.queryParameters['page'] as int;
        return pageJson([appointmentJson(id: page)], next: page < 3);
      });
      final all = await repo.fetchUpcoming();
      expect(all.map((a) => a.id), [1, 2, 3]);
      final first = adapter.requests.first.queryParameters;
      expect(first['scope'], 'upcoming');
      expect(first['status'], 'confirmed');
      expect(first['page_size'], 100);
    },
  );

  test(
    'ApiException keeps error.details; TimeOffConflict reads them',
    () async {
      answer(
        (_) => {
          'error': {
            'code': 'time_off_conflict',
            'message': 'Busy',
            'fields': {},
            'details': {
              'count': 3,
              'appointments': [
                {
                  'id': 4,
                  'start_at': '2026-11-05T10:00:00+01:00',
                  'end_at': '2026-11-05T10:30:00+01:00',
                  'patient_name': 'Pat Ient',
                },
              ],
            },
          },
        },
        409,
      );
      try {
        await repo.get(1);
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.details['count'], 3);
        final conflict = TimeOffConflict.from(e)!;
        expect(conflict.count, 3);
        expect(conflict.items.single.patientName, 'Pat Ient');
        expect(conflict.items.single.startAt, DateTime(2026, 11, 5, 10));
      }
      expect(TimeOffConflict.from(const ApiException(code: 'other')), isNull);
      expect(TimeOffConflict.from('x'), isNull);
    },
  );
}
