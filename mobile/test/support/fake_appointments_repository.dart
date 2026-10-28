import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/core/network/paginated.dart';
import 'package:medical_appointments/features/appointments/data/appointments_repository.dart';
import 'package:medical_appointments/features/appointments/data/models/appointment.dart';

import 'fake_doctors_repository.dart';

/// A UTC instant plus the clinic wall clock of the same moment (UTC+1 in the tests).
Appointment fakeAppointment({
  int id = 1,
  DateTime? startAt,
  int minutes = 30,
  AppointmentStatus status = AppointmentStatus.confirmed,
  String patientName = 'Amira Ben Salah',
  String doctorName = 'Sarah Miller',
  String reason = '',
  String? cancelledByRole,
  String cancellationReason = '',
}) {
  final utc = startAt ?? DateTime.now().toUtc().add(const Duration(days: 3));
  final clinic = utc.add(const Duration(hours: 1));
  DateTime wall(DateTime d) =>
      DateTime(d.year, d.month, d.day, d.hour, d.minute);
  final names = patientName.split(' ');
  final doctorNames = doctorName.split(' ');
  return Appointment(
    id: id,
    patient: AppointmentPerson(
      id: 1,
      firstName: names.first,
      lastName: names.skip(1).join(' '),
      phone: '+21620123456',
    ),
    doctor: AppointmentPerson(
      id: 10,
      firstName: doctorNames.first,
      lastName: doctorNames.skip(1).join(' '),
      specialty: cardiology,
    ),
    startAt: utc,
    endAt: utc.add(Duration(minutes: minutes)),
    start: wall(clinic),
    end: wall(clinic.add(Duration(minutes: minutes))),
    status: status,
    reason: reason,
    cancelledByRole: cancelledByRole,
    cancellationReason: cancellationReason,
  );
}

Slot fakeSlot(int hour, [int minute = 0]) {
  String two(int n) => n.toString().padLeft(2, '0');
  return Slot(
    startIso: '2026-11-05T${two(hour)}:${two(minute)}:00+01:00',
    start: DateTime(2026, 11, 5, hour, minute),
    end: DateTime(2026, 11, 5, hour, minute + 30),
  );
}

/// In-memory stand-in for [AppointmentsRepository] (M4 can reuse it for reminder tests).
class FakeAppointmentsRepository implements AppointmentsRepository {
  FakeAppointmentsRepository({
    List<Appointment>? appointments,
    List<Slot>? freeSlots,
    this.pageSize = 20,
  }) : appointments = appointments ?? [],
       freeSlots = freeSlots ?? [fakeSlot(9), fakeSlot(9, 30), fakeSlot(10)];

  final List<Appointment> appointments;

  /// Answer of `slots()` whatever the day.
  List<Slot> freeSlots;
  final int pageSize;

  /// Set to make the matching call fail (once set it keeps failing until cleared).
  ApiException? slotsError;
  ApiException? listError;
  ApiException? bookError;
  ApiException? actionError;

  final calls = <String>[];
  var _nextId = 500;

  @override
  Future<List<Slot>> slots({
    required int doctorId,
    required DateTime day,
  }) async {
    calls.add('slots doctor=$doctorId day=${day.year}-${day.month}-${day.day}');
    if (slotsError != null) throw slotsError!;
    return [...freeSlots];
  }

  @override
  Future<Appointment> book({
    required int doctorId,
    required String startAtIso,
    String reason = '',
  }) async {
    calls.add('book doctor=$doctorId start=$startAtIso reason=$reason');
    if (bookError != null) throw bookError!;
    final booked = fakeAppointment(
      id: _nextId++,
      startAt: DateTime.parse(startAtIso).toUtc(),
      reason: reason,
    );
    appointments.add(booked);
    return booked;
  }

  bool _isUpcoming(Appointment a) =>
      a.status == AppointmentStatus.confirmed &&
      a.startAt.isAfter(DateTime.now());

  @override
  Future<Paginated<Appointment>> list({
    int page = 1,
    AppointmentScope? scope,
    AppointmentStatus? status,
    DateTime? day,
    int pageSize = 20,
  }) async {
    calls.add('list page=$page scope=${scope?.name} day=$day status=$status');
    if (listError != null) throw listError!;
    final matching = [
      for (final a in appointments)
        if ((scope == null ||
                (scope == AppointmentScope.upcoming) == _isUpcoming(a)) &&
            (status == null || a.status == status) &&
            (day == null ||
                (a.start.year == day.year &&
                    a.start.month == day.month &&
                    a.start.day == day.day)))
          a,
    ]..sort((a, b) => a.startAt.compareTo(b.startAt));
    if (scope == AppointmentScope.past) {
      matching.sort((a, b) => b.startAt.compareTo(a.startAt));
    }
    final from = (page - 1) * this.pageSize;
    return Paginated(
      count: matching.length,
      hasNext: from + this.pageSize < matching.length,
      results: matching.skip(from).take(this.pageSize).toList(),
    );
  }

  @override
  Future<Appointment> get(int id) async => appointments.firstWhere(
    (a) => a.id == id,
    orElse: () => throw const ApiException(statusCode: 404, code: 'not_found'),
  );

  Future<Appointment> _change(
    int id,
    AppointmentStatus status, {
    String reason = '',
    String? by,
  }) async {
    if (actionError != null) throw actionError!;
    final current = await get(id);
    final updated = fakeAppointment(
      id: id,
      startAt: current.startAt,
      status: status,
      cancelledByRole: by,
      cancellationReason: reason,
    );
    appointments[appointments.indexWhere((a) => a.id == id)] = updated;
    return updated;
  }

  @override
  Future<Appointment> cancel(int id, {String reason = ''}) {
    calls.add('cancel $id reason=$reason');
    return _change(
      id,
      AppointmentStatus.cancelled,
      reason: reason,
      by: 'patient',
    );
  }

  @override
  Future<Appointment> complete(int id) {
    calls.add('complete $id');
    return _change(id, AppointmentStatus.completed);
  }

  @override
  Future<Appointment> markNoShow(int id) {
    calls.add('noShow $id');
    return _change(id, AppointmentStatus.noShow);
  }

  @override
  Future<List<Appointment>> fetchUpcoming() async {
    calls.add('fetchUpcoming');
    if (listError != null) throw listError!;
    return [...appointments.where(_isUpcoming)]
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
  }
}
