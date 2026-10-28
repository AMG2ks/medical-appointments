import 'package:dio/dio.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/paginated.dart';
import 'models/availability.dart';
import 'models/doctor.dart';
import 'models/specialty.dart';
import 'models/time_off.dart';

/// Reference lists (specialties, weekly windows, time off) are small: ask for the largest
/// page the backend allows instead of paging them.
const _bigPage = 100;

/// All `/api/v1/specialties/` and `/api/v1/doctors/` calls. Errors come out as
/// [ApiException]. Features that need doctors depend on this class, so tests can swap in
/// a fake (`implements DoctorsRepository`).
class DoctorsRepository {
  DoctorsRepository(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, dynamic>? query,
  ]) => _dio
      .get<Map<String, dynamic>>(path, queryParameters: query)
      .then((r) => r.data!);

  // --- specialties ---

  Future<List<Specialty>> listSpecialties() => guardApi(() async {
    final page = Paginated.fromJson(
      await _get('specialties/', {'page_size': _bigPage}),
      Specialty.fromJson,
    );
    return page.results;
  });

  Future<Specialty> createSpecialty(Specialty draft) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      'specialties/',
      data: draft.toJson(),
    );
    return Specialty.fromJson(response.data!);
  });

  Future<Specialty> updateSpecialty(int id, Specialty draft) =>
      guardApi(() async {
        final response = await _dio.patch<Map<String, dynamic>>(
          'specialties/$id/',
          data: draft.toJson(),
        );
        return Specialty.fromJson(response.data!);
      });

  /// 409 `specialty_in_use` while doctors still use it.
  Future<void> deleteSpecialty(int id) =>
      guardApi(() => _dio.delete<void>('specialties/$id/'));

  // --- doctors ---

  Future<Paginated<Doctor>> listDoctors({
    int page = 1,
    int? specialtyId,
    String search = '',
  }) => guardApi(() async {
    final json = await _get('doctors/', {
      'page': page,
      if (specialtyId != null) 'specialty': specialtyId,
      if (search.isNotEmpty) 'search': search,
    });
    return Paginated.fromJson(json, Doctor.fromJson);
  });

  Future<Doctor> getDoctor(int id) =>
      guardApi(() async => Doctor.fromJson(await _get('doctors/$id/')));

  /// Admin: creates the doctor account and sends the invite email.
  Future<Doctor> createDoctor({
    required String email,
    required String firstName,
    required String lastName,
    required String phone,
    required String preferredLanguage,
    required int specialtyId,
    required int consultationMinutes,
    required String bio,
  }) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      'doctors/',
      data: {
        'email': email,
        'first_name': firstName,
        'last_name': lastName,
        if (phone.isNotEmpty) 'phone': phone,
        'preferred_language': preferredLanguage,
        'specialty_id': specialtyId,
        'consultation_minutes': consultationMinutes,
        'bio': bio,
      },
    );
    return Doctor.fromJson(response.data!);
  });

  // --- my profile (doctor) ---

  Future<Doctor> getMe() =>
      guardApi(() async => Doctor.fromJson(await _get('doctors/me/')));

  Future<Doctor> updateMe({
    required int specialtyId,
    required String bio,
    required int consultationMinutes,
  }) => guardApi(() async {
    final response = await _dio.patch<Map<String, dynamic>>(
      'doctors/me/',
      data: {
        'specialty_id': specialtyId,
        'bio': bio,
        'consultation_minutes': consultationMinutes,
      },
    );
    return Doctor.fromJson(response.data!);
  });

  // --- weekly availability (doctor) ---

  Future<List<Availability>> listAvailability() => guardApi(() async {
    final page = Paginated.fromJson(
      await _get('doctors/me/availability/', {'page_size': _bigPage}),
      Availability.fromJson,
    );
    return page.results;
  });

  /// 400 `availability_overlap` when it overlaps another window of the same weekday.
  Future<Availability> createAvailability({
    required int weekday,
    required TimeOfDay start,
    required TimeOfDay end,
  }) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      'doctors/me/availability/',
      data: {
        'weekday': weekday,
        'start_time': apiTime(start),
        'end_time': apiTime(end),
      },
    );
    return Availability.fromJson(response.data!);
  });

  Future<Availability> updateAvailability(
    int id, {
    required int weekday,
    required TimeOfDay start,
    required TimeOfDay end,
  }) => guardApi(() async {
    final response = await _dio.patch<Map<String, dynamic>>(
      'doctors/me/availability/$id/',
      data: {
        'weekday': weekday,
        'start_time': apiTime(start),
        'end_time': apiTime(end),
      },
    );
    return Availability.fromJson(response.data!);
  });

  Future<void> deleteAvailability(int id) =>
      guardApi(() => _dio.delete<void>('doctors/me/availability/$id/'));

  // --- time off (doctor) ---

  /// Newest first.
  Future<List<TimeOff>> listTimeOff() => guardApi(() async {
    final page = Paginated.fromJson(
      await _get('doctors/me/time-off/', {'page_size': _bigPage}),
      TimeOff.fromJson,
    );
    return page.results;
  });

  Future<TimeOff> createTimeOff({
    required DateTime startAt,
    required DateTime endAt,
    required String reason,
  }) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      'doctors/me/time-off/',
      data: {
        // No offset on purpose: the server reads it in its TIME_ZONE (the clinic's).
        'start_at': apiDateTime(startAt),
        'end_at': apiDateTime(endAt),
        'reason': reason,
      },
    );
    return TimeOff.fromJson(response.data!);
  });

  Future<void> deleteTimeOff(int id) =>
      guardApi(() => _dio.delete<void>('doctors/me/time-off/$id/'));
}

final doctorsRepositoryProvider = Provider<DoctorsRepository>(
  (ref) => DoctorsRepository(ref.watch(dioProvider)),
);
