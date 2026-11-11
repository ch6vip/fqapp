import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/migrating_secure_key_storage.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// The native key store is the authority after the #205 migration, but the
/// legacy `flutter_secure_storage` entries must be imported exactly once and
/// mirrored so a rollback to the previous build still finds the current key.
void main() {
  test('imports a legacy value and writes it forward only once', () async {
    final primary = _FakeStorage();
    final legacy = _FakeStorage({'k': 'legacy-key'});
    final storage = MigratingSecureKeyStorage(primary: primary, legacy: legacy);

    expect(await storage.read('k'), 'legacy-key');
    expect(primary.values['k'], 'legacy-key');
    expect(primary.writes, 1);

    expect(await storage.read('k'), 'legacy-key');
    expect(primary.writes, 1);
  });

  test('serves the primary value without touching the legacy store', () async {
    final primary = _FakeStorage({'k': 'native-key'});
    final legacy = _FakeStorage({'k': 'legacy-key'});
    final storage = MigratingSecureKeyStorage(primary: primary, legacy: legacy);

    expect(await storage.read('k'), 'native-key');
    expect(legacy.reads, 0);
  });

  test('reports absent only when both stores agree', () async {
    final storage = MigratingSecureKeyStorage(
      primary: _FakeStorage(),
      legacy: _FakeStorage(),
    );
    expect(await storage.read('k'), isNull);
  });

  test('a transient primary failure is rethrown, not read as absent', () async {
    // Returning null here would make SecureKeyProvider mint a new key and
    // quarantine the boxes encrypted under the real one.
    final storage = MigratingSecureKeyStorage(
      primary: _ThrowingStorage(),
      legacy: _FakeStorage(),
    );
    expect(storage.read('k'), throwsStateError);
  });

  test(
    'a legacy value still works while the primary store is failing',
    () async {
      final storage = MigratingSecureKeyStorage(
        primary: _ThrowingStorage(),
        legacy: _FakeStorage({'k': 'legacy-key'}),
      );
      expect(await storage.read('k'), 'legacy-key');
    },
  );

  test('writes both stores so an older build can still decrypt', () async {
    final primary = _FakeStorage();
    final legacy = _FakeStorage();
    final storage = MigratingSecureKeyStorage(primary: primary, legacy: legacy);

    await storage.write('k', 'fresh');
    expect(primary.values['k'], 'fresh');
    expect(legacy.values['k'], 'fresh');

    await storage.delete('k');
    expect(primary.values.containsKey('k'), isFalse);
    expect(legacy.values.containsKey('k'), isFalse);
  });

  test('a failing legacy mirror does not fail the write', () async {
    final storage = MigratingSecureKeyStorage(
      primary: _FakeStorage(),
      legacy: _ThrowingStorage(),
    );
    await storage.write('k', 'fresh');
    expect(await storage.read('k'), 'fresh');
  });

  test('SecureKeyProvider round-trips through the migrating store', () async {
    final primary = _FakeStorage({'fqapp_hive_encryption_key_v1': _key32});
    final provider = SecureKeyProvider(
      storage: MigratingSecureKeyStorage(
        primary: primary,
        legacy: _FakeStorage(),
      ),
    );
    expect(await provider.getOrCreateKey(), isNotNull);
    expect(primary.writes, 0);
  });
}

/// base64 of 32 bytes, i.e. a well-formed persisted key.
final _key32 = base64Encode(List<int>.generate(32, (index) => index));

class _FakeStorage implements SecureKeyStorage {
  _FakeStorage([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _ThrowingStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async => throw StateError('keystore down');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('keystore down');

  @override
  Future<void> delete(String key) async => throw StateError('keystore down');
}
