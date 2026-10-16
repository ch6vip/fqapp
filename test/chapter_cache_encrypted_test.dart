import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// P1-5: decrypted chapter text lives in the encrypted box only, and
/// offline reading still works from that box.
void main() {
  late Directory dir;
  late SecureKeyProvider keys;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fqapp-chapter-enc-');
    Hive.init(dir.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('chapter text is ciphertext on disk and readable offline', () async {
    const text = 'PLAINTEXT-CHAPTER-BODY-9d2e4a';
    final store = ChapterCacheStore(keys: keys);
    await store.write(
      bookId: 'book1',
      chapterId: 'c1',
      title: '第一章',
      text: text,
    );
    await Hive.close();

    for (final file in dir.listSync().whereType<File>()) {
      expect(
        String.fromCharCodes(file.readAsBytesSync()).contains(text),
        isFalse,
        reason: 'chapter plaintext leaked in ${file.path}',
      );
    }

    // Offline read: same store, same key, no network involved.
    final reopened = ChapterCacheStore(keys: keys);
    expect(
      await reopened.read(bookId: 'book1', chapterId: 'c1'),
      text,
    );
    expect(await reopened.cachedChapterIds('book1'), {'c1'});
  });

  test('legacy plaintext chapter box migrates into the encrypted box', () async {
    final legacy = await Hive.openBox<dynamic>('chapter_cache_v1');
    await legacy.put('chapter:["book1","c1"]', {
      'bookId': 'book1',
      'chapterId': 'c1',
      'title': '第一章',
      'text': 'MIGRATED-BODY',
      'bytes': 13,
      'accessedAt': 0,
    });
    await legacy.close();

    final store = ChapterCacheStore(keys: keys);
    expect(await store.read(bookId: 'book1', chapterId: 'c1'), 'MIGRATED-BODY');
    expect(await Hive.boxExists('chapter_cache_v1'), isFalse);
  });

  test('no key means fail closed, never a plaintext chapter box', () async {
    final noKeys = SecureKeyProvider(storage: _ThrowingStorage());
    final store = ChapterCacheStore(keys: noKeys);
    await expectLater(
      store.read(bookId: 'book1', chapterId: 'c1'),
      throwsStateError,
    );
    expect(await Hive.boxExists('chapter_cache_v1'), isFalse);
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
