import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/reader/reader_toast.dart';
import 'package:fqapp/widgets/reader/reader_full_search_panel.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

void main() {
  testWidgets('search selection waits for ordinary pending next chapter', (
    tester,
  ) async {
    setSingleChapterPrefs({'reader_page_mode': 'paged'});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final style = AppThemeStyleStore();
    await style.select(AppThemeStyle.classic);
    final pending = Completer<String>();
    addTearDown(() async {
      if (!pending.isCompleted) pending.complete('第二章正文。');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      style.dispose();
    });
    const query = '缓存中的命中';
    await tester.pumpWidget(
      AppUiHost(
        store: style,
        home: ReaderPage(
          bookId: 'busy-search-navigation',
          title: '并发换章回归',
          chapters: [
            Chapter(itemId: 'a', title: '第一章', volumeName: ''),
            Chapter(itemId: 'b', title: '第二章', volumeName: ''),
          ],
          startIndex: 0,
          chapterLoader: (chapter) async =>
              chapter.itemId == 'b' ? pending.future : '$query，应该返回此段。',
          chapterCache: MemoryChapterCache(),
          readerStore: MemoryReaderStore(),
          readerDevice: _Device(),
          ideasLoader: (_) async => ChapterIdeas.empty,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-classic-next-chapter')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('classic-reader-full-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-search-field')),
      query,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('reader-full-search-result-0-0')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReaderFullSearchPanel), findsNothing);
    expect(
      find.textContaining(query),
      findsWidgets,
      reason: '等待旧换章时保留离开页正文，不能提前伪造目标页定位',
    );
    expect(find.byType(ReaderPagedView), findsNothing);
    pending.complete('第二章正文。');
    await tester.pumpAndSettle();
    final pager = tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
    expect(pager.layout.blocks.first.text, '第一章');
    expect(pager.selection, isNotNull);
    final block = pager.layout.blocks.singleWhere(
      (b) => b.text.contains(query),
    );
    expect(pager.selection!.start, block.start + block.text.indexOf(query));
    expect(tester.takeException(), isNull);
  });

  testWidgets('search reports a target chapter reload failure after eviction', (
    tester,
  ) async {
    setSingleChapterPrefs({'reader_page_mode': 'paged'});
    final style = AppThemeStyleStore();
    await style.select(AppThemeStyle.classic);
    final cache = MemoryChapterCache();
    var failTarget = false;
    var targetLoads = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      style.dispose();
    });
    await tester.pumpWidget(
      AppUiHost(
        store: style,
        home: ReaderPage(
          bookId: 'search-target-load-error',
          title: '搜索加载失败',
          chapters: [
            for (var i = 0; i < 8; i++)
              Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
          ],
          startIndex: 0,
          chapterLoader: (chapter) async {
            if (chapter.itemId == '2') {
              targetLoads++;
              if (failTarget) throw StateError('target unavailable');
              return 'needle 命中原文';
            }
            return '普通正文 ${chapter.itemId}';
          },
          chapterCache: cache,
          readerStore: MemoryReaderStore(),
          readerDevice: _Device(),
          ideasLoader: (_) async => ChapterIdeas.empty,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('classic-reader-full-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-search-field')),
      'needle',
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }
    final result = find.byKey(const ValueKey('reader-full-search-result-2-0'));
    expect(result, findsOneWidget);
    expect(targetLoads, 1);
    // The eight-chapter scan has evicted chapter 2 from the five-entry LRU.
    // Simulate automatic disk eviction while the search snapshot is still open.
    cache.content['search-target-load-error']!.remove('2');
    failTarget = true;
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderFullSearchPanel), findsNothing);
    expect(targetLoads, 2, reason: '定位必须真正走到失败的目标章节加载');
    expect(
      tester.widget<ReaderToast>(find.byType(ReaderToast)).message,
      '目标章节加载失败，请重试',
    );
    expect(tester.takeException(), isNull);
  });
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(time: DateTime(2026), battery: 64);
  @override
  Future<void> keepScreenOn(bool on) async {}
  @override
  Future<void> setImmersive(
    bool enabled, {
    bool showStatusBar = false,
    bool showNavigationBar = false,
  }) async {}
  @override
  Future<void> close() async {}
}
