import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Access + refresh tokens in the platform keystore, cached in memory after the first read.
/// Tokens never go to `shared_preferences`, logs or route parameters.
class TokenStorage {
  TokenStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';

  final FlutterSecureStorage _storage;
  String? _access;
  String? _refresh;
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) return;
    _access = await _storage.read(key: _accessKey);
    _refresh = await _storage.read(key: _refreshKey);
    _loaded = true;
  }

  Future<String?> readAccess() async {
    await _load();
    return _access;
  }

  Future<String?> readRefresh() async {
    await _load();
    return _refresh;
  }

  Future<void> save({required String access, required String refresh}) async {
    _access = access;
    _refresh = refresh;
    _loaded = true;
    // Refresh first: if the app dies in between, the session can still be restored.
    await _storage.write(key: _refreshKey, value: refresh);
    await _storage.write(key: _accessKey, value: access);
  }

  Future<void> clear() async {
    _access = null;
    _refresh = null;
    _loaded = true;
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }
}
