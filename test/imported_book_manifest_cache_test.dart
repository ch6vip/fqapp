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
}
