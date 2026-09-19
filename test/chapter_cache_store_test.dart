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
    'a catalogue saved before its first chapter survives other evictions',
    () async {
      final store = ChapterCacheStore(maxEntries: 2);
      // The download sheet saves the catalogues before any chapter lands.
      await store.saveBook(_book('a'));
      await store.saveBook(_book('x'));
      await _write(store, 'x', '1', '正文一');
      await _write(store, 'x', '2', '正文二');
      // Another book's write evicts a chapter while 'x' still has text cached.
      await _write(store, 'x', '3', '正文三');
      final box = Hive.box('chapter_cache_v1');
      // A catalogue survives while any of its chapters is still cached.
      expect(box.containsKey('book:x'), isTrue);
      // The interrupted download of 'a' resumes and fills its chapters.
      await _write(store, 'a', '1', '正文一');
      expect(box.containsKey('book:x'), isTrue);
      expect(
        (await store.books()).map((entry) => entry.book.id),
        contains('a'),
      );
      // A detached catalogue is kept while it is young and within the
      // detached cap; only the TTL sweep or the cap collects it (both are
      // covered by review_fix_b02_test.dart). 'a' keeps growing and stays
      // listed, while x has no chapters left to be listed.
      await _write(store, 'a', '2', '正文二');
      await _write(store, 'a', '3', '正文三');
      expect(box.containsKey('book:x'), isTrue);
      expect(box.containsKey('book:a'), isTrue);
      expect((await store.books()).map((entry) => entry.book.id), ['a']);
    },
  );

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

  test(
    'damaged metadata cannot block cache reads or defeat capacity limits',
    () async {
      final store = ChapterCacheStore(maxBytes: 8);
      await store.saveBook(_book('a'));
      final box = Hive.box('chapter_cache_v1');
      await box.put('chapter:["a","same"]', {
        'bookId': 'a',
        'chapterId': 'same',
        'text': 'abcdef',
        'bytes': 1,
        'accessedAt': 'invalid',
        42: 'invalid map key',
      });
      expect((await store.stats()).byteCount, 6);
      expect((await store.books()).single.stats.byteCount, 6);
      expect(await store.read(bookId: 'a', chapterId: 'same'), 'abcdef');
      await _write(store, 'a', 'new', 'xyz');
      expect(await store.cachedChapterIds('a'), {'new'});
      expect((await store.stats()).byteCount, 3);
    },
  );

  test(
    'clearing a book removes damaged chapter records without touching others',
    () async {
      final store = ChapterCacheStore();
      await store.saveBook(_book('a'));
      await store.saveBook(_book('ab'));
      await _write(store, 'ab', 'same', 'Unrelated content');
      final box = Hive.box('chapter_cache_v1');
      await box.put('chapter:["a","same"]', {'text': 42});
      await box.put('chapter:["a","truncated"]', 'truncated data');
      await store.clear(bookId: 'a');
      expect(box.containsKey('chapter:["a","same"]'), isFalse);
      expect(box.containsKey('chapter:["a","truncated"]'), isFalse);
      expect(
        await store.read(bookId: 'ab', chapterId: 'same'),
        'Unrelated content',
      );
    },
  );

  test(
    'an access-time write failure does not hide readable offline text',
    () async {
      final store = ChapterCacheStore(hive: _ReadOnlyHive());
      expect(
        await store.read(bookId: 'a', chapterId: 'same'),
        'Readable content',
      );
    },
  );

  test(
    'an unpinned batch larger than the cap evicts its own opening chapters',
    () async {
      // Why a download has to be pinned: under the automatic budget, an uncapped
      // "download everything" deletes the chapters the reader is standing on and
      // leaves only the tail of the catalogue.
      final store = ChapterCacheStore(maxEntries: 3);
      for (var index = 1; index <= 6; index++) {
        await _write(store, 'a', '$index', '正文$index');
      }
      expect(await store.cachedChapterIds('a'), {'4', '5', '6'});
    },
  );

  test('a pinned download runs past the cap intact', () async {
    final store = ChapterCacheStore(maxEntries: 3);
    for (var index = 1; index <= 6; index++) {
      await _write(store, 'a', '$index', '正文$index', pinned: true);
    }
    expect(await store.cachedChapterIds('a'), {'1', '2', '3', '4', '5', '6'});
  });

  test('pinned downloads do not spend the automatic budget', () async {
    final store = ChapterCacheStore(maxEntries: 2);
    for (final id in ['p1', 'p2', 'p3']) {
      await _write(store, 'a', id, '下载$id', pinned: true);
    }
    for (final id in ['r1', 'r2', 'r3']) {
      await _write(store, 'b', id, '自动$id');
    }
    expect(await store.cachedChapterIds('a'), {'p1', 'p2', 'p3'});
    expect(await store.cachedChapterIds('b'), {'r2', 'r3'});
  });
}

class _ReadOnlyHive extends Fake implements HiveInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #openBox) {
      return Future<Box<dynamic>>.value(_ReadOnlyBox());
    }
    return super.noSuchMethod(invocation);
  }
}

class _ReadOnlyBox extends Fake implements Box<dynamic> {
  @override
  bool get isOpen => true;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) => {
    'bookId': 'a',
    'chapterId': 'same',
    'text': 'Readable content',
    'accessedAt': 0,
  };

  @override
  Future<void> put(dynamic key, dynamic value) async =>
      throw StateError('Disk is read-only');
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
  String text, {
  bool pinned = false,
}) => store.write(
  bookId: book,
  chapterId: chapter,
  title: chapter,
  text: text,
  pinned: pinned,
);
