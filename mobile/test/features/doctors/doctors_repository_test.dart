import 'package:dio/dio.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/features/doctors/data/doctors_repository.dart';

import '../../support/fakes.dart';

const _doctorJson = {
  'id': 10,
  'first_name': 'Sarah',
  'last_name': 'Miller',
  'specialty': {'id': 1, 'name_fr': 'Cardiologie', 'name_en': 'Cardiology'},
  'bio': '',
  'consultation_minutes': 20,
};

void main() {
  late StubAdapter adapter;
  late DoctorsRepository repo;

  void answer(Object? body, [int status = 200]) {
    adapter = StubAdapter((_) async => jsonResponse(body, status));
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api/v1/'))
      ..httpClientAdapter = adapter;
    repo = DoctorsRepository(dio);
  }

  test('listDoctors sends filters and parses the page', () async {
    answer({
      'count': 21,
      'next': 'http://test/api/v1/doctors/?page=2',
      'previous': null,
      'results': [_doctorJson],
    });
    final page = await repo.listDoctors(page: 2, specialtyId: 1, search: 'mil');
    final request = adapter.requests.single;
    expect(request.path, 'doctors/');
    expect(request.queryParameters, {
      'page': 2,
      'specialty': 1,
      'search': 'mil',
    });
    expect(page.hasNext, isTrue);
    final doctor = page.results.single;
    expect(doctor.fullName, 'Sarah Miller');
    expect(doctor.specialty.nameFor('en'), 'Cardiology');
    expect(doctor.specialty.nameFor('fr'), 'Cardiologie');
    expect(doctor.email, isNull);
  });

  test('listDoctors omits empty filters', () async {
    answer({'count': 0, 'next': null, 'previous': null, 'results': []});
    await repo.listDoctors();
    expect(adapter.requests.single.queryParameters, {'page': 1});
  });

  test('createAvailability sends HH:mm and parses seconds', () async {
    answer({
      'id': 5,
      'weekday': 0,
      'start_time': '09:00:00',
      'end_time': '12:30:00',
    }, 201);
    final item = await repo.createAvailability(
      weekday: 0,
      start: const TimeOfDay(hour: 9, minute: 0),
      end: const TimeOfDay(hour: 12, minute: 30),
    );
    expect(adapter.requests.single.data, {
      'weekday': 0,
      'start_time': '09:00',
      'end_time': '12:30',
    });
    expect(item.end, const TimeOfDay(hour: 12, minute: 30));
  });

  test('an availability_overlap answer becomes an ApiException', () async {
    answer({
      'error': {
        'code': 'availability_overlap',
        'message': 'x',
        'fields': <String, dynamic>{},
      },
    }, 400);
    expect(
      repo.createAvailability(
        weekday: 0,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 10, minute: 0),
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'availability_overlap',
        ),
      ),
    );
  });

  test('createTimeOff sends wall-clock times without offset', () async {
    answer({
      'id': 1,
      'start_at': '2026-11-03T00:00:00+01:00',
      'end_at': '2026-11-05T00:00:00+01:00',
      'reason': 'Holidays',
    }, 201);
    final item = await repo.createTimeOff(
      startAt: DateTime(2026, 11, 3),
      endAt: DateTime(2026, 11, 5),
      reason: 'Holidays',
    );
    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['start_at'], '2026-11-03T00:00:00');
    expect(body['end_at'], '2026-11-05T00:00:00');
    // The answer keeps the clinic's wall clock whatever the phone's zone.
    expect(item.endAt, DateTime(2026, 11, 5));
  });

  test('deleteSpecialty in use is a 409 specialty_in_use', () async {
    answer({
      'error': {
        'code': 'specialty_in_use',
        'message': 'x',
        'fields': <String, dynamic>{},
      },
    }, 409);
    expect(
      repo.deleteSpecialty(1),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'specialty_in_use')
            .having((e) => e.statusCode, 'status', 409),
      ),
    );
  });

  test('createDoctor sends specialty_id and skips an empty phone', () async {
    answer({..._doctorJson, 'email': 'a@b.co', 'phone': ''}, 201);
    final doctor = await repo.createDoctor(
      email: 'a@b.co',
      firstName: 'Sarah',
      lastName: 'Miller',
      phone: '',
      preferredLanguage: 'en',
      specialtyId: 1,
      consultationMinutes: 20,
      bio: '',
    );
    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['specialty_id'], 1);
    expect(body.containsKey('phone'), isFalse);
    expect(doctor.email, 'a@b.co');
  });
}
