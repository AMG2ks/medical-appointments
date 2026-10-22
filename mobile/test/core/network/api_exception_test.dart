import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/network/api_exception.dart';

DioException dioError({Object? body, int? status, DioExceptionType? type}) {
  final options = RequestOptions(path: 'x');
  return DioException(
    requestOptions: options,
    type: type ?? DioExceptionType.badResponse,
    response:
        body == null && status == null
            ? null
            : Response(requestOptions: options, statusCode: status, data: body),
  );
}

void main() {
  test('parses the error envelope with field codes', () {
    final e = ApiException.fromDioException(
      dioError(
        status: 400,
        body: {
          'error': {
            'code': 'validation_error',
            'message': 'Invalid input.',
            'fields': {
              'email': [
                {'code': 'unique', 'message': 'Already used.'},
              ],
            },
          },
        },
      ),
    );
    expect(e.statusCode, 400);
    expect(e.code, 'validation_error');
    expect(e.message, 'Invalid input.');
    expect(e.fieldError('email')!.code, 'unique');
    expect(e.fieldError('phone'), isNull);
  });

  test('flattens nested field errors with dotted keys', () {
    final e = ApiException.fromDioException(
      dioError(
        status: 400,
        body: {
          'error': {
            'code': 'validation_error',
            'message': 'x',
            'fields': {
              'patient_profile': {
                'date_of_birth': [
                  {'code': 'date_in_future', 'message': 'x'},
                ],
              },
            },
          },
        },
      ),
    );
    expect(
      e.fieldError('patient_profile.date_of_birth')!.code,
      'date_in_future',
    );
  });

  test('recurses into lists of maps (many=True) with the item index', () {
    final e = ApiException.fromDioException(
      dioError(
        status: 400,
        body: {
          'error': {
            'code': 'validation_error',
            'message': 'x',
            'fields': {
              'items': [
                {},
                {
                  'name': [
                    {'code': 'blank', 'message': 'x'},
                  ],
                },
              ],
            },
          },
        },
      ),
    );
    expect(e.fieldError('items.1.name')!.code, 'blank');
  });

  test('timeouts and connection errors become network_error', () {
    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      final e = ApiException.fromDioException(dioError(type: type));
      expect(e.code, ApiException.networkError);
      expect(e.isNetworkError, isTrue);
    }
  });

  test('an answer that is not the envelope becomes server_error', () {
    final e = ApiException.fromDioException(
      dioError(status: 502, body: '<html>bad gateway</html>'),
    );
    expect(e.code, ApiException.serverError);
    expect(e.statusCode, 502);
  });

  test('guardApi converts DioException', () async {
    await expectLater(
      guardApi<void>(
        () => throw dioError(type: DioExceptionType.connectionError),
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
