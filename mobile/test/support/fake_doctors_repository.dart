import 'package:flutter/material.dart' show TimeOfDay;
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/core/network/paginated.dart';
import 'package:medical_appointments/features/doctors/data/doctors_repository.dart';
import 'package:medical_appointments/features/doctors/data/models/availability.dart';
import 'package:medical_appointments/features/doctors/data/models/doctor.dart';
import 'package:medical_appointments/features/doctors/data/models/specialty.dart';
import 'package:medical_appointments/features/doctors/data/models/time_off.dart';

const cardiology = Specialty(
  id: 1,
  nameFr: 'Cardiologie',
  nameEn: 'Cardiology',
);
const dermatology = Specialty(
  id: 2,
  nameFr: 'Dermatologie',
  nameEn: 'Dermatology',
);

Doctor fakeDoctor({
  int id = 10,
  String firstName = 'Sarah',
  String lastName = 'Miller',
  Specialty specialty = cardiology,
  String bio = 'Bio of the doctor.',
}) => Doctor(
  id: id,
  firstName: firstName,
  lastName: lastName,
  specialty: specialty,
  bio: bio,
  consultationMinutes: 30,
);

/// In-memory stand-in for M2's repository, usable by other modules' tests too
/// (`doctorsRepositoryProvider.overrideWithValue(FakeDoctorsRepository())`).
class FakeDoctorsRepository implements DoctorsRepository {
  FakeDoctorsRepository({
    List<Doctor>? doctors,
    List<Specialty>? specialties,
    this.pageSize = 20,
  }) : doctors = doctors ?? [fakeDoctor()],
       specialties = specialties ?? [cardiology, dermatology];

  final List<Doctor> doctors;
  final List<Specialty> specialties;
  final int pageSize;
  final List<Availability> availability = [];
  final List<TimeOff> timeOff = [];

  /// Set to make the matching call fail.
  ApiException? listSpecialtiesError;
  ApiException? createDoctorError;
  final calls = <String>[];
  var _nextId = 100;

  @override
  Future<List<Specialty>> listSpecialties() async {
    if (listSpecialtiesError != null) throw listSpecialtiesError!;
    return [...specialties];
  }

  @override
  Future<Specialty> createSpecialty(Specialty draft) async {
    final created = Specialty(
      id: _nextId++,
      nameFr: draft.nameFr,
      nameEn: draft.nameEn,
    );
    specialties.add(created);
    return created;
  }

  @override
  Future<Specialty> updateSpecialty(int id, Specialty draft) async {
    final updated = Specialty(
      id: id,
      nameFr: draft.nameFr,
      nameEn: draft.nameEn,
    );
    specialties[specialties.indexWhere((s) => s.id == id)] = updated;
    return updated;
  }

  @override
  Future<void> deleteSpecialty(int id) async {
    if (doctors.any((d) => d.specialty.id == id)) {
      throw const ApiException(statusCode: 409, code: 'specialty_in_use');
    }
    specialties.removeWhere((s) => s.id == id);
  }

  @override
  Future<Paginated<Doctor>> listDoctors({
    int page = 1,
    int? specialtyId,
    String search = '',
  }) async {
    calls.add('listDoctors page=$page specialty=$specialtyId search=$search');
    final matching = [
      for (final d in doctors)
        if ((specialtyId == null || d.specialty.id == specialtyId) &&
            d.fullName.toLowerCase().contains(search.toLowerCase()))
          d,
    ];
    final from = (page - 1) * pageSize;
    final slice = matching.skip(from).take(pageSize).toList();
    return Paginated(
      count: matching.length,
      hasNext: from + pageSize < matching.length,
      results: slice,
    );
  }

  @override
  Future<Doctor> getDoctor(int id) async => doctors.firstWhere(
    (d) => d.id == id,
    orElse: () => throw const ApiException(statusCode: 404, code: 'not_found'),
  );

  @override
  Future<Doctor> createDoctor({
    required String email,
    required String firstName,
    required String lastName,
    required String phone,
    required String preferredLanguage,
    required int specialtyId,
    required int consultationMinutes,
    required String bio,
  }) async {
    if (createDoctorError != null) throw createDoctorError!;
    final doctor = fakeDoctor(
      id: _nextId++,
      firstName: firstName,
      lastName: lastName,
      specialty: specialties.firstWhere((s) => s.id == specialtyId),
    );
    doctors.add(doctor);
    return doctor;
  }

  @override
  Future<Doctor> getMe() async => doctors.first;

  @override
  Future<Doctor> updateMe({
    required int specialtyId,
    required String bio,
    required int consultationMinutes,
  }) async {
    final me = doctors.first;
    final updated = Doctor(
      id: me.id,
      firstName: me.firstName,
      lastName: me.lastName,
      specialty: specialties.firstWhere((s) => s.id == specialtyId),
      bio: bio,
      consultationMinutes: consultationMinutes,
    );
    doctors[0] = updated;
    return updated;
  }

  @override
  Future<List<Availability>> listAvailability() async => [...availability];

  @override
  Future<Availability> createAvailability({
    required int weekday,
    required TimeOfDay start,
    required TimeOfDay end,
  }) async {
    int minutes(TimeOfDay t) => t.hour * 60 + t.minute;
    final overlaps = availability.any(
      (a) =>
          a.weekday == weekday &&
          minutes(start) < minutes(a.end) &&
          minutes(end) > minutes(a.start),
    );
    if (overlaps) {
      throw const ApiException(statusCode: 400, code: 'availability_overlap');
    }
    final created = Availability(
      id: _nextId++,
      weekday: weekday,
      start: start,
      end: end,
    );
    availability.add(created);
    return created;
  }

  @override
  Future<Availability> updateAvailability(
    int id, {
    required int weekday,
    required TimeOfDay start,
    required TimeOfDay end,
  }) async => throw UnimplementedError();

  @override
  Future<void> deleteAvailability(int id) async =>
      availability.removeWhere((a) => a.id == id);

  @override
  Future<List<TimeOff>> listTimeOff() async => [...timeOff];

  @override
  Future<TimeOff> createTimeOff({
    required DateTime startAt,
    required DateTime endAt,
    required String reason,
  }) async {
    final created = TimeOff(
      id: _nextId++,
      startAt: startAt,
      endAt: endAt,
      reason: reason,
    );
    timeOff.add(created);
    return created;
  }

  @override
  Future<void> deleteTimeOff(int id) async =>
      timeOff.removeWhere((t) => t.id == id);
}
