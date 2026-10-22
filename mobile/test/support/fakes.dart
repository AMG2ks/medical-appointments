import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:medical_appointments/core/storage/token_storage.dart';
import 'package:medical_appointments/features/auth/data/models/user.dart';

/// In-memory tokens (Dart classes are implicit interfaces, so no abstract class is needed).
class FakeTokenStorage implements TokenStorage {
  FakeTokenStorage({this.access, this.refresh});

  String? access;
  String? refresh;

  @override
  Future<String?> readAccess() async => access;

  @override
  Future<String?> readRefresh() async => refresh;

  @override
  Future<void> save({required String access, required String refresh}) async {
    this.access = access;
    this.refresh = refresh;
  }

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
  }
}

/// Answers every request with [handler] and records them.
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Object? body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

User fakeUser({UserRole role = UserRole.patient, String language = 'fr'}) =>
    User(
      id: 1,
      email: 'amira@example.com',
      firstName: 'Amira',
      lastName: 'Ben Salah',
      phone: '',
      role: role,
      preferredLanguage: language,
      isActive: true,
      dateJoined: DateTime(2026, 11, 2),
      patientProfile: role == UserRole.patient ? const PatientProfile() : null,
    );
