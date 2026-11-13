import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

void main() {
  testWidgets(
    'cross chapter search stays on exact hit after late bubbles repaginate',
    (tester) async {
      setSingleChapterPrefs({
        'reader_page_mode': 'paged',
        'reader_show_paragraph_bubbles': true,
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      final style = AppThemeStyleStore();
      await style.select(AppThemeStyle.classic);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        style.dispose();
      });
      const query = '还有7小时08分24秒';
      final lateIdeas = Completer<ChapterIdeas>();
      final chapterText = Completer<String>();
      await tester.pumpWidget(
        AppUiHost(
          store: style,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: ReaderPage(
                bookId: 'search-late-ideas-regression',
                title: '搜索定位回归',
                chapters: [
                  Chapter(itemId: 'a', title: '第一章', volumeName: ''),
                  Chapter(itemId: 'b', title: '第二章', volumeName: ''),
                ],
                startIndex: 0,
                chapterLoader: (chapter) async =>
                    chapter.itemId == 'b' ? chapterText.future : '开篇正文。',
                chapterCache: MemoryChapterCache(),
                readerStore: MemoryReaderStore(),
                readerDevice: _Device(),
                ideasLoader: (id) => id == 'b'
                    ? lateIdeas.future
                    : Future.value(ChapterIdeas.empty),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final spec = tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .layout
          .spec;
      String? wrappingParagraph;
      for (var length = 8; length < 100; length++) {
        final text = List.filled(length, '山').join();
        final content = ChapterContent(
          blocks: [ChapterParagraph(text, paraIndex: 0)],
        );
        final plain = ReaderChapterLayout(
          title: '第二章',
          content: content,
          spec: spec,
        );
        final decorated = ReaderChapterLayout(
          title: '第二章',
          content: content,
          spec: spec,
          paragraphBubbles: const {0: 12345},
          bubbleBuilder: (_, _, _) => const SizedBox(width: 30, height: 20),
        );
        if (decorated.blocks.last.height > plain.blocks.last.height) {
          wrappingParagraph = text;
          break;
        }
      }
      expect(wrappingParagraph, isNotNull);
      final source = ChapterContent(
        paragraphIdsChecked: true,
        illustrationsChecked: true,
        timelineChecked: true,
        blocks: [
          for (var i = 0; i < 50; i++)
            ChapterParagraph(
              i == 27 ? '$query，系统正在倒数。' : wrappingParagraph!,
              paraIndex: i,
            ),
        ],
      );
      chapterText.complete(source.toCacheText());
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester
            .getRect(find.byKey(const ValueKey('reader-page-surface')))
            .center,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('classic-reader-full-search')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-full-search-field')),
        query,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('reader-full-search-result-1-0')),
      );
      await tester.pumpAndSettle();

      ReaderPagedView pager() =>
          tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
      ReaderPagedViewState state() =>
          tester.state<ReaderPagedViewState>(find.byType(ReaderPagedView));
      final initial = pager();
      final hit = initial.layout.blocks.singleWhere(
        (b) => b.text.contains(query),
      );
      final start = hit.start + hit.text.indexOf(query);
      final initialPage = initial.layout.pageForOffset(start);
      expect(state().currentPage, initialPage);
      expect(initial.selection?.start, start);

      lateIdeas.complete(
        ChapterIdeas(
          paragraphs: [
            for (var i = 0; i < 50; i++)
              ParagraphIdeas(paraIndex: i, count: 12345),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final finalPager = pager();
      final targetPage = finalPager.layout.pageForOffset(start);
      expect(finalPager.layout, isNot(same(initial.layout)));
      expect(
        finalPager.layout.blocks[1].height,
        greaterThan(initial.layout.blocks[1].height),
        reason:
            'text=${finalPager.layout.blocks[1].text}, bubble=${finalPager.layout.blocks[1].bubbleCount}, id=${finalPager.layout.blocks[1].paraIndex}, spec=${finalPager.layout.spec.width}/${spec.width}',
      );
      expect(
        targetPage,
        greaterThan(initialPage),
        reason: 'Late bubbles must move the hit to a later page.',
      );
      expect(
        state().currentPage,
        targetPage,
        reason: 'Keep the selected hit, not the old page start.',
      );
      expect(finalPager.pageIndex, targetPage);
      expect(finalPager.selection?.start, start);
      await tester.pump(const Duration(seconds: 4));
      expect(
        state().currentPage,
        targetPage,
        reason: 'The exact anchor outlives its temporary highlight.',
      );
      unawaited(state().turnPage(1));
      await tester.pumpAndSettle();
      expect(
        state().currentPage,
        targetPage + 1,
        reason: 'A user turn still takes over navigation.',
      );
      expect(pager().selection, isNull);
      expect(tester.takeException(), isNull);
    },
  );
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
