import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/paginated.dart';
import 'package:medical_appointments/features/appointments/data/appointments_repository.dart';
import 'package:medical_appointments/features/appointments/data/models/appointment.dart';
import 'package:medical_appointments/features/appointments/presentation/appointments_providers.dart';
import 'package:medical_appointments/features/auth/presentation/auth_controller.dart';

import '../../support/fake_appointments_repository.dart';
import '../../support/test_app.dart';

/// Answers pages after the first only when the test releases them.
class _GatedRepository extends FakeAppointmentsRepository {
  _GatedRepository({super.appointments, super.pageSize});

  final gate = Completer<void>();

  @override
  Future<Paginated<Appointment>> list({
    int page = 1,
    AppointmentScope? scope,
    AppointmentStatus? status,
    DateTime? day,
    int pageSize = 20,
  }) async {
    if (page > 1) await gate.future;
    return super.list(
      page: page,
      scope: scope,
      status: status,
      day: day,
      pageSize: pageSize,
    );
  }
}

void main() {
  const query = (scope: null, day: null);

  test(
    'a next page that arrives after a rebuild is dropped, no crash',
    () async {
      final repo = _GatedRepository(
        appointments: [for (var i = 1; i <= 3; i++) fakeAppointment(id: i)],
        pageSize: 1,
      );
      final container = makeContainer([
        ...await baseOverrides(),
        appointmentsRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWithValue(1),
      ]);
      final provider = appointmentsListProvider(query);
      final first = await container.read(provider.future);
      expect(first.items, hasLength(1));
      expect(first.hasNext, isTrue);

      final loading = container.read(provider.notifier).loadMore();
      container.invalidate(provider); // rebuilt while page 2 is in flight
      await container.read(provider.future);
      repo.gate.complete();
      await loading; // must not throw (UnmountedRefException)

      expect(container.read(provider).requireValue.items, hasLength(1));
    },
  );

  test('loadMore appends the next page', () async {
    final repo = FakeAppointmentsRepository(
      appointments: [for (var i = 1; i <= 3; i++) fakeAppointment(id: i)],
      pageSize: 2,
    );
    final container = makeContainer([
      ...await baseOverrides(),
      appointmentsRepositoryProvider.overrideWithValue(repo),
      currentUserIdProvider.overrideWithValue(1),
    ]);
    final provider = appointmentsListProvider(query);
    await container.read(provider.future);
    await container.read(provider.notifier).loadMore();
    expect(container.read(provider).requireValue.items, hasLength(3));
    expect(container.read(provider).requireValue.hasNext, isFalse);
  });
}
