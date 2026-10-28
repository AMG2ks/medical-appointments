import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/paginated.dart';
import '../../../core/utils/date_format.dart';
import 'models/appointment.dart';

const _maxPageSize = 100;

/// Safety net for [AppointmentsRepository.fetchUpcoming] (100 per page).
const _maxUpcomingPages = 10;

/// All `/api/v1/appointments/` calls. Errors come out as [ApiException]. Other features
/// depend on this class so tests can swap in a fake (`implements AppointmentsRepository`).
///
/// M4 (on-device reminders): call [fetchUpcoming] and reschedule from its result.
class AppointmentsRepository {
  AppointmentsRepository(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, dynamic>? query,
  ]) => _dio
      .get<Map<String, dynamic>>(path, queryParameters: query)
      .then((r) => r.data!);

  /// Free slots of [doctorId] on [day] (a calendar day of the clinic). Empty on past days,
  /// days off and days beyond the booking horizon. 404 for a doctor that cannot be booked.
  Future<List<Slot>> slots({required int doctorId, required DateTime day}) =>
      guardApi(() async {
        final json = await _get('appointments/slots/', {
          'doctor': doctorId,
          'date': apiDate(day),
        });
        return [
          for (final item in json['slots'] as List<dynamic>)
            Slot.fromJson(item as Map<String, dynamic>),
        ];
      });

  /// Books a slot (confirmed at once). 409 `slot_taken`, 400 `slot_not_available`.
  Future<Appointment> book({
    required int doctorId,
    required String startAtIso,
    String reason = '',
  }) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      'appointments/',
      data: {
        'doctor': doctorId,
        'start_at': startAtIso,
        if (reason.isNotEmpty) 'reason': reason,
      },
    );
    return Appointment.fromJson(response.data!);
  });

  /// My appointments (patient: own, doctor: own agenda, admin: all).
  Future<Paginated<Appointment>> list({
    int page = 1,
    AppointmentScope? scope,
    AppointmentStatus? status,
    DateTime? day,
    int pageSize = 20,
  }) => guardApi(() async {
    final json = await _get('appointments/', {
      'page': page,
      'page_size': pageSize,
      if (scope != null) 'scope': scope.name,
      if (status != null) 'status': status.apiValue,
      if (day != null) 'date': apiDate(day),
    });
    return Paginated.fromJson(json, Appointment.fromJson);
  });

  Future<Appointment> get(int id) => guardApi(
    () async => Appointment.fromJson(await _get('appointments/$id/')),
  );

  /// Patient: until `CANCELLATION_MIN_HOURS` before the start (else 400
  /// `cancellation_too_late`). Doctor: until the start, [reason] required.
  Future<Appointment> cancel(int id, {String reason = ''}) =>
      _action(id, 'cancel', data: {'reason': reason});

  /// Doctor, once the appointment has started. 409 `invalid_status_transition` otherwise.
  Future<Appointment> complete(int id) => _action(id, 'complete');

  Future<Appointment> markNoShow(int id) => _action(id, 'no-show');

  Future<Appointment> _action(int id, String action, {Object? data}) =>
      guardApi(() async {
        final response = await _dio.post<Map<String, dynamic>>(
          'appointments/$id/$action/',
          data: data,
        );
        return Appointment.fromJson(response.data!);
      });

  /// Every confirmed appointment that has not started yet, earliest first (all pages).
  /// This is what the on-device reminders (M4) are rebuilt from.
  Future<List<Appointment>> fetchUpcoming() async {
    final all = <Appointment>[];
    for (var page = 1; page <= _maxUpcomingPages; page++) {
      final result = await list(
        page: page,
        scope: AppointmentScope.upcoming,
        status: AppointmentStatus.confirmed,
        pageSize: _maxPageSize,
      );
      all.addAll(result.results);
      if (!result.hasNext) break;
    }
    return all;
  }
}

final appointmentsRepositoryProvider = Provider<AppointmentsRepository>(
  (ref) => AppointmentsRepository(ref.watch(dioProvider)),
);
