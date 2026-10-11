import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// JWT storage -- flutter_secure_storage (Keychain/Keystore-backed on
/// mobile, encrypted-at-rest on web via the browser's subtle-crypto-backed
/// storage). Never kept in shared_preferences or any plaintext location.
class TokenStorage {
  TokenStorage() : _storage = const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _tokenKey = 'auth_access_token';

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<void> writeToken(String token) => _storage.write(key: _tokenKey, value: token);

  Future<void> clearToken() => _storage.delete(key: _tokenKey);
}
