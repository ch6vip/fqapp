import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';

import 'support/fakes.dart';

void main() {
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

final _cachedBook = CachedBook(
  id: 'book',
  title: '缓存测试',
  chapters: [
    Chapter(itemId: '1', title: '第一章', volumeName: ''),
    Chapter(itemId: '2', title: '第二章', volumeName: ''),
  ],
);
