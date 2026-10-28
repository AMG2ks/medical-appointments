import 'package:dio/dio.dart';

/// One error of one field: `{"code": "unique", "message": "..."}`.
class ApiFieldError {
  const ApiFieldError({required this.code, required this.message});

  final String code;
  final String message;
}

/// The backend error envelope `{"error": {"code", "message", "fields"}}` (TEAM_PLAN 4.3),
/// or a client-side `network_error` / `server_error`.
///
/// [fields] keys of nested serializers are dotted: `patient_profile.date_of_birth`.
class ApiException implements Exception {
  const ApiException({
    this.statusCode,
    required this.code,
    this.message = '',
    this.fields = const {},
    this.details = const {},
  });

  final int? statusCode;
  final String code;
  final String message;
  final Map<String, List<ApiFieldError>> fields;

  /// Extra data some business errors carry (`error.details`), e.g. the appointments that
  /// block a time off. Empty when the server sent none.
  final Map<String, dynamic> details;

  static const networkError = 'network_error';
  static const serverError = 'server_error';

  bool get isNetworkError => code == networkError;

  /// First error of [field], if the server reported one.
  ApiFieldError? fieldError(String field) {
    final errors = fields[field];
    return (errors == null || errors.isEmpty) ? null : errors.first;
  }

  factory ApiException.fromDioException(DioException e) {
    final status = e.response?.statusCode;
    final parsed = _parse(e.response?.data, status);
    if (parsed != null) return parsed;

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const ApiException(code: networkError);
      default:
        return ApiException(statusCode: status, code: serverError);
    }
  }

  static ApiException? _parse(Object? body, int? status) {
    if (body is! Map) return null;
    final error = body['error'];
    if (error is! Map || error['code'] is! String) return null;
    final fields = <String, List<ApiFieldError>>{};
    _collectFields(error['fields'], '', fields);
    return ApiException(
      statusCode: status,
      code: error['code'] as String,
      message: (error['message'] as String?) ?? '',
      fields: fields,
      details:
          error['details'] is Map
              ? (error['details'] as Map).cast<String, dynamic>()
              : const {},
    );
  }

  /// Flattens nested field errors. A list of {code, message} is a leaf; a list of other
  /// maps (many=True serializers) recurses with the item index: `items.0.name`.
  static void _collectFields(
    Object? node,
    String prefix,
    Map<String, List<ApiFieldError>> out,
  ) {
    if (node is! Map) return;
    node.forEach((key, value) {
      final path = prefix.isEmpty ? '$key' : '$prefix.$key';
      if (value is List) {
        final leaves = <ApiFieldError>[];
        for (var i = 0; i < value.length; i++) {
          final item = value[i];
          if (item is Map && item['code'] is String) {
            leaves.add(
              ApiFieldError(
                code: item['code'] as String,
                message: (item['message'] as String?) ?? '',
              ),
            );
          } else {
            _collectFields(item is Map ? {'$i': item} : null, path, out);
          }
        }
        if (leaves.isNotEmpty || value.isEmpty) out[path] = leaves;
      } else {
        _collectFields(value, path, out);
      }
    });
  }

  @override
  String toString() => 'ApiException($statusCode, $code)';
}

/// Runs an API call and turns Dio errors into [ApiException]. Use it in every `*_api.dart`.
Future<T> guardApi<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on DioException catch (e) {
    throw ApiException.fromDioException(e);
  }
}
