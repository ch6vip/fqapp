import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal read/write surface over the platform secure store, kept as an
/// interface so tests can substitute an in-memory fake instead of driving a
/// MethodChannel.
abstract interface class SecureKeyStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Legacy backend: `flutter_secure_storage` (Android Keystore + RSA-wrapped
/// AES, iOS Keychain, Windows DPAPI, Linux libsecret).
///
/// Kept only as a one-release *import source* for the key migration to
/// [NativeSecureKeyStorage]. This package pinned `win32` to 5.x through
/// `flutter_secure_storage_windows 3.1.2`, which blocked `wakelock_plus` and
/// `package_info_plus` from moving to their Built-in-Kotlin releases (#205).
/// Remove this class and the dependency once every in-field install has
/// migrated; see `DEVELOPMENT.md` →「本机密钥库」.
class FlutterSecureKeyStorage implements SecureKeyStorage {
  const FlutterSecureKeyStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory fake for tests and for environments without a platform channel.
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
