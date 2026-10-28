import 'dart:async';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/core/network/paginated.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';
import 'package:medical_appointments/features/doctors/data/doctors_repository.dart';
import 'package:medical_appointments/features/doctors/data/models/doctor.dart';
import 'package:medical_appointments/features/doctors/presentation/doctors_providers.dart';

import '../../support/fake_doctors_repository.dart';
import '../../support/test_app.dart';

/// Answers `listDoctors` only when the test releases it, to reorder responses.
class GatedRepository extends FakeDoctorsRepository {
  GatedRepository({super.doctors, super.pageSize});

  bool open = true;
  final pending = <({String search, Completer<void> gate})>[];

  @override
  Future<Paginated<Doctor>> listDoctors({
    int page = 1,
    int? specialtyId,
    String search = '',
  }) async {
    if (!open) {
      final gate = Completer<void>();
      pending.add((search: search, gate: gate));
      await gate.future;
    }
    return super.listDoctors(
      page: page,
      specialtyId: specialtyId,
      search: search,
    );
  }
}

void main() {
  late FakeDoctorsRepository repo;

  Future<ProviderContainer> container() async => makeContainer([
    ...await baseOverrides(),
    doctorsRepositoryProvider.overrideWithValue(repo),
    currentUserIdProvider.overrideWithValue(1),
  ]);

  test(
    'filters and search are sent to the repository and reset paging',
    () async {
      repo = FakeDoctorsRepository(
        doctors: [
          fakeDoctor(
            id: 1,
            firstName: 'Amira',
            lastName: 'Zouari',
            specialty: dermatology,
          ),
          fakeDoctor(id: 2, firstName: 'Sarah', lastName: 'Miller'),
        ],
      );
      final c = await container();
      expect((await c.read(doctorsListProvider.future)).doctors, hasLength(2));

      final controller = c.read(doctorsListProvider.notifier);
      await controller.setSpecialty(dermatology.id);
      expect(c.read(doctorsListProvider).requireValue.doctors.single.id, 1);

      await controller.setSpecialty(null);
      await controller.setSearch('  mill ');
      final state = c.read(doctorsListProvider).requireValue;
      expect(state.doctors.single.id, 2);
      expect(state.search, 'mill');
      expect(repo.calls.last, 'listDoctors page=1 specialty=null search=mill');
    },
  );

  test('loadMore appends the next page, then stops', () async {
    repo = FakeDoctorsRepository(
      pageSize: 2,
      doctors: [
        for (var i = 1; i <= 3; i++) fakeDoctor(id: i, lastName: 'D$i'),
      ],
    );
    final c = await container();
    await c.read(doctorsListProvider.future);
    final controller = c.read(doctorsListProvider.notifier);
    expect(c.read(doctorsListProvider).requireValue.hasNext, isTrue);

    await controller.loadMore();
    final state = c.read(doctorsListProvider).requireValue;
    expect(state.doctors.map((d) => d.id), [1, 2, 3]);
    expect(state.hasNext, isFalse);

    await controller.loadMore(); // nothing left: no extra request
    expect(repo.calls, hasLength(2));
  });

  test(
    'availability: add refreshes the list, an overlap is rethrown',
    () async {
      repo = FakeDoctorsRepository();
      final c = await container();
      await c.read(availabilityProvider.future);
      final controller = c.read(availabilityProvider.notifier);
      const nine = TimeOfDay(hour: 9, minute: 0);
      const twelve = TimeOfDay(hour: 12, minute: 0);

      await controller.add(0, nine, twelve);
      expect((await c.read(availabilityProvider.future)), hasLength(1));

      await expectLater(
        controller.add(
          0,
          const TimeOfDay(hour: 11, minute: 0),
          const TimeOfDay(hour: 13, minute: 0),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'availability_overlap',
          ),
        ),
      );
      expect((await c.read(availabilityProvider.future)), hasLength(1));

      await controller.remove(
        (await c.read(availabilityProvider.future)).single.id,
      );
      expect((await c.read(availabilityProvider.future)), isEmpty);
    },
  );

  test('time off: add then remove', () async {
    repo = FakeDoctorsRepository();
    final c = await container();
    await c.read(timeOffProvider.future);
    final controller = c.read(timeOffProvider.notifier);
    await controller.add(
      DateTime(2026, 11, 3),
      DateTime(2026, 11, 5),
      'Holidays',
    );
    final items = (await c.read(timeOffProvider.future));
    expect(items.single.reason, 'Holidays');
    await controller.remove(items.single.id);
    expect((await c.read(timeOffProvider.future)), isEmpty);
  });

  test('specialties: deleting one in use rethrows specialty_in_use', () async {
    repo = FakeDoctorsRepository();
    final c = await container();
    await c.read(specialtiesProvider.future);
    final controller = c.read(specialtiesProvider.notifier);
    await expectLater(
      controller.remove(cardiology.id),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'specialty_in_use'),
      ),
    );
    await controller.remove(dermatology.id);
    expect((await c.read(specialtiesProvider.future)).map((s) => s.id), [
      cardiology.id,
    ]);
  });

  test('my profile: save replaces the state', () async {
    repo = FakeDoctorsRepository();
    final c = await container();
    await c.read(myDoctorProfileProvider.future);
    await c
        .read(myDoctorProfileProvider.notifier)
        .save(
          specialtyId: dermatology.id,
          bio: 'New bio',
          consultationMinutes: 45,
        );
    final me = c.read(myDoctorProfileProvider).requireValue;
    expect(
      (me.bio, me.consultationMinutes, me.specialty.id),
      ('New bio', 45, 2),
    );
  });

  group('stale responses', () {
    GatedRepository gated() => GatedRepository(
      pageSize: 2,
      doctors: [
        for (var i = 1; i <= 3; i++) fakeDoctor(id: i, lastName: 'D$i'),
      ],
    );

    test('a late next page is dropped after the filter changed', () async {
      final gatedRepo = repo = gated();
      final c = await container();
      await c.read(doctorsListProvider.future);
      final controller = c.read(doctorsListProvider.notifier);

      gatedRepo.open = false;
      final more =
          controller.loadMore(); // page 2 of the unfiltered list, in flight
      final reload = controller.setSearch('D1'); // new filter meanwhile
      expect(c.read(doctorsListProvider).isLoading, isTrue);

      gatedRepo.pending[0].gate.complete(); // the stale page arrives first
      await more; // no StateError, no overwrite
      expect(c.read(doctorsListProvider).isLoading, isTrue);

      gatedRepo.pending[1].gate.complete();
      await reload;
      final state = c.read(doctorsListProvider).requireValue;
      expect(state.doctors.map((d) => d.id), [1]);
      expect(state.search, 'D1');
    });

    test('the older of two reloads cannot win', () async {
      final gatedRepo = repo = gated();
      final c = await container();
      await c.read(doctorsListProvider.future);
      final controller = c.read(doctorsListProvider.notifier);

      gatedRepo.open = false;
      final first = controller.setSearch('D1');
      final second = controller.setSearch('D2');
      gatedRepo.pending[1].gate.complete(); // newest answers first
      await second;
      gatedRepo.pending[0].gate.complete(); // oldest answers last
      await first;
      final state = c.read(doctorsListProvider).requireValue;
      expect(state.search, 'D2');
      expect(state.doctors.map((d) => d.id), [2]);
    });
  });
}
