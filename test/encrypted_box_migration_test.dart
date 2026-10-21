import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/services/encrypted_box_migration.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// 加密存储撤销后的一次性迁移：`<name>_enc` 加密箱 → 同名明文箱。
void main() {
  late Directory dir;
  late InMemorySecureKeyStorage storage;
  late SecureKeyProvider keys;
  late Uint8List keyBytes;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fqapp-enc-migration-');
    Hive.init(dir.path);
    storage = InMemorySecureKeyStorage();
    keys = SecureKeyProvider(storage: storage);
    keyBytes = Uint8List.fromList(Hive.generateSecureKey());
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<void> seedEncryptedBox(
    String name,
    Map<dynamic, dynamic> entries, {
    Uint8List? withKey,
  }) async {
    final box = await Hive.openBox<dynamic>(
      '${name}_enc',
      encryptionCipher: HiveAesCipher(withKey ?? keyBytes),
    );
    await box.putAll(entries);
    await box.close();
  }

  Future<void> storeKey() => storage.write(
    SecureKeyProvider.hiveBoxKeyName,
    base64Encode(keyBytes),
  );

  test('encrypted entries are copied to the plaintext box, enc deleted',
      () async {
    await storeKey();
    await seedEncryptedBox('shelf', {'a': 1, 'b': 'two'});

    await EncryptedBoxMigration.migrateAll(Hive, keys: keys);

    expect(await Hive.boxExists('shelf_enc'), isFalse);
    final plain = await Hive.openBox<dynamic>('shelf');
    expect(plain.get('a'), 1);
    expect(plain.get('b'), 'two');
    expect(plain.length, 2);
  });

  test('no existing key skips the box, keeps enc files, never throws',
      () async {
    await seedEncryptedBox('shelf', {'a': 1});

    await EncryptedBoxMigration.migrateAll(Hive, keys: keys);

    expect(await Hive.boxExists('shelf_enc'), isTrue);
    expect(await Hive.boxExists('shelf'), isFalse);
    // The migration must not create a key as a side effect.
    expect(await storage.read(SecureKeyProvider.hiveBoxKeyName), isNull);
  });

  test('a wrong key skips the box and keeps the encrypted data', () async {
    await storeKey();
    await seedEncryptedBox('shelf', {'a': 1},
        withKey: Uint8List.fromList(Hive.generateSecureKey()));

    await EncryptedBoxMigration.migrateAll(Hive, keys: keys);

    expect(await Hive.boxExists('shelf_enc'), isTrue);
    expect(await Hive.boxExists('shelf'), isFalse);
  });

  test('throwing secure storage skips silently', () async {
    await seedEncryptedBox('shelf', {'a': 1});
    final throwing = SecureKeyProvider(storage: _ThrowingStorage());

    await EncryptedBoxMigration.migrateAll(Hive, keys: throwing);

    expect(await Hive.boxExists('shelf_enc'), isTrue);
  });

  test('existing plaintext entries win over encrypted copies', () async {
    await storeKey();
    await seedEncryptedBox('shelf', {'a': 'old', 'b': 'enc-only'});
    final plain = await Hive.openBox<dynamic>('shelf');
    await plain.put('a', 'newer-plaintext');
    await plain.close();

    await EncryptedBoxMigration.migrateAll(Hive, keys: keys);

    final merged = await Hive.openBox<dynamic>('shelf');
    expect(merged.get('a'), 'newer-plaintext');
    expect(merged.get('b'), 'enc-only');
    expect(await Hive.boxExists('shelf_enc'), isFalse);
  });

  test('migration is idempotent across launches', () async {
    await storeKey();
    await seedEncryptedBox('history', {'h1': 'x'});

    await EncryptedBoxMigration.migrateAll(Hive, keys: keys);
    await Hive.close();
    Hive.init(dir.path);
    await EncryptedBoxMigration.migrateAll(Hive, keys: keys);

    final plain = await Hive.openBox<dynamic>('history');
    expect(plain.get('h1'), 'x');
    expect(await Hive.boxExists('history_enc'), isFalse);
  });
}

class _ThrowingStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async {
    throw StateError('secure storage unavailable');
  }

  @override
  Future<void> write(String key, String value) async {
    throw StateError('secure storage unavailable');
  }
}
