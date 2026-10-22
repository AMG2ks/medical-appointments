import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/paginated.dart';
import '../../auth/data/models/user.dart';

/// Admin endpoints `/api/v1/users/`.
class UsersAdminApi {
  UsersAdminApi(this._dio);

  final Dio _dio;

  Future<Paginated<User>> list({
    int page = 1,
    UserRole? role,
    String search = '',
  }) => guardApi(() async {
    final response = await _dio.get<Map<String, dynamic>>(
      'users/',
      queryParameters: {
        'page': page,
        if (role != null) 'role': role.name,
        if (search.isNotEmpty) 'search': search,
      },
    );
    return Paginated.fromJson(response.data!, User.fromJson);
  });

  Future<User> setActive(int id, {required bool isActive}) =>
      guardApi(() async {
        final response = await _dio.patch<Map<String, dynamic>>(
          'users/$id/',
          data: {'is_active': isActive},
        );
        return User.fromJson(response.data!);
      });
}

final usersAdminApiProvider = Provider<UsersAdminApi>(
  (ref) => UsersAdminApi(ref.watch(dioProvider)),
);
