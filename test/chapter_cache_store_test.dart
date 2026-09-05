import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'fqapp-chapter-cache-test-',
    );
    Hive.init(directory.path);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'catalog and text survive reopening, including colliding chapter IDs',
    () async {
      final store = ChapterCacheStore();
      await store.saveBook(_book('a'));
      await store.saveBook(_book('b'));
      await _write(store, 'a', 'same', '第一本正文');
      await _write(store, 'b', 'same', '第二本正文');
      await Hive.close();

      final reopened = ChapterCacheStore();
      expect(await reopened.read(bookId: 'a', chapterId: 'same'), '第一本正文');
      expect(await reopened.read(bookId: 'b', chapterId: 'same'), '第二本正文');
      final books = await reopened.books();
      expect(books.map((entry) => entry.book.id), containsAll(['a', 'b']));
      expect(books.first.book.chapters.single.title, '第一章');
      expect((await reopened.stats()).chapterCount, 2);
    },
  );

  test('evicts least recently read text and enforces the byte limit', () async {
    final store = ChapterCacheStore(maxEntries: 2, maxBytes: 12);
    await _write(store, 'a', '1', 'aaaa');
    await _write(store, 'a', '2', 'bbbb');
    await store.read(bookId: 'a', chapterId: '1');
    await _write(store, 'a', '3', 'cccc');
    expect(await store.cachedChapterIds('a'), {'1', '3'});
    await _write(store, 'a', '4', 'dddddddddd');
    expect(await store.cachedChapterIds('a'), {'4'});
    expect((await store.stats()).byteCount, 10);
    await expectLater(_write(store, 'a', '5', 'x' * 13), throwsStateError);
    await _write(store, 'a', '6', 'e');
    expect(await store.cachedChapterIds('a'), {'4', '6'});
  });

  test(
    'clear is ordered after pending writes and preserves reading history',
    () async {
      final store = ChapterCacheStore();
      final history = await Hive.openBox('history');
      await history.put('a', {'position': 35});
      final operations = [
        store.saveBook(_book('a')),
        _write(store, 'a', 'same', '正文'),
        store.clear(bookId: 'a'),
      ];
      await Future.wait(operations);
      expect((await store.stats()).chapterCount, 0);
      expect(await store.books(), isEmpty);
      expect(history.get('a')['position'], 35);
      await _write(store, 'b', 'same', '正文二');
      await store.clear();
      expect((await store.stats()).byteCount, 0);
      expect(history.get('a')['position'], 35);
    },
  );
}

CachedBook _book(String id) => CachedBook(
  id: id,
  title: '书籍$id',
  chapters: [Chapter(itemId: 'same', title: '第一章', volumeName: '正文')],
);

Future<void> _write(
  ChapterCacheStore store,
  String book,
  String chapter,
  String text,
) => store.write(bookId: book, chapterId: chapter, title: chapter, text: text);
