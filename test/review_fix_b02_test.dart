import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fqapp-b02-test-');
    Hive.init(directory.path);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'a catalogue evicted mid-batch no longer hides the surviving chapters',
    () async {
      final store = ChapterCacheStore(maxEntries: 1);
      await store.saveBook(_book('y'));
      await _write(store, 'y', '1', 'y-one');
      // Writing x historically evicted y/1 and then deleted book:y, so the
      // later y/2 write landed with no catalogue to discover it.
      await _write(store, 'x', '1', 'x-one');
      await _write(store, 'y', '2', 'y-two');

      expect(await store.cachedChapterIds('y'), {'2'});
      final books = await store.books();
      expect(
        books.where((entry) => entry.book.id == 'y').single.stats.chapterCount,
        1,
      );
      expect(Hive.box('chapter_cache_v1').containsKey('book:y'), isTrue);
    },
  );

  test('a missing catalogue is rebuilt from the surviving chapters', () async {
    final store = ChapterCacheStore();
    // Reproduces the stored state left behind by the old orphan bug.
    await _write(store, 'orphan', '1', 'orphan text');
    final book = (await store.books()).single.book;
    expect(book.id, 'orphan');
    expect(book.chapters.single.itemId, '1');
  });

  test(
    'catalogue-only records are bounded even without any chapters',
    () async {
      final store = ChapterCacheStore(maxEntries: 1);
      await store.saveBook(_book('a'));
      await store.saveBook(_book('b'));
      final box = Hive.box('chapter_cache_v1');
      expect(box.containsKey('book:a'), isFalse);
      expect(box.containsKey('book:b'), isTrue);
    },
  );

  test('stale catalogue-only records are aged out', () async {
    final store = ChapterCacheStore();
    await store.books();
    final box = Hive.box('chapter_cache_v1');
    await box.put('book:stale', {
      'id': 'stale',
      'title': '旧书',
      'cover': '',
      'chapters': [
        {'itemId': '1', 'title': '第一章'},
      ],
      'cachedAt': 0,
    });
    await store.saveBook(_book('fresh'));
    expect(box.containsKey('book:stale'), isFalse);
    expect(box.containsKey('book:fresh'), isTrue);
  });

  test('a catalogue-only download still survives other evictions', () async {
    final store = ChapterCacheStore(maxEntries: 2);
    await store.saveBook(_book('a'));
    await _write(store, 'x', '1', 'x-one');
    await _write(store, 'x', '2', 'x-two');
    await _write(store, 'x', '3', 'x-three');
    expect(Hive.box('chapter_cache_v1').containsKey('book:a'), isTrue);
  });
}

CachedBook _book(String id) => CachedBook(
  id: id,
  title: '书籍$id',
  chapters: [Chapter(itemId: '1', title: '第一章', volumeName: '正文')],
);

Future<void> _write(
  ChapterCacheStore store,
  String book,
  String chapter,
  String text,
) => store.write(bookId: book, chapterId: chapter, title: chapter, text: text);
