import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// P1-3: hive_ce + encrypted boxes with crash-safe legacy migration.
/// Uses a mock (in-memory) secure storage; never touches the platform channel.
void main() {
  late Directory dir;
  late InMemorySecureKeyStorage storage;
  late SecureKeyProvider keys;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fqapp-encrypted-hive-');
    Hive.init(dir.path);
    storage = InMemorySecureKeyStorage();
    keys = SecureKeyProvider(storage: storage);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('encrypted box does not leave plaintext on disk', () async {
    const sentinel = 'SECRET-CHAPTER-TEXT-7f3a9c';
    final box = await EncryptedHive.openBox<dynamic>(
      Hive,
      'chapter_cache_v1',
      keys: keys,
    );
    await box.put('k1', {'text': sentinel});
    await box.close();

    final files = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(
      files.any((p) => p.endsWith('chapter_cache_v1_enc.hive')),
      isTrue,
    );
    for (final path in files) {
      final bytes = File(path).readAsBytesSync();
      expect(
        String.fromCharCodes(bytes).contains(sentinel),
        isFalse,
        reason: 'plaintext leaked in $path',
      );
    }

    // Reopen with the same key: values round-trip.
    final reopened = await EncryptedHive.openBox<dynamic>(
      Hive,
      'chapter_cache_v1',
      keys: keys,
    );
    expect((reopened.get('k1') as Map)['text'], sentinel);
  });

  test('legacy plaintext box migrates and is deleted', () async {
    final legacy = await Hive.openBox<dynamic>('shelf');
    await legacy.put('a', {'title': 'Book A'});
    await legacy.put('b', {'title': 'Book B'});
    await legacy.close();

    final box = await EncryptedHive.openBox<dynamic>(
      Hive,
      'shelf',
      keys: keys,
    );
    expect((box.get('a') as Map)['title'], 'Book A');
    expect((box.get('b') as Map)['title'], 'Book B');
    expect(await Hive.boxExists('shelf'), isFalse);
    expect(await Hive.boxExists('shelf_enc'), isTrue);
  });

  test('partial encrypted box is completed from the legacy box', () async {
    // Simulate a crash between copy and delete: legacy full, encrypted partial.
    final legacy = await Hive.openBox<dynamic>('shelf');
    await legacy.put('a', {'title': 'Book A'});
    await legacy.put('b', {'title': 'Book B'});
    await legacy.close();

    final key = (await keys.getOrCreateKey())!;
    final partial = await Hive.openBox<dynamic>(
      'shelf_enc',
      encryptionCipher: HiveAesCipher(key),
    );
    await partial.put('a', {'title': 'Book A'});
    await partial.close();

    final box = await EncryptedHive.openBox<dynamic>(
      Hive,
      'shelf',
      keys: keys,
    );
    expect((box.get('a') as Map)['title'], 'Book A');
    expect((box.get('b') as Map)['title'], 'Book B');
    expect(await Hive.boxExists('shelf'), isFalse);
  });

  test('lost key treats the encrypted box as empty', () async {
    final box = await EncryptedHive.openBox<dynamic>(
      Hive,
      'shelf',
      keys: keys,
    );
    await box.put('a', {'title': 'Book A'});
    await box.close();

    // Fresh secure storage => fresh key that cannot open the old box.
    final lostKeys = SecureKeyProvider(
      storage: InMemorySecureKeyStorage(),
    );
    final reopened = await EncryptedHive.openBox<dynamic>(
      Hive,
      'shelf',
      keys: lostKeys,
    );
    expect(reopened.isEmpty, isTrue);
    expect(reopened.get('a'), isNull);
  });

  test('malformed stored key is replaced with a fresh 32-byte key', () async {
    await storage.write(
      SecureKeyProvider.hiveBoxKeyName,
      base64Encode(Uint8List.fromList([1, 2, 3])),
    );
    final key = await keys.getOrCreateKey();
    expect(key, isNotNull);
    expect(key!.length, 32);
    expect(
      base64Decode((await storage.read(SecureKeyProvider.hiveBoxKeyName))!),
      key,
    );
  });

  test('unavailable secure storage degrades to the legacy box', () async {
    final failing = _ThrowingStorage();
    final noKeys = SecureKeyProvider(storage: failing);
    final box = await EncryptedHive.openBox<dynamic>(
      Hive,
      'shelf',
      keys: noKeys,
    );
    await box.put('a', {'title': 'Book A'});
    expect((box.get('a') as Map)['title'], 'Book A');
    expect(await Hive.boxExists('shelf'), isTrue);
    expect(await Hive.boxExists('shelf_enc'), isFalse);
  });

  test('requireEncryption fails closed without a key', () async {
    final noKeys = SecureKeyProvider(storage: _ThrowingStorage());
    await expectLater(
      EncryptedHive.openBox<dynamic>(
        Hive,
        'chapter_cache_v1',
        keys: noKeys,
        requireEncryption: true,
      ),
      throwsStateError,
    );
  });

  test('no key with an existing encrypted box fails closed', () async {
    // An earlier session encrypted this box, so the records are still on disk.
    final box = await EncryptedHive.openBox<dynamic>(Hive, 'shelf', keys: keys);
    await box.put('a', {'title': 'Book A'});
    await box.close();

    // Next launch, secure storage is unavailable. Degrading to the legacy
    // plaintext box would show an empty shelf, hide the real records and start
    // writing plaintext beside them, so opening must fail instead.
    final noKeys = SecureKeyProvider(storage: _ThrowingStorage());
    await expectLater(
      EncryptedHive.openBox<dynamic>(Hive, 'shelf', keys: noKeys),
      throwsStateError,
    );
    expect(await Hive.boxExists('shelf_enc'), isTrue, reason: '真数据必须还在');
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
