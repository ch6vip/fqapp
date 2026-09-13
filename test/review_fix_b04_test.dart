import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_summary.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'refreshing clears stale excerpts while the preview loader is pending',
    (tester) async {
      var calls = 0;
      final second = Completer<ChapterSummary>();
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: _book,
            detailLoader: (id, {String tab = '小说'}) async => {},
            directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
            previewLoader: (ids) {
              calls++;
              if (calls == 1) {
                return Future.value(
                  const ChapterSummary(byItemId: {'first': '摘要一'}),
                );
              }
              return second.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('摘要一'), findsOneWidget);

      await tester.tap(find.byKey(const Key('detail_refresh_button')));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('摘要一'), findsNothing);

      second.complete(const ChapterSummary(byItemId: {'first': '摘要二'}));
      await tester.pumpAndSettle();
      expect(find.text('摘要二'), findsOneWidget);
      expect(find.text('摘要一'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a failing preview loader degrades to no excerpts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
          previewLoader: (ids) async => throw StateError('preview unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.byKey(const Key('detail_preview_excerpt_first')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an opened cache sheet saves no catalogue until a download starts',
    (tester) async {
      final cache = MemoryChapterCache();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChapterCacheSheet(
              book: _cachedBook,
              currentIndex: 0,
              cache: cache,
              loader: (_) async => '正文',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(cache.catalogs, isEmpty);

      await tester.tap(find.text('缓存后 1 章'));
      await tester.pumpAndSettle();
      expect(cache.catalogs['book'], isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a plain-text loader is stored image-incomplete, not image-complete',
    (tester) async {
      final cache = MemoryChapterCache();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChapterCacheSheet(
              book: _cachedBook,
              currentIndex: 0,
              cache: cache,
              loader: (_) async => '纯文字正文',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 1 章'));
      await tester.pumpAndSettle();

      final stored = ChapterContent.fromCacheText(cache.content['book']!['2']!);
      expect(stored.illustrationsChecked, isFalse);
      expect(stored.needsImageRefresh(), isTrue);
      expect(find.textContaining('插图未更新'), findsOneWidget);
      expect(find.textContaining('缓存完成'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

final _book = MediaItem(
  id: 'book',
  title: '测试书',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);

final _chapters = <Chapter>[
  Chapter(itemId: 'first', title: '第一章', volumeName: ''),
  Chapter(itemId: 'second', title: '第二章', volumeName: ''),
];

final _cachedBook = CachedBook(
  id: 'book',
  title: '缓存测试',
  chapters: [
    Chapter(itemId: '1', title: '第一章', volumeName: ''),
    Chapter(itemId: '2', title: '第二章', volumeName: ''),
  ],
);
