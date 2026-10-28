import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_controller.dart';
import '../data/doctors_repository.dart';
import '../data/models/availability.dart';
import '../data/models/doctor.dart';
import '../data/models/specialty.dart';
import '../data/models/time_off.dart';

// Every user-scoped provider watches currentUserIdProvider so its data resets on logout.

// --- specialties ---

/// All specialties. Read by the doctors filter and the pickers; the admin edits it.
class SpecialtiesController extends AsyncNotifier<List<Specialty>> {
  @override
  Future<List<Specialty>> build() {
    ref.watch(currentUserIdProvider);
    return ref.read(doctorsRepositoryProvider).listSpecialties();
  }

  // The mutators throw ApiException for the screen to show. After a successful write the
  // list is only invalidated: a failing reload must not make a saved change look failed;
  // the screen shows that error with its retry button instead.

  Future<void> create(Specialty draft) async {
    await ref.read(doctorsRepositoryProvider).createSpecialty(draft);
    ref.invalidateSelf();
  }

  Future<void> edit(int id, Specialty draft) async {
    await ref.read(doctorsRepositoryProvider).updateSpecialty(id, draft);
    ref.invalidateSelf();
    // Doctors show the specialty name: refresh the cards that embed it.
    ref.invalidate(doctorsListProvider);
    ref.invalidate(doctorProvider);
    ref.invalidate(myDoctorProfileProvider);
  }

  /// Throws `specialty_in_use` (409) while doctors use it.
  Future<void> remove(int id) async {
    await ref.read(doctorsRepositoryProvider).deleteSpecialty(id);
    ref.invalidateSelf();
  }
}

final specialtiesProvider =
    AsyncNotifierProvider<SpecialtiesController, List<Specialty>>(
      SpecialtiesController.new,
    );

// --- doctors list ---

class DoctorsListState {
  const DoctorsListState({
    this.doctors = const [],
    this.page = 1,
    this.hasNext = false,
    this.specialtyId,
    this.search = '',
  });

  final List<Doctor> doctors;
  final int page;
  final bool hasNext;
  final int? specialtyId;
  final String search;
}

class DoctorsListController extends AsyncNotifier<DoctorsListState> {
  int? _specialtyId;
  String _search = '';
  bool _loadingMore = false;

  /// Bumped by every (re)load. A response that belongs to an older generation (the user
  /// changed the filter, or the provider was rebuilt, while it was in flight) is dropped.
  int _generation = 0;

  @override
  Future<DoctorsListState> build() {
    ref.watch(currentUserIdProvider);
    _generation++;
    return _fetch(1, _specialtyId, _search, const []);
  }

  Future<DoctorsListState> _fetch(
    int page,
    int? specialtyId,
    String search,
    List<Doctor> previous,
  ) async {
    final result = await ref
        .read(doctorsRepositoryProvider)
        .listDoctors(page: page, specialtyId: specialtyId, search: search);
    return DoctorsListState(
      doctors: [...previous, ...result.results],
      page: page,
      hasNext: result.hasNext,
      specialtyId: specialtyId,
      search: search,
    );
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    state = const AsyncLoading<DoctorsListState>();
    final next = await AsyncValue.guard(
      () => _fetch(1, _specialtyId, _search, const []),
    );
    if (generation == _generation) state = next;
  }

  /// `null` = all specialties.
  Future<void> setSpecialty(int? id) {
    _specialtyId = id;
    return _reload();
  }

  Future<void> setSearch(String search) {
    _search = search.trim();
    return _reload();
  }

  /// Next page. Ignored while one is loading; on failure the list is kept and the error
  /// is thrown for the screen to show. If the filters change meanwhile, the page that
  /// arrives late is dropped.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasNext || _loadingMore) return;
    _loadingMore = true;
    final generation = _generation;
    try {
      final next = await _fetch(
        current.page + 1,
        current.specialtyId,
        current.search,
        current.doctors,
      );
      if (generation == _generation) state = AsyncData(next);
    } finally {
      _loadingMore = false;
    }
  }
}

final doctorsListProvider =
    AsyncNotifierProvider<DoctorsListController, DoctorsListState>(
      DoctorsListController.new,
    );

final doctorProvider = FutureProvider.family<Doctor, int>((ref, id) {
  ref.watch(currentUserIdProvider);
  return ref.read(doctorsRepositoryProvider).getDoctor(id);
});

// --- my professional profile (doctor) ---

class MyDoctorProfileController extends AsyncNotifier<Doctor> {
  @override
  Future<Doctor> build() {
    ref.watch(currentUserIdProvider);
    return ref.read(doctorsRepositoryProvider).getMe();
  }

  /// Throws ApiException on failure; the screen shows it.
  Future<void> save({
    required int specialtyId,
    required String bio,
    required int consultationMinutes,
  }) async {
    final updated = await ref
        .read(doctorsRepositoryProvider)
        .updateMe(
          specialtyId: specialtyId,
          bio: bio,
          consultationMinutes: consultationMinutes,
        );
    state = AsyncData(updated);
  }
}

final myDoctorProfileProvider =
    AsyncNotifierProvider<MyDoctorProfileController, Doctor>(
      MyDoctorProfileController.new,
    );

// --- weekly availability (doctor) ---

class AvailabilityController extends AsyncNotifier<List<Availability>> {
  @override
  Future<List<Availability>> build() {
    ref.watch(currentUserIdProvider);
    return ref.read(doctorsRepositoryProvider).listAvailability();
  }

  // The server is the judge of overlaps (`availability_overlap`): after every successful
  // change the list is invalidated and reloaded from it. Mutators throw ApiException for
  // the screen to show.
  void _refresh() => ref.invalidateSelf();

  Future<void> add(int weekday, TimeOfDay start, TimeOfDay end) async {
    await ref
        .read(doctorsRepositoryProvider)
        .createAvailability(weekday: weekday, start: start, end: end);
    _refresh();
  }

  Future<void> edit(int id, int weekday, TimeOfDay start, TimeOfDay end) async {
    await ref
        .read(doctorsRepositoryProvider)
        .updateAvailability(id, weekday: weekday, start: start, end: end);
    _refresh();
  }

  Future<void> remove(int id) async {
    await ref.read(doctorsRepositoryProvider).deleteAvailability(id);
    _refresh();
  }
}

final availabilityProvider =
    AsyncNotifierProvider<AvailabilityController, List<Availability>>(
      AvailabilityController.new,
    );

// --- time off (doctor) ---

class TimeOffController extends AsyncNotifier<List<TimeOff>> {
  @override
  Future<List<TimeOff>> build() {
    ref.watch(currentUserIdProvider);
    return ref.read(doctorsRepositoryProvider).listTimeOff();
  }

  Future<void> add(DateTime startAt, DateTime endAt, String reason) async {
    await ref
        .read(doctorsRepositoryProvider)
        .createTimeOff(startAt: startAt, endAt: endAt, reason: reason);
    ref.invalidateSelf();
  }

  Future<void> remove(int id) async {
    await ref.read(doctorsRepositoryProvider).deleteTimeOff(id);
    ref.invalidateSelf();
  }
}

final timeOffProvider = AsyncNotifierProvider<TimeOffController, List<TimeOff>>(
  TimeOffController.new,
);
