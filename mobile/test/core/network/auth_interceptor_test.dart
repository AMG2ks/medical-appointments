import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/auth_interceptor.dart';

import '../../support/fakes.dart';

void main() {
  late FakeTokenStorage tokens;
  late StubAdapter adapter;
  late Dio dio;
  late int refreshCalls;
  late int expiredCalls;
  late bool refreshFails;
  late bool refreshOffline;
  late int refreshStatus; // status of a failing refresh
  void Function()? duringRefresh; // simulates another writer of the storage

  setUp(() {
    tokens = FakeTokenStorage(access: 'a1', refresh: 'r1');
    refreshCalls = 0;
    expiredCalls = 0;
    refreshFails = false;
    refreshOffline = false;
    refreshStatus = 401;
    duringRefresh = null;

    // The backend accepts only the refreshed access token "a2".
    adapter = StubAdapter((options) async {
      if (options.path == 'auth/token/refresh/') {
        refreshCalls++;
        if (refreshOffline) {
          throw DioException.connectionError(
            requestOptions: options,
            reason: 'offline',
          );
        }
        duringRefresh?.call();
        if (refreshFails) {
          return jsonResponse({
            'error': {'code': 'token_not_valid', 'message': 'x', 'fields': {}},
          }, refreshStatus);
        }
        return jsonResponse({'access': 'a2', 'refresh': 'r2'});
      }
      if (options.headers['Authorization'] == 'Bearer a2' ||
          options.path.startsWith('auth/logout')) {
        return jsonResponse({'ok': true});
      }
      return jsonResponse({
        'error': {'code': 'token_not_valid', 'message': 'x', 'fields': {}},
      }, 401);
    });

    final plain = Dio(BaseOptions(baseUrl: 'http://test/api/v1/'))
      ..httpClientAdapter = adapter;
    dio =
        Dio(BaseOptions(baseUrl: 'http://test/api/v1/'))
          ..httpClientAdapter = adapter
          ..interceptors.add(
            AuthInterceptor(
              plainDio: plain,
              tokens: tokens,
              currentLanguage: () => 'en',
              onSessionExpired: () => expiredCalls++,
            ),
          );
  });

  test('adds the bearer token and Accept-Language', () async {
    tokens.access = 'a2';
    await dio.get<dynamic>('appointments/');
    final sent = adapter.requests.single.headers;
    expect(sent['Authorization'], 'Bearer a2');
    expect(sent['Accept-Language'], 'en');
  });

  test('a 401 triggers one refresh, saves both tokens and retries', () async {
    final response = await dio.get<dynamic>('appointments/');
    expect(response.statusCode, 200);
    expect(refreshCalls, 1);
    expect(tokens.access, 'a2');
    expect(tokens.refresh, 'r2');
    expect(adapter.requests.last.headers['Authorization'], 'Bearer a2');
  });

  test('two parallel 401s refresh only once', () async {
    final results = await Future.wait([
      dio.get<dynamic>('appointments/'),
      dio.get<dynamic>('notifications/'),
    ]);
    expect(results.map((r) => r.statusCode), [200, 200]);
    expect(refreshCalls, 1);
  });

  test('a failed refresh clears the storage and expires the session', () async {
    refreshFails = true;
    await expectLater(
      dio.get<dynamic>('appointments/'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          401,
        ),
      ),
    );
    expect(tokens.access, isNull);
    expect(tokens.refresh, isNull);
    expect(expiredCalls, 1);
  });

  test('a network error while refreshing keeps the session', () async {
    refreshOffline = true;
    await expectLater(
      dio.get<dynamic>('appointments/'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.connectionError,
        ),
      ),
    );
    expect(tokens.refresh, 'r1');
    expect(expiredCalls, 0);
  });

  test('a 401 on login is returned as is (no refresh)', () async {
    await expectLater(
      dio.post<dynamic>('auth/login/'),
      throwsA(isA<DioException>()),
    );
    expect(refreshCalls, 0);
    expect(
      adapter.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
  });

  test('the logout request carries no bearer token', () async {
    await dio.post<dynamic>('auth/logout/', data: {'refresh': 'r1'});
    expect(
      adapter.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
    expect(refreshCalls, 0);
  });

  test('a failed refresh with 400 also expires the session', () async {
    refreshFails = true;
    refreshStatus = 400;
    await expectLater(
      dio.get<dynamic>('appointments/'),
      throwsA(isA<DioException>()),
    );
    expect(tokens.refresh, isNull);
    expect(expiredCalls, 1);
  });

  test('a retried request that is still 401 does not loop', () async {
    tokens.access = 'a1';
    // The backend never accepts "a2" here, so the retry fails with 401 again.
    adapter = StubAdapter((options) async {
      if (options.path == 'auth/token/refresh/') {
        refreshCalls++;
        return jsonResponse({'access': 'a2', 'refresh': 'r2'});
      }
      return jsonResponse({
        'error': {'code': 'token_not_valid', 'message': 'x', 'fields': {}},
      }, 401);
    });
    dio.httpClientAdapter = adapter;
    final interceptor = dio.interceptors.whereType<AuthInterceptor>().single;
    interceptor.plainDio.httpClientAdapter = adapter;

    await expectLater(
      dio.get<dynamic>('appointments/'),
      throwsA(isA<DioException>()),
    );
    expect(refreshCalls, 1);
    expect(adapter.requests.where((r) => r.path == 'appointments/').length, 2);
  });

  test('a session changed during the refresh is not overwritten', () async {
    duringRefresh = () {
      // e.g. the user logged in again while the refresh was in flight
      tokens.access = 'b1';
      tokens.refresh = 'r9';
    };
    await expectLater(
      dio.get<dynamic>('appointments/'),
      throwsA(isA<DioException>()),
    );
    expect(tokens.refresh, 'r9');
    expect(tokens.access, 'b1');
    expect(expiredCalls, 0);
    expect(adapter.requests.last.headers['Authorization'], 'Bearer b1');
  });

  test(
    'a refresh failure for an outdated session does not expire the new one',
    () async {
      refreshFails = true;
      duringRefresh = () {
        tokens.access = 'b1';
        tokens.refresh = 'r9';
      };
      await expectLater(
        dio.get<dynamic>('appointments/'),
        throwsA(isA<DioException>()),
      );
      expect(tokens.refresh, 'r9');
      expect(expiredCalls, 0);
    },
  );

  test('the bearer token is never sent to another origin', () async {
    tokens.access = 'a2';
    // The stub answers 401 without a valid bearer: it must neither get ours nor trigger
    // a refresh for a foreign host.
    await expectLater(
      dio.get<dynamic>('http://evil.example/steal'),
      throwsA(isA<DioException>()),
    );
    expect(
      adapter.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
    expect(refreshCalls, 0);
  });

  test('public paths are matched exactly', () async {
    tokens.access = 'a2';
    await dio.get<dynamic>('appointments/auth/login/'); // looks public, is not
    expect(adapter.requests.single.headers['Authorization'], 'Bearer a2');
  });
}
