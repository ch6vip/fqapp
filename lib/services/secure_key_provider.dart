import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

/// Minimal read/write surface over the platform secure store, kept as an
/// interface so tests can substitute an in-memory fake instead of driving a
/// MethodChannel.
abstract interface class SecureKeyStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Production backend: `flutter_secure_storage` (Android Keystore /
/// EncryptedSharedPreferences, iOS Keychain). The raw key bytes never touch
/// SharedPreferences or any other plaintext store.
class FlutterSecureKeyStorage implements SecureKeyStorage {
  const FlutterSecureKeyStorage([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
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
}

/// Owns the random 256-bit keys that encrypt local data at rest.
///
/// One key per purpose, all base64-encoded in secure storage:
/// - [hiveBoxKeyName]: the Hive `HiveAesCipher` key for every encrypted box
///   (see `EncryptedHive`);
/// - [devicePoolKeyName]: the Rust device-pool file key, handed to the core
///   via the `set_device_pool_key` FRB call at startup (P1-2). Sharing the
///   infrastructure but not the key material: compromising one store must not
///   open the other.
///
/// A missing entry is created once (random 256-bit via
/// `Hive.generateSecureKey`) and persisted; a present-but-malformed entry is
/// treated as a lost key and replaced, which makes the boxes encrypted under
/// the old key unreadable — `EncryptedHive` then treats those boxes as empty
/// rather than falling back to plaintext. When secure storage itself throws
/// (no platform channel, Keystore failure), `null` is returned and callers
/// degrade per their own policy instead of failing startup.
class SecureKeyProvider {
  SecureKeyProvider({SecureKeyStorage? storage})
    : _storage = storage ?? const FlutterSecureKeyStorage();

  static final SecureKeyProvider instance = SecureKeyProvider();

  /// Hive box encryption key (base64 of 32 random bytes).
  static const hiveBoxKeyName = 'fqapp_hive_encryption_key_v1';

  /// Rust device-pool file encryption key (base64 of 32 random bytes).
  static const devicePoolKeyName = 'fqapp_device_pool_key_v1';

  final SecureKeyStorage _storage;
  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List?>> _pending = {};

  Future<Uint8List?> getOrCreateKey({String name = hiveBoxKeyName}) {
    final cached = _cache[name];
    if (cached != null) return Future.value(cached);
    return _pending[name] ??= _loadOrCreate(name).then((key) {
      _pending.remove(name);
      return key;
    });
  }

  Future<Uint8List?> _loadOrCreate(String name) async {
    try {
      final stored = await _storage.read(name);
      if (stored != null) {
        try {
          final decoded = base64Decode(stored);
          if (decoded.length == 32) {
            final bytes = Uint8List.fromList(decoded);
            _cache[name] = bytes;
            return bytes;
          }
        } catch (_) {
          // Malformed entry: fall through and replace it (key lost).
        }
      }
      final fresh = Uint8List.fromList(Hive.generateSecureKey());
      await _storage.write(name, base64Encode(fresh));
      _cache[name] = fresh;
      return fresh;
    } catch (_) {
      // Secure storage unavailable: caller decides how to degrade.
      return null;
    }
  }

  /// Device-pool file key for the P1-2 FRB handoff. Same infrastructure as
  /// the Hive key, separate key material.
  Future<Uint8List?> devicePoolKey() =>
      getOrCreateKey(name: devicePoolKeyName);

  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _pending.clear();
  }
}
