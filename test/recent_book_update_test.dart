import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_book_reader.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/book_updates.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

import 'support/fakes.dart';

final _chapters = [
  Chapter(itemId: '1', title: '第一章', volumeName: ''),
  Chapter(itemId: '2', title: '第二章', volumeName: ''),
  Chapter(itemId: '3', title: '第三章', volumeName: ''),
];
final _book = MediaItem(
  id: 'updated-book',
  title: '连载测试',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);

void main() {
  setUp(
    () =>
        SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'}),
  );

  for (final mode in ['scroll', 'slide', 'curl']) {
    testWidgets('$mode 缓存立即续读，慢目录到达后可进入新增章节', (tester) async {
      SharedPreferences.setMockInitialValues({'reader_page_mode': mode});
      final pending = Completer<List<Chapter>>();
      final cache = await _cache();
      final history = _history();
      await _open(tester, cache, history, (_) => pending.future);
      expect(_reader(tester).chapters, hasLength(2));
      expect(find.textContaining('第二章的正文'), findsWidgets);
      pending.complete(_chapters);
      await tester.pumpAndSettle();
      expect(_reader(tester).chapters.map((c) => c.itemId), ['1', '2', '3']);
      expect((await cache.savedCatalogue(_book.id))!.chapters, hasLength(3));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      expect(find.text('目录 · 3 章'), findsOneWidget);
      await tester.tap(find.text('第三章'));
      await tester.pumpAndSettle();
      expect(find.textContaining('第三章的正文'), findsWidgets);
    });
  }

  for (final result in ['失败', '空目录']) {
    testWidgets('目录$result 保留缓存并可在返回前台后重试', (tester) async {
      final pending = Completer<List<Chapter>>();
      var attempt = 0;
      await _open(tester, await _cache(), _history(), (_) {
        attempt++;
        return attempt == 1 ? pending.future : Future.value(_chapters);
      });
      if (result == '失败') {
        pending.completeError(StateError('offline'));
      } else {
        pending.complete([]);
      }
      await tester.pumpAndSettle();
      expect(_reader(tester).chapters, hasLength(2));
      expect(find.textContaining('第二章的正文'), findsWidgets);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(_reader(tester).chapters, hasLength(3));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('退出阅读后才返回的目录不再修改缓存', (tester) async {
    final pending = Completer<List<Chapter>>();
    final cache = await _cache();
    await _open(tester, cache, _history(), (_) => pending.future);
    Navigator.of(tester.element(find.byType(ReaderPage))).pop();
    await tester.pumpAndSettle();
    pending.complete(_chapters);
    await tester.pumpAndSettle();
    expect((await cache.savedCatalogue(_book.id))!.chapters, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}

ReaderPage _reader(WidgetTester tester) =>
    tester.widget<ReaderPage>(find.byType(ReaderPage));

MemoryReaderStore _history() => MemoryReaderStore(
  entry: {
    'id': _book.id,
    'kind': 'book',
    'chapterId': '2',
    'episode': 1,
    'chapterCount': 2,
  },
);

Future<MemoryChapterCache> _cache() async {
  final cache = MemoryChapterCache();
  await cache.saveBook(
    CachedBook(
      id: _book.id,
      title: _book.title,
      chapters: _chapters.take(2).toList(),
    ),
  );
  for (final chapter in _chapters) {
    await cache.write(
      bookId: _book.id,
      chapterId: chapter.itemId,
      title: chapter.title,
      text: '${chapter.title}的正文。' * 100,
    );
  }
  return cache;
}

Future<void> _open(
  WidgetTester tester,
  MemoryChapterCache cache,
  MemoryReaderStore history,
  BookDirectoryLoader loader,
) async {
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => openRecentBook(
            context,
            _book,
            cache: cache,
            readerStore: history,
            directoryLoader: loader,
          ),
          child: const Text('封面续读'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('封面续读'));
  await tester.pumpAndSettle();
}
