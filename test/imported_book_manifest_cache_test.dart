import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/imported_book_store.dart';

/// Reading a chapter of an imported book must not re-parse the book manifest:
/// the catalogue is immutable after import, so the store keeps it per book.
void main() {
  late Directory directory;
  late ImportedBookStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fqapp-import-cache-');
    store = ImportedBookStore(rootDirectoryProvider: () async => directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<ImportedBook> importText() => store.importBytes(
    fileName: '缓存.txt',
    bytes: Uint8List.fromList(utf8.encode('第一章\n正文一\n第二章\n正文二')),
  );

  test('chapter text reuses the manifest parsed by the first read', () async {
    final imported = await importText();
    final first = imported.chapters.first;
    expect(await store.chapterText(imported.id, first.itemId), contains('正文一'));

    // The manifest is unreadable from now on; the cached one still resolves
    // the chapter file, so a per-chapter reader is not blocked mid-book.
    await File(
      '${imported.directory}${Platform.pathSeparator}book.json',
    ).writeAsString('{broken', encoding: utf8);
    expect(await store.chapterText(imported.id, first.itemId), contains('正文一'));
  });

  test('deleting the book invalidates its cached manifest', () async {
    final imported = await importText();
    final first = imported.chapters.first;
    expect(await store.chapterText(imported.id, first.itemId), contains('正文一'));

    expect(await store.deleteBook(imported.id), isTrue);
    await expectLater(
      store.chapterText(imported.id, first.itemId),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          'message',
          contains('找不到本地书籍'),
        ),
      ),
    );
  });

  test(
    'bounds the cache at eight books, evicting the least recently read',
    () async {
      final books = <ImportedBook>[];
      for (var index = 0; index < 9; index++) {
        books.add(
          await store.importBytes(
            fileName: '书$index.txt',
            bytes: Uint8List.fromList(utf8.encode('第一章\n第$index本正文')),
          ),
        );
      }
      for (final book in books) {
        expect(
          await store.chapterText(book.id, book.chapters.single.itemId),
          contains('正文'),
        );
      }

      // 第一本最久未被读取，第九本入缓存时把它挤了出去：损坏第一本的清单后
      // 再读它必须重新解析（失败），而刚读过的最后一本仍走缓存。
      await File(
        '${books.first.directory}${Platform.pathSeparator}book.json',
      ).writeAsString('{broken', encoding: utf8);
      await expectLater(
        store.chapterText(books.first.id, books.first.chapters.single.itemId),
        throwsA(isA<FileSystemException>()),
      );
      await File(
        '${books.last.directory}${Platform.pathSeparator}book.json',
      ).writeAsString('{broken', encoding: utf8);
      expect(
        await store.chapterText(
          books.last.id,
          books.last.chapters.single.itemId,
        ),
        contains('正文'),
      );
    },
  );

  test('the cache is LRU-bounded and removing a book drops its entry', () {
    final cache = ImportedManifestCache<String>(capacity: 2);
    cache['a'] = 'A';
    cache['b'] = 'B';
    // Touching a makes b the least recently used entry.
    expect(cache['a'], 'A');
    cache['c'] = 'C';
    expect(cache.length, 2);
    expect(cache['a'], 'A');
    expect(cache['b'], isNull);
    expect(cache['c'], 'C');

    cache.remove('a');
    expect(cache['a'], isNull);
    expect(cache.length, 1);
  });

  test('the manifest cache holds at most eight books by default', () {
    expect(ImportedManifestCache<String>().capacity, 8);
  });
}
