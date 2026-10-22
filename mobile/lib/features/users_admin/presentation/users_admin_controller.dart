import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/data/models/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/users_admin_api.dart';

class UsersListState {
  const UsersListState({
    this.users = const [],
    this.page = 1,
    this.hasNext = false,
    this.role,
    this.search = '',
  });

  final List<User> users;
  final int page;
  final bool hasNext;
  final UserRole? role;
  final String search;
}

class UsersAdminController extends AsyncNotifier<UsersListState> {
  UserRole? _role;
  String _search = '';

  @override
  Future<UsersListState> build() async {
    ref.watch(currentUserIdProvider); // reset on logout / account switch
    return _load(1);
  }

  Future<UsersListState> _load(int page) async {
    final result = await ref
        .read(usersAdminApiProvider)
        .list(page: page, role: _role, search: _search);
    final previous = page == 1 ? const <User>[] : state.requireValue.users;
    return UsersListState(
      users: [...previous, ...result.results],
      page: page,
      hasNext: result.hasNext,
      role: _role,
      search: _search,
    );
  }

  Future<void> setFilters({UserRole? role, String? search}) async {
    _role = role;
    _search = search ?? _search;
    state = const AsyncLoading<UsersListState>();
    state = await AsyncValue.guard(() => _load(1));
  }

  /// Role chips pass null for "all", so the role is set explicitly (not "keep").
  Future<void> setRole(UserRole? role) => setFilters(role: role);

  Future<void> setSearch(String search) =>
      setFilters(role: _role, search: search);

  bool _loadingMore = false;

  /// Next page. Ignored while one is loading. On failure the current list is kept and the
  /// error is thrown for the screen to show.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasNext || _loadingMore) return;
    _loadingMore = true;
    try {
      state = AsyncData(await _load(current.page + 1));
    } finally {
      _loadingMore = false;
    }
  }

  /// Throws ApiException (e.g. `cannot_deactivate_self`): the screen shows it.
  Future<void> setActive(User user, bool isActive) async {
    final updated = await ref
        .read(usersAdminApiProvider)
        .setActive(user.id, isActive: isActive);
    final current = state.requireValue;
    state = AsyncData(
      UsersListState(
        users: [
          for (final u in current.users) u.id == updated.id ? updated : u,
        ],
        page: current.page,
        hasNext: current.hasNext,
        role: current.role,
        search: current.search,
      ),
    );
  }
}

final usersAdminControllerProvider =
    AsyncNotifierProvider<UsersAdminController, UsersListState>(
      UsersAdminController.new,
    );
