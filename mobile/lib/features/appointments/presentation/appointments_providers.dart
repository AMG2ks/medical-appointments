import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_controller.dart';
import '../data/appointments_repository.dart';
import '../data/models/appointment.dart';

// Every user-scoped provider watches currentUserIdProvider so its data resets on logout.

/// Which appointments a list shows: a scope (upcoming / past), a calendar day, or both
/// null for everything. A record, so it is a valid family key.
typedef AppointmentsQuery = ({AppointmentScope? scope, DateTime? day});

/// A calendar day without time (the clinic's day as the user sees it).
DateTime dayOf(DateTime moment) =>
    DateTime(moment.year, moment.month, moment.day);

class AppointmentsListState {
  const AppointmentsListState({
    this.items = const [],
    this.page = 1,
    this.hasNext = false,
  });

  final List<Appointment> items;
  final int page;
  final bool hasNext;
}

/// One list (patient tabs, doctor agenda tabs), paged.
class AppointmentsListController extends AsyncNotifier<AppointmentsListState> {
  AppointmentsListController(this.query);

  final AppointmentsQuery query;
  bool _loadingMore = false;

  /// Bumped by every (re)build: a page that arrives after a rebuild belongs to a list that
  /// no longer exists and is dropped.
  int _generation = 0;

  @override
  Future<AppointmentsListState> build() {
    ref.watch(currentUserIdProvider);
    _generation++;
    return _fetch(1, const []);
  }

  Future<AppointmentsListState> _fetch(
    int page,
    List<Appointment> previous,
  ) async {
    final result = await ref
        .read(appointmentsRepositoryProvider)
        .list(page: page, scope: query.scope, day: query.day);
    return AppointmentsListState(
      items: [...previous, ...result.results],
      page: page,
      hasNext: result.hasNext,
    );
  }

  /// Next page. Ignored while one is loading; on failure the list is kept and the error
  /// is thrown for the screen to show.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasNext || _loadingMore) return;
    _loadingMore = true;
    final generation = _generation;
    try {
      final next = await _fetch(current.page + 1, current.items);
      // The provider may have been rebuilt or disposed while the page was in flight.
      if (!ref.mounted || generation != _generation) return;
      state = AsyncData(next);
    } finally {
      _loadingMore = false;
    }
  }
}

final appointmentsListProvider = AsyncNotifierProvider.family<
  AppointmentsListController,
  AppointmentsListState,
  AppointmentsQuery
>(AppointmentsListController.new);

/// Not kept alive: opening a detail always shows fresh data.
final appointmentProvider = FutureProvider.autoDispose.family<Appointment, int>(
  (ref, id) {
    ref.watch(currentUserIdProvider);
    return ref.read(appointmentsRepositoryProvider).get(id);
  },
);

/// Free slots of a doctor on a day. Not kept alive: leaving the booking screen forgets them.
final slotsProvider = FutureProvider.autoDispose
    .family<List<Slot>, ({int doctorId, DateTime day})>((ref, query) {
      ref.watch(currentUserIdProvider);
      return ref
          .read(appointmentsRepositoryProvider)
          .slots(doctorId: query.doctorId, day: query.day);
    });

/// Every confirmed appointment that has not started (all pages). M4 watches this one to
/// resync the on-device reminders: it reloads after every booking and cancellation.
final upcomingConfirmedProvider = FutureProvider<List<Appointment>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.read(appointmentsRepositoryProvider).fetchUpcoming();
});

/// Writes. Each one throws ApiException for the screen to show; after a success every
/// cached list / detail / slots answer is dropped so screens reload from the server.
class AppointmentsActions {
  AppointmentsActions(this._ref);

  final Ref _ref;

  AppointmentsRepository get _repo => _ref.read(appointmentsRepositoryProvider);

  Future<Appointment> _done(Future<Appointment> call) async {
    final appointment = await call;
    _ref
      ..invalidate(appointmentsListProvider)
      ..invalidate(appointmentProvider)
      ..invalidate(slotsProvider)
      ..invalidate(upcomingConfirmedProvider);
    return appointment;
  }

  /// 409 `slot_taken`, 400 `slot_not_available`.
  Future<Appointment> book({
    required int doctorId,
    required Slot slot,
    String reason = '',
  }) => _done(
    _repo.book(doctorId: doctorId, startAtIso: slot.startIso, reason: reason),
  );

  Future<Appointment> cancel(int id, {String reason = ''}) =>
      _done(_repo.cancel(id, reason: reason));

  Future<Appointment> complete(int id) => _done(_repo.complete(id));

  Future<Appointment> markNoShow(int id) => _done(_repo.markNoShow(id));
}

final appointmentsActionsProvider = Provider<AppointmentsActions>(
  AppointmentsActions.new,
);
