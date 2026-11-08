import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';
import 'package:fqapp/widgets/reader/reader_bookmarks_panel.dart';
import 'package:fqapp/widgets/reader/reader_directory_sheet.dart';
import 'package:fqapp/widgets/reader/reader_find_panel.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';
import 'package:fqapp/widgets/reader/reader_paragraph_menu.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/reader/settings/reader_settings_widgets.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

/// Classic reader panels (PR #292 task E) against the one live business layer.
///
/// Every panel keeps its current State/store/algorithm; these tests pin the
/// renderer split (classic Material vs archive Wenku8), the input/scroll
/// survival across a live style switch, the current find/bookmark/volume
/// behaviour, and that archive output is unchanged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // `ApiClient.instance` captures the ambient http client when built.
    http.runWithClient(() => ApiClient.instance, () => MockClient(_api));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetAppUiTestDiagnostics();
  });

  group('目录', () {
    testWidgets(
      'classic restores search/order/status/volume rows and AI/cache',
      (tester) async {
        final store = await _style(AppThemeStyle.classic);
        final launched = await _launch<int>(
          tester,
          store,
          _directory(chapters: _volumes, cachedIds: const {'c1'}),
        );

        expect(find.text('目录 · 3 章'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('reader-catalogue-search-toggle')),
          findsNothing,
        );
        // Classic keeps the search field mounted instead of a toggle.
        expect(
          find.byKey(const ValueKey('reader-chapter-search')),
          findsOneWidget,
        );
        expect(find.text('当前第 1 章'), findsOneWidget);

        // Collapsed volume keeps its chapters out until expanded.
        expect(find.text('晨光'), findsOneWidget);
        expect(find.text('暮色'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('reader-volume-卷二')));
        await tester.pumpAndSettle();
        expect(find.text('暮色'), findsOneWidget);
        // AI status and cache markers are the classic trailing labels.
        expect(find.text('已校验'), findsOneWidget);
        expect(find.text('已缓存'), findsOneWidget);

        // Search penetrates the collapsed volume, including its name.
        await tester.enterText(
          find.byKey(const ValueKey('reader-chapter-search')),
          '卷二',
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();
        expect(find.text('找到 2 章'), findsOneWidget);
        expect(find.text('晨光'), findsNothing);
        expect(find.text('暮色'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('reader-chapter-search')),
          '',
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();

        // Reverse order flips the row projection without changing the indices.
        await tester.tap(find.byKey(const ValueKey('reader-catalogue-order')));
        await tester.pumpAndSettle();
        expect(find.text('倒序'), findsOneWidget);
        final titles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((tile) => (tile.title as Text).data)
            .toList(growable: false);
        expect(titles, ['夜雨', '暮色', '晨光']);

        // A tapped row still returns the real chapter index.
        await tester.tap(find.byKey(const ValueKey('reader-directory-row-2')));
        await tester.pumpAndSettle();
        expect(launched.value, 2);
      },
    );

    testWidgets('archive keeps the count-less header and search toggle', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.archive);
      await _launch<int>(tester, store, _directory(chapters: _volumes));

      expect(find.text('目录'), findsOneWidget);
      expect(find.text('目录 · 3 章'), findsNothing);
      expect(
        find.byKey(const ValueKey('reader-catalogue-search-toggle')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-chapter-search')), findsNothing);
      // Archive rows are the current ListTiles with a trailing column.
      expect(find.text('晨光'), findsOneWidget);
    });

    for (final scale in const [1.5, 2.0]) {
      testWidgets('directory AI/cache markers fit 320dp at ${scale}x', (
        tester,
      ) async {
        final store = await _style(AppThemeStyle.classic);
        final launched = await _launch<int>(
          tester,
          store,
          _directory(
            chapters: [
              Chapter(itemId: 'm0', title: '第一章', volumeName: ''),
              Chapter(itemId: 'm1', title: '第二章', volumeName: ''),
              Chapter(itemId: 'm2', title: '第三章', volumeName: ''),
            ],
            cachedIds: const {'m0', 'm2'},
            aiStatuses: [
              _aiStatus('m0', AiChapterCheckState.checked),
              _aiStatus('m1', AiChapterCheckState.failed),
            ],
          ),
          size: const Size(320, 700),
          textScale: scale,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // m0 carries both markers at once; m1 AI only; m2 cache only.
        expect(find.text('已校验'), findsOneWidget);
        expect(find.text('失败'), findsOneWidget);
        // m0 shows both markers, m2 shows cache only.
        expect(find.text('已缓存'), findsNWidgets(2));

        await tester.ensureVisible(
          find.byKey(const ValueKey('reader-directory-row-2')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-directory-row-2')));
        await tester.pumpAndSettle();
        expect(launched.value, 2);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('open directory keeps query and scroll across styles', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.archive);
      await _launch<int>(tester, store, _directory(chapters: _manyChapters));
      await tester.tap(
        find.byKey(const ValueKey('reader-catalogue-search-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-chapter-search')),
        '同名 4',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.byType(ListTile), findsNWidgets(10));

      // Clear, then scroll the unfiltered list and switch styles.
      await tester.enterText(
        find.byKey(const ValueKey('reader-chapter-search')),
        '',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('reader-directory-scroll')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      final before = _firstVisibleDirectoryRow(tester);
      expect(before, isNotNull);
      expect(before!.$1, greaterThan(0));

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.text('目录 · 60 章'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-chapter-search')),
        findsOneWidget,
      );
      final after = _firstVisibleDirectoryRow(tester);
      expect(after, isNotNull);
      expect(after!.$1, before.$1, reason: '切风格后首个可见章节必须不变');
      // The classic row wraps its ListTile in 2dp padding and uses a taller
      // list padding; the chapter and its scroll position are what anchor.
      expect(after.$2, closeTo(before.$2, 8));

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      // The query controller is the same State; the archive field is still open.
      expect(
        find.byKey(const ValueKey('reader-chapter-search')),
        findsOneWidget,
      );
      final back = _firstVisibleDirectoryRow(tester);
      expect(back!.$1, before.$1);
      expect(back.$2, closeTo(before.$2, 8));
      expect(tester.takeException(), isNull);
    });
  });

  group('章内查找', () {
    testWidgets(
      'classic result list keeps UTF-16 offsets and returns a match',
      (tester) async {
        final store = await _style(AppThemeStyle.classic);
        final launched = await _launch<ReaderFindMatch>(
          tester,
          store,
          const ReaderFindPanel(
            paragraphs: [ReaderFindParagraph(start: 40, text: '😀 中文内容中文')],
            preset: ReaderThemePreset.light,
          ),
          size: const Size(390, 844),
        );

        expect(find.byType(ReaderSettingsSheetFrame), findsOneWidget);
        expect(find.text('章内查找'), findsOneWidget);
        final field = find.byKey(const ValueKey('reader-find-field'));
        expect(tester.widget<TextField>(field).autofocus, isTrue);

        await tester.enterText(field, '中文');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect(find.text('2 处匹配'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('reader-find-result-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-find-results')),
          findsOneWidget,
        );

        // Tap the second hit: display offsets stay exact (surrogate pairs count
        // two UTF-16 units, exactly like the reader engine's mapping).
        await tester.tap(find.byKey(const ValueKey('reader-find-result-1')));
        await tester.pumpAndSettle();
        final match = launched.value!;
        expect((match.start, match.end), (47, 49));
      },
    );

    testWidgets('archive keeps its own header and scroll view', (tester) async {
      final store = await _style(AppThemeStyle.archive);
      await _launch<ReaderFindMatch>(
        tester,
        store,
        const ReaderFindPanel(
          paragraphs: [ReaderFindParagraph(start: 0, text: '中文内容')],
          preset: ReaderThemePreset.light,
        ),
      );
      expect(find.byType(ReaderSettingsSheetFrame), findsNothing);
      expect(find.byKey(const ValueKey('reader-find-scroll')), findsOneWidget);
      expect(find.text('章内查找'), findsOneWidget);
    });

    testWidgets('classic find lands on the exact hit inside replaced text', (
      tester,
    ) async {
      // Same fixture as the archive replacement regression: the display text
      // is much longer than the source marker, so a source/display round trip
      // would land on the wrong page. The classic renderer must only change
      // the shell.
      setSingleChapterPrefs({'reader_page_mode': 'paged'});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const bookId = 'classic:find-replacement';
      const marker = '短标';
      const target = '唯一末端命中';
      final expanded =
          '${List.filled(100, '山风吹过窗台，书页在阳光下缓缓翻开。').join()}'
          '$target，故事仍在继续。';
      final replacements = TextReplacementStore();
      final engine = TextReplacementEngine();
      final cache = MemoryChapterCache();
      final marks = _PanelStore([]);
      addTearDown(marks.changes.dispose);
      await replacements.save(
        enabled: true,
        rules: [
          TextReplacementRule(
            id: 'expand',
            pattern: marker,
            replacement: expanded,
          ),
        ],
      );
      final source = ChapterContent.fromPlainText(
        marker,
        illustrationsChecked: true,
      );
      await cache.write(
        bookId: bookId,
        chapterId: 'a',
        title: '甲章',
        text: source.toCacheText(),
      );
      final transformed = await tester.runAsync(
        () => engine.transform(
          source: source,
          chapterTitle: '甲章',
          snapshot: replacements.snapshot,
        ),
      );
      expect(transformed, isNotNull);
      final store = await _style(AppThemeStyle.classic);
      await tester.pumpWidget(
        AppUiHost(
          store: store,
          home: ReaderPage(
            bookId: bookId,
            title: '查找替换回归',
            chapters: [Chapter(itemId: 'a', title: '甲章', volumeName: '')],
            startIndex: 0,
            localOnly: true,
            chapterLoader: (_) async => source.toCacheText(),
            readerStore: MemoryReaderStore(),
            readerDevice: _Device(),
            chapterCache: cache,
            replacementStore: replacements,
            replacementEngine: engine,
            bookmarkStore: marks,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final layout = tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .layout;
      final body = layout.blocks.where((b) => !b.isTitle && !b.isImage).single;
      expect(body.text, expanded);
      final matchStart = body.start + body.text.indexOf(target);
      final expectedPage = layout.pageForOffset(matchStart);

      await _openControls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-find-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsSheetFrame), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        target,
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('reader-find-result-0')));
      await tester.pumpAndSettle();
      final landed = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      expect(landed.pageIndex, expectedPage);
      expect(landed.selection?.start, matchStart);
      expect(landed.selection?.end, matchStart + target.length);
      expect(tester.takeException(), isNull);
    });

    testWidgets('find keeps the top visible match across styles', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final text = List.generate(
        40,
        (index) =>
            '第 $index 段 山中 有风，'
            '${'继续阅读的内容' * (index % 3 + 1)}',
      ).join();
      await _launch<ReaderFindMatch>(
        tester,
        store,
        ReaderFindPanel(
          paragraphs: [ReaderFindParagraph(start: 0, text: text)],
          preset: ReaderThemePreset.light,
        ),
        size: const Size(390, 600),
      );
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '山中',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('40 处匹配'), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('reader-find-results')),
        const Offset(0, -260),
      );
      await tester.pumpAndSettle();
      final before = _firstVisibleFindResult(tester, 40);
      expect(before, isNotNull);
      expect(before!.$1, greaterThan(0), reason: '标题区已滚出视口');

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      final after = _firstVisibleFindResult(tester, 40);
      expect(after, isNotNull);
      expect(after!.$1, before.$1, reason: '切风格后顶部匹配必须不变');
      expect(after.$2, closeTo(before.$2, 2));

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      final back = _firstVisibleFindResult(tester, 40);
      expect(back!.$1, before.$1);
      expect(back.$2, closeTo(before.$2, 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('classic re-runs the query when the body updates', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final paragraphs = ValueNotifier<List<ReaderFindParagraph>>([
        const ReaderFindParagraph(start: 0, text: '原文 山中 内容'),
      ]);
      addTearDown(paragraphs.dispose);
      await _launch<ReaderFindMatch>(
        tester,
        store,
        ValueListenableBuilder<List<ReaderFindParagraph>>(
          valueListenable: paragraphs,
          builder: (_, value, _) => ReaderFindPanel(
            // A new list identity is what the page hands over after AI or a
            // text replacement rewrote the body.
            paragraphs: value,
            preset: ReaderThemePreset.light,
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '山中',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('1 处匹配'), findsOneWidget);

      paragraphs.value = const [
        ReaderFindParagraph(start: 0, text: '更新后的正文 山中 又一处 山中'),
      ];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('2 处匹配'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-find-result-1')));
      await tester.pumpAndSettle();
      expect((tester.takeException()), isNull);
      expect(find.text('3 处匹配'), findsNothing);
    });

    testWidgets('deep find results keep the top match both ways', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final paragraphs = <ReaderFindParagraph>[];
      var start = 0;
      for (var i = 0; i < 200; i++) {
        final text = '第 $i 段 山中 ${'背景文字' * (i % 4 + 1)}';
        paragraphs.add(ReaderFindParagraph(start: start, text: text));
        start += text.length + 1;
      }
      await _launch<ReaderFindMatch>(
        tester,
        store,
        ReaderFindPanel(
          paragraphs: paragraphs,
          preset: ReaderThemePreset.light,
        ),
        size: const Size(390, 700),
      );
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '山中',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('200 处匹配'), findsOneWidget);

      final results = find.byKey(const ValueKey('reader-find-results'));
      tester
          .state<ScrollableState>(
            find
                .descendant(of: results, matching: find.byType(Scrollable))
                .first,
          )
          .position
          .jumpTo(6000);
      await tester.pumpAndSettle();
      final before = _firstVisibleFindResult(tester, 200);
      expect(before, isNotNull);
      final anchorResult = before!;
      expect(anchorResult.$1, greaterThan(30), reason: '必须落在结果列表深处');

      for (final style in const [
        AppThemeStyle.archive,
        AppThemeStyle.classic,
        AppThemeStyle.archive,
      ]) {
        await store.select(style);
        await tester.pumpAndSettle();
        final after = _firstVisibleFindResult(tester, 200);
        expect(after, isNotNull, reason: '${style.name} 必须仍有可见结果');
        expect(after!.$1, anchorResult.$1, reason: '${style.name} 顶部匹配必须不变');
        expect(
          after.$2,
          closeTo(anchorResult.$2, 2),
          reason: '${style.name} 行内偏移必须保持',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('open find keeps the query when the style changes', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      await _launch<ReaderFindMatch>(
        tester,
        store,
        const ReaderFindPanel(
          paragraphs: [ReaderFindParagraph(start: 0, text: '中文内容')],
          preset: ReaderThemePreset.light,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '中文',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('1 处匹配'), findsOneWidget);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('reader-find-field')))
            .controller!
            .text,
        '中文',
      );
      expect(find.text('1 处匹配'), findsOneWidget);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsSheetFrame), findsOneWidget);
      expect(find.text('1 处匹配'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('书签', () {
    testWidgets('classic rows add/open/delete through the shared store', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final marks = _PanelStore([]);
      addTearDown(marks.changes.dispose);
      await tester.pumpWidget(
        AppUiHost(
          store: store,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push<ReaderBookmark>(
                    MaterialPageRoute(
                      builder: (_) => ReaderBookmarksPanel(
                        bookId: 'book',
                        preset: ReaderThemePreset.light,
                        store: marks,
                        onAdd: () async {
                          final mark = _mark(1);
                          await marks.add(mark);
                          return mark;
                        },
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(ReaderSettingsSheetFrame), findsOneWidget);
      expect(find.text('还没有书签，点右上角保存当前位置'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
      await tester.pumpAndSettle();
      expect(find.text('本书 1 条记录'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-bookmarks-list')),
        findsOneWidget,
      );

      // The shared confirm seam renders the classic centred dialog.
      await tester.tap(
        find.byKey(ValueKey('reader-bookmark-delete-${_mark(1).key}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('archive-confirm')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('reader-bookmark-confirm-delete')),
      );
      await tester.pumpAndSettle();
      expect(marks.records, isEmpty);
      expect(find.text('本书 0 条记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('archive keeps its quote layout and record keys', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.archive);
      final marks = _PanelStore([_mark(1)]);
      addTearDown(marks.changes.dispose);
      await _launch<ReaderBookmark>(
        tester,
        store,
        ReaderBookmarksPanel(
          bookId: 'book',
          preset: ReaderThemePreset.light,
          store: marks,
          onAdd: () async => null,
        ),
      );
      expect(
        find.byKey(const ValueKey('reader-bookmarks-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('bookmark-quote-${_mark(1).key}')),
        findsOneWidget,
      );
    });

    testWidgets('open bookmarks keep the visible record across styles', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      // Short, medium and long excerpts make row heights deliberately uneven.
      final marks = _PanelStore([
        for (var i = 0; i < 14; i++)
          _mark(
            i,
            text: switch (i % 3) {
              0 => '短摘录 $i',
              1 => '中等长度摘录 $i ${'内容' * 6}',
              _ => '很长很长的摘录 $i ${'翻页前的那句话还在耳边。' * 12}',
            },
          ),
      ]);
      addTearDown(marks.changes.dispose);
      await _launch<ReaderBookmark>(
        tester,
        store,
        ReaderBookmarksPanel(
          bookId: 'book',
          preset: ReaderThemePreset.light,
          store: marks,
          onAdd: () async => null,
        ),
        size: const Size(390, 600),
      );

      await tester.drag(
        find.byKey(const ValueKey('reader-bookmarks-list')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      final before = _firstVisibleBookmark(tester, marks.records);
      expect(before, isNotNull);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      final after = _firstVisibleBookmark(tester, marks.records);
      expect(after, isNotNull);
      expect(after!.$1, before!.$1, reason: '切风格后顶部书签必须不变');
      expect(after.$2, closeTo(before.$2, 2));
      // The archive header is a sliver: at this offset it left the viewport.
      expect(find.text('本书 14 条记录'), findsNothing);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-bookmarks-list')),
        findsOneWidget,
      );
      final back = _firstVisibleBookmark(tester, marks.records);
      expect(back!.$1, before.$1);
      expect(back.$2, closeTo(before.$2, 2));
      expect(find.text('本书 14 条记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deep heterogeneous bookmarks keep the record both ways', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      // First 100 rows have no excerpt (short), the last 100 carry a long one:
      // row heights differ wildly, so a proportional guess cannot land on the
      // same record when switching renderers deep in the list.
      final marks = _PanelStore([
        for (var i = 0; i < 200; i++)
          _mark(i, text: i < 100 ? '' : '第 $i 条长摘录 ${'翻页前的那句话还在耳边。' * 16}'),
      ]);
      addTearDown(marks.changes.dispose);
      await _launch<ReaderBookmark>(
        tester,
        store,
        ReaderBookmarksPanel(
          bookId: 'book',
          preset: ReaderThemePreset.light,
          store: marks,
          onAdd: () async => null,
        ),
        size: const Size(390, 700),
      );

      final list = find.byKey(const ValueKey('reader-bookmarks-list'));
      for (var i = 0; i < 10; i++) {
        await tester.drag(list, const Offset(0, -820));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final before = _firstVisibleBookmark(tester, marks.records);
      expect(before, isNotNull);
      final anchorRecord = before!;
      final targetIndex = marks.records.indexWhere(
        (record) => record.key == anchorRecord.$1,
      );
      expect(targetIndex, greaterThanOrEqualTo(100), reason: '必须落在长摘录深段');

      // classic → archive → classic → archive, all at the deep offset.
      for (final style in const [
        AppThemeStyle.archive,
        AppThemeStyle.classic,
        AppThemeStyle.archive,
      ]) {
        await store.select(style);
        await tester.pumpAndSettle();
        final after = _firstVisibleBookmark(tester, marks.records);
        expect(after, isNotNull, reason: '${style.name} 必须仍有可见书签');
        expect(after!.$1, anchorRecord.$1, reason: '${style.name} 顶部书签必须不变');
        expect(
          after.$2,
          closeTo(anchorRecord.$2, 2),
          reason: '${style.name} 行内偏移必须保持',
        );
        expect(
          marks.records.indexWhere((record) => record.key == after.$1),
          targetIndex,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('bookmark error row height keeps the content anchor', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final marks = _PanelStore([for (var i = 0; i < 10; i++) _mark(i)]);
      addTearDown(marks.changes.dispose);
      await _launch<ReaderBookmark>(
        tester,
        store,
        ReaderBookmarksPanel(
          bookId: 'book',
          preset: ReaderThemePreset.light,
          store: marks,
          onAdd: () async => null,
        ),
        size: const Size(390, 600),
      );
      await tester.drag(
        find.byKey(const ValueKey('reader-bookmarks-list')),
        const Offset(0, -220),
      );
      await tester.pumpAndSettle();

      // A failed reload keeps the last successful list and grows the header.
      marks.failRead = true;
      marks.changes.value++;
      await tester.pumpAndSettle();
      expect(find.text('书签读取失败，请重试'), findsOneWidget);
      final before = _firstVisibleBookmark(tester, marks.records);
      expect(before, isNotNull);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      final after = _firstVisibleBookmark(tester, marks.records);
      expect(after, isNotNull);
      expect(after!.$1, before!.$1);
      expect(after.$2, closeTo(before.$2, 2));

      // Back in classic the fixed header is on screen again, with the same
      // record still anchored.
      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.text('书签读取失败，请重试'), findsOneWidget);
      final back = _firstVisibleBookmark(tester, marks.records);
      expect(back!.$1, before.$1);
      expect(back.$2, closeTo(before.$2, 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('classic delete failure keeps the record and retries', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final marks = _PanelStore([_mark(1)]);
      addTearDown(marks.changes.dispose);
      await _launch<ReaderBookmark>(
        tester,
        store,
        ReaderBookmarksPanel(
          bookId: 'book',
          preset: ReaderThemePreset.light,
          store: marks,
          onAdd: () async => null,
        ),
      );
      marks.failDelete = true;
      await tester.tap(
        find.byKey(ValueKey('reader-bookmark-delete-${_mark(1).key}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('reader-bookmark-confirm-delete')),
      );
      await tester.pumpAndSettle();
      expect(find.text('书签删除失败，请重试'), findsOneWidget);
      expect(marks.records, hasLength(1));

      // Retry re-opens the shared confirm before deleting again.
      marks.failDelete = false;
      await tester.tap(
        find.byKey(const ValueKey('reader-bookmarks-retry-action')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('archive-confirm')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('reader-bookmark-confirm-delete')),
      );
      await tester.pumpAndSettle();
      expect(marks.records, isEmpty);
      expect(marks.deletes, 2);
      expect(find.text('本书 0 条记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('阅读设置', () {
    testWidgets('classic one-screen panel drives the same preferences', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final changes = <ReaderPreferences>[];
      final brightnesses = <double>[];
      var brightnessEnded = 0;
      var textReplacements = 0;
      await _openSettings(
        tester,
        store,
        changes: changes,
        brightnesses: brightnesses,
        onBrightnessEnd: () => brightnessEnded++,
        onTextReplacement: () => textReplacements++,
      );

      expect(
        find.byKey(const ValueKey('reader-appearance-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-settings-category-grid')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('reader-brightness')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-font-size')), findsOneWidget);
      expect(find.text('阅读设置'), findsOneWidget);

      // Font size: two quick taps then an immediate close must still deliver
      // the final value exactly once through the 120ms merge.
      await tester.tap(find.byKey(const ValueKey('reader-font-size-increase')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('reader-font-size-increase')));
      await tester.pump();
      await _closeSettings(tester);
      expect(
        find.byKey(const ValueKey('reader-appearance-scroll')),
        findsNothing,
      );
      expect(changes.last.fontSize, 20);

      // Reopen (a fresh sheet gets the committed value) and exercise the rest.
      changes.clear();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('20'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-spacing-loose')));
      await tester.pump(const Duration(milliseconds: 150));
      expect(changes.last.lineHeight, 2.1);
      await tester.tap(find.byKey(const ValueKey('reader-theme-dark')));
      await tester.pump(const Duration(milliseconds: 150));
      expect(changes.last.themePreset, ReaderThemePreset.dark);

      // Brightness: the classic Material slider keeps the device contract.
      await tester.drag(
        find.byKey(const ValueKey('reader-brightness')),
        const Offset(60, 0),
      );
      await tester.pump();
      expect(brightnesses, isNotEmpty);
      expect(brightnessEnded, greaterThan(0));

      // 更多设置 is the current full sheet: every option stays reachable.
      // Scroll to the deep 正文替换 entry and exercise it, instead of only
      // finding eagerly-built text.
      await tester.tap(find.byKey(const ValueKey('reader-more-appearance')));
      await tester.pumpAndSettle();
      // The action row below the new sheet still says 更多设置 too.
      expect(find.text('更多设置'), findsWidgets);
      final moreScroll = find.descendant(
        of: find.byKey(const ValueKey('reader-more-settings-scroll')),
        matching: find.byType(Scrollable),
      );
      expect(moreScroll, findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('正文替换'),
        240,
        scrollable: moreScroll,
      );
      await tester.pumpAndSettle();
      expect(find.text('正文替换').hitTestable(), findsOneWidget);
      await tester.tap(find.text('正文替换'));
      await tester.pumpAndSettle();
      expect(textReplacements, 1);
      expect(
        find.byKey(const ValueKey('reader-appearance-scroll')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('archive still opens the category grid', (tester) async {
      final store = await _style(AppThemeStyle.archive);
      await _openSettings(tester, store);
      expect(
        find.byKey(const ValueKey('reader-settings-category-grid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-appearance-scroll')),
        findsNothing,
      );
    });

    for (final style in const [AppThemeStyle.classic, AppThemeStyle.archive]) {
      testWidgets('${style.name} 跟随系统真的切换、回调并带到最终值', (tester) async {
        final store = await _style(style);
        final changes = <ReaderPreferences>[];
        var followCalls = 0;
        await _openSettings(
          tester,
          store,
          initial: const ReaderPreferences(followSystemBrightness: false),
          changes: changes,
          onFollowSystem: () => followCalls++,
        );
        if (style == AppThemeStyle.archive) {
          await tester.tap(
            find.byKey(const ValueKey('reader-settings-category-page')),
          );
          await tester.pumpAndSettle();
        }

        await tester.tap(find.byKey(const ValueKey('reader-follow-system')));
        await tester.pump();
        expect(followCalls, 1, reason: '跟随系统必须调用设备回调');
        final follow = find.byKey(const ValueKey('reader-follow-system'));
        if (style == AppThemeStyle.classic) {
          expect(
            tester
                .widget<TextButton>(follow)
                .style
                ?.foregroundColor
                ?.resolve({}),
            ReaderThemePreset.light.accentColor,
          );
        } else {
          expect(tester.widget<GlassTextButton>(follow).selected, isTrue);
        }

        // A second edit carries the toggled flag into the merged final write.
        if (style == AppThemeStyle.classic) {
          await tester.tap(
            find.byKey(const ValueKey('reader-font-size-increase')),
          );
        } else {
          await tester.tap(find.byKey(const ValueKey('reader-info-compact')));
        }
        await tester.pump(const Duration(milliseconds: 150));
        expect(changes.last.followSystemBrightness, isTrue);
        await _closeSettings(tester);
        expect(followCalls, 1);
        expect(changes.last.followSystemBrightness, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('classic slider keeps state through a mid-drag style switch', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final brightnesses = <double>[];
      await _openSettings(tester, store, brightnesses: brightnesses);
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-brightness')),
      );
      final gesture = await tester.startGesture(rect.center);
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(brightnesses, isNotEmpty);

      // The classic Material slider disappears under the pointer.
      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-settings-category-grid')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-appearance-scroll')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('style switch under an open panel keeps the edited value', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final changes = <ReaderPreferences>[];
      await _openSettings(tester, store, changes: changes);
      await tester.tap(find.byKey(const ValueKey('reader-font-size-increase')));
      await tester.pump(const Duration(milliseconds: 150));

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-settings-category-grid')),
        findsOneWidget,
      );
      expect(changes.last.fontSize, 19);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.text('19'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('选区工具条', () {
    testWidgets('classic bar is the flat dark arrow bar with all actions', (
      tester,
    ) async {
      final store = await _style(AppThemeStyle.classic);
      final fired = <ReaderParagraphAction>[];
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        AppUiHost(
          store: store,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: Scaffold(
                body: Center(
                  child: ReaderParagraphMenu(
                    underlined: false,
                    paragraphScoped: true,
                    showListening: true,
                    showBookmark: true,
                    showAi: true,
                    onAction: fired.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('reader-selection-classic-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-selection-glass-bar')),
        findsNothing,
      );
      for (final key in const [
        'reader-action-listen',
        'reader-action-copy',
        'reader-action-underline',
        'reader-action-bookmark',
        'reader-action-missed',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      // Narrow + large text: the row scrolls instead of clipping a handle.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('reader-selection-classic-bar')),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('reader-action-copy')));
      expect(fired, [ReaderParagraphAction.copy]);
      expect(tester.takeException(), isNull);
    });

    test('classic geometry uses the 60x48 item and the arrow allowance', () {
      const view = Size(320, 640);
      const safe = EdgeInsets.zero;
      // Five actions, below the anchor: width clamped to the viewport and the
      // top is the anchor plus the arrow tip.
      final (below, isBelow) = ReaderParagraphMenu.resolvePosition(
        anchor: const Offset(160, 400),
        topAnchor: const Offset(0, 300),
        paragraphScoped: true,
        view: view,
        safeArea: safe,
        underlined: false,
        showListening: true,
        showBookmark: true,
        showAi: true,
        classic: true,
      );
      expect(isBelow, isTrue);
      expect(below.dx, 10);
      expect(below.dy, 408);

      // Flipped above a tall selection: 64dp bar + 8dp arrow + clearance.
      final (above, isAbove) = ReaderParagraphMenu.resolvePosition(
        anchor: const Offset(160, 560),
        topAnchor: const Offset(0, 500),
        paragraphScoped: true,
        view: view,
        safeArea: safe,
        underlined: false,
        showListening: true,
        showBookmark: true,
        showAi: true,
        classic: true,
      );
      expect(isAbove, isFalse);
      expect(above.dy, 418);

      // Archive maths are untouched (52dp bar, no layout arrow).
      final (archive, archiveBelow) = ReaderParagraphMenu.resolvePosition(
        anchor: const Offset(160, 400),
        paragraphScoped: true,
        view: view,
        safeArea: safe,
        underlined: false,
        showBookmark: true,
        showAi: true,
      );
      expect(archiveBelow, isTrue);
      expect(archive.dy, 408);
    });
  });

  testWidgets(
    'classic bar honours the caller maxWidth and scrolls to the last action',
    (tester) async {
      final store = await _style(AppThemeStyle.classic);
      final fired = <ReaderParagraphAction>[];
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        AppUiHost(
          store: store,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                child: ReaderParagraphMenu(
                  maxWidth: 160,
                  showListening: true,
                  showBookmark: true,
                  showAi: true,
                  onAction: fired.add,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bar = find.byKey(const ValueKey('reader-selection-classic-bar'));
      // MediaQuery is 400 wide, the local overlay slot only 160: the renderer
      // must clamp to the caller's width, not the window.
      expect(tester.getSize(bar).width, lessThanOrEqualTo(160));
      final row = find.descendant(
        of: bar,
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(row, const Offset(-260, 0));
      await tester.pumpAndSettle();
      final last = find.byKey(const ValueKey('reader-action-missed'));
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      expect(fired, [ReaderParagraphAction.missedChange]);

      // resolvePosition keeps the same clamped width for the local view.
      final (position, _) = ReaderParagraphMenu.resolvePosition(
        anchor: const Offset(80, 300),
        paragraphScoped: true,
        view: const Size(180, 600),
        safeArea: EdgeInsets.zero,
        underlined: false,
        showListening: true,
        showBookmark: true,
        showAi: true,
        classic: true,
      );
      expect(position.dx, 10);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('经典主题长按段落：窄屏大字号下用 classic 工具条复制', (tester) async {
    final store = await _style(AppThemeStyle.classic);
    final marks = _PanelStore([]);
    addTearDown(marks.changes.dispose);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mountReader(
      tester,
      store,
      marks,
      size: const Size(280, 620),
      textScale: 2,
    );

    final paragraph = find.byKey(const ValueKey('reader-paragraph-0'));
    await tester.ensureVisible(paragraph);
    await tester.pumpAndSettle();
    await tester.longPress(paragraph);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reader-selection-classic-bar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-selection-glass-bar')),
      findsNothing,
    );
    for (final key in const [
      'reader-action-listen',
      'reader-action-copy',
      'reader-action-underline',
      'reader-action-bookmark',
    ]) {
      expect(
        find.byKey(ValueKey(key)).hitTestable(),
        findsOneWidget,
        reason: key,
      );
    }
    await tester.tap(find.byKey(const ValueKey('reader-action-copy')));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect(copied.single, contains('c1 第 0 段'));
    expect(
      find.byKey(const ValueKey('reader-selection-classic-bar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('经典书签跨章：从第二章回到第一章的保存位置', (tester) async {
    final store = await _style(AppThemeStyle.classic);
    final marks = _PanelStore([]);
    addTearDown(marks.changes.dispose);
    await _mountReader(tester, store, marks);
    await _openControls(tester);

    // Save a bookmark in chapter one.
    await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
    await tester.pumpAndSettle();
    expect(marks.records, hasLength(1));
    expect(marks.records.single.chapterId, 'c1');
    Navigator.of(
      tester.element(find.byKey(const ValueKey('reader-bookmarks-scroll'))),
    ).pop();
    await tester.pumpAndSettle();

    // Move to chapter two through the classic directory.
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-catalogue-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二章'));
    await tester.pumpAndSettle();
    expect(find.textContaining('c2 第 0 段'), findsOneWidget);

    // The stored source anchor brings the reader back to chapter one.
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('reader-bookmark-${marks.records.single.key}')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('c1 第 0 段'), findsOneWidget);
    await _openControls(tester);
    expect(find.text('正在阅读 · 第 1 章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

// ── fixtures ────────────────────────────────────────────────────────────────

final _volumes = [
  Chapter(itemId: 'c0', title: '晨光', volumeName: '卷一'),
  Chapter(itemId: 'c1', title: '暮色', volumeName: '卷二', version: 'v1'),
  Chapter(itemId: 'c2', title: '夜雨', volumeName: '卷二'),
];

final _manyChapters = [
  for (var i = 0; i < 60; i++)
    Chapter(itemId: 'm$i', title: '同名 ${i ~/ 10} · 第 $i 章', volumeName: ''),
];

Widget _directory({
  required List<Chapter> chapters,
  Set<String> cachedIds = const {},
  List<AiChapterCheckStatus>? aiStatuses,
}) => ReaderDirectorySheet(
  chapters: chapters,
  currentIndex: 0,
  cachedIds: cachedIds,
  bookId: 'directory-book',
  aiStatuses:
      aiStatuses ??
      [_aiStatus('c1', AiChapterCheckState.checked, version: 'v1')],
  aiController: AiReadingController.instance,
);

AiChapterCheckStatus _aiStatus(
  String chapterId,
  AiChapterCheckState state, {
  String version = '',
}) => AiChapterCheckStatus(
  bookId: 'directory-book',
  chapterId: chapterId,
  chapterVersion: version,
  state: state,
  updatedAt: DateTime(2026),
);

ReaderBookmark _mark(int offset, {String? text}) => ReaderBookmark(
  bookId: 'book',
  chapterId: 'chapter',
  title: '第一章',
  text: text ?? '摘录 $offset',
  sourceOffset: offset,
  createdAt: offset,
);

Future<AppThemeStyleStore> _style(AppThemeStyle style) async {
  final store = AppThemeStyleStore();
  addTearDown(store.dispose);
  await store.select(style);
  return store;
}

class _Launched<T> {
  T? value;
  bool closed = false;
}

/// Pushes [panel] on the root Navigator above the live [AppUiScope] so a style
/// switch reaches the already-open route.
Future<_Launched<T>> _launch<T>(
  WidgetTester tester,
  AppThemeStyleStore store,
  Widget panel, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final launched = _Launched<T>();
  await tester.pumpWidget(
    AppUiHost(
      store: store,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  launched.value = await Navigator.of(
                    context,
                  ).push<T>(MaterialPageRoute(builder: (_) => panel));
                  launched.closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return launched;
}

class _SettingsHost extends StatefulWidget {
  const _SettingsHost({
    required this.initial,
    required this.changes,
    required this.brightnesses,
    required this.onBrightnessEnd,
    required this.onFollowSystem,
    required this.onTextReplacement,
  });

  final ReaderPreferences initial;
  final List<ReaderPreferences> changes;
  final List<double> brightnesses;
  final VoidCallback onBrightnessEnd;
  final VoidCallback onFollowSystem;
  final VoidCallback onTextReplacement;

  @override
  State<_SettingsHost> createState() => _SettingsHostState();
}

class _SettingsHostState extends State<_SettingsHost> {
  late ReaderPreferences _current = widget.initial;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => showReaderSettingsSheet(
          context: context,
          initialValue: _current,
          onChanged: (next) {
            widget.changes.add(next);
            setState(() => _current = next);
          },
          onPickFont: () async => null,
          deviceAvailable: true,
          systemBrightness: 0.45,
          onBrightness: widget.brightnesses.add,
          onBrightnessEnd: widget.onBrightnessEnd,
          onFollowSystem: widget.onFollowSystem,
          autoTurnActive: false,
          onAutoTurn: () {},
          onTextReplacement: widget.onTextReplacement,
          onMarks: () {},
        ),
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _openSettings(
  WidgetTester tester,
  AppThemeStyleStore store, {
  ReaderPreferences initial = const ReaderPreferences(),
  List<ReaderPreferences>? changes,
  List<double>? brightnesses,
  VoidCallback? onBrightnessEnd,
  VoidCallback? onFollowSystem,
  VoidCallback? onTextReplacement,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppUiHost(
      store: store,
      home: _SettingsHost(
        initial: initial,
        changes: changes ?? <ReaderPreferences>[],
        brightnesses: brightnesses ?? <double>[],
        onBrightnessEnd: onBrightnessEnd ?? () {},
        onFollowSystem: onFollowSystem ?? () {},
        onTextReplacement: onTextReplacement ?? () {},
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// First chapter row that intersects the directory list viewport, with its
/// top offset relative to the viewport. Row ids are the real chapter indices.
(int, double)? _firstVisibleDirectoryRow(WidgetTester tester) {
  final list = find.byKey(const ValueKey('reader-directory-scroll'));
  if (list.evaluate().isEmpty) return null;
  final bounds = tester.getRect(list);
  (int, double)? best;
  for (var index = 0; index < 200; index++) {
    final row = find.byKey(ValueKey('reader-directory-row-$index'));
    if (row.evaluate().isEmpty) continue;
    final rect = tester.getRect(row);
    if (rect.bottom <= bounds.top || rect.top >= bounds.bottom) continue;
    final delta = rect.top - bounds.top;
    if (best == null || delta < best.$2) best = (index, delta);
  }
  return best;
}

/// First bookmark record that intersects the panel viewport, with its top
/// offset relative to the scrollable.
(String, double)? _firstVisibleBookmark(
  WidgetTester tester,
  List<ReaderBookmark> records,
) {
  final scrollables = find.descendant(
    of: find.byType(ReaderBookmarksPanel),
    matching: find.byType(Scrollable),
  );
  if (scrollables.evaluate().isEmpty) return null;
  final bounds = tester.getRect(scrollables.last);
  (String, double)? best;
  for (final record in records) {
    final row = find.byKey(ValueKey('reader-bookmark-${record.key}'));
    if (row.evaluate().isEmpty) continue;
    final rect = tester.getRect(row);
    if (rect.bottom <= bounds.top || rect.top >= bounds.bottom) continue;
    final delta = rect.top - bounds.top;
    if (best == null || delta < best.$2) best = (record.key, delta);
  }
  return best;
}

/// First find result that intersects the panel's result viewport.
(int, double)? _firstVisibleFindResult(WidgetTester tester, int count) {
  final list =
      find.byKey(const ValueKey('reader-find-results')).evaluate().isNotEmpty
      ? find.byKey(const ValueKey('reader-find-results'))
      : find.byKey(const ValueKey('reader-find-scroll'));
  if (list.evaluate().isEmpty) return null;
  final bounds = tester.getRect(list);
  (int, double)? best;
  for (var index = 0; index < count; index++) {
    final row = find.byKey(ValueKey('reader-find-result-$index'));
    if (row.evaluate().isEmpty) continue;
    final rect = tester.getRect(row);
    if (rect.bottom <= bounds.top || rect.top >= bounds.bottom) continue;
    final delta = rect.top - bounds.top;
    if (best == null || delta < best.$2) best = (index, delta);
  }
  return best;
}

Future<void> _closeSettings(WidgetTester tester) async {
  final archiveClose = find.byKey(const ValueKey('reader-settings-close'));
  await tester.tap(
    archiveClose.evaluate().isNotEmpty
        ? archiveClose
        : find.byTooltip('关闭排版设置'),
  );
  await tester.pumpAndSettle();
}

Future<void> _openControls(WidgetTester tester) async {
  if (find
      .byKey(const ValueKey('reader-classic-toolbar'))
      .evaluate()
      .isNotEmpty) {
    return;
  }
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
}

Future<void> _mountReader(
  WidgetTester tester,
  AppThemeStyleStore store,
  _PanelStore marks, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppUiHost(
      store: store,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: ReaderPage(
            bookId: 'classic-panels',
            title: '经典面板测试',
            chapters: [
              Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
              Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
            ],
            startIndex: 0,
            readerDevice: _Device(),
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            bookmarkStore: marks,
            chapterLoader: (chapter) async => List.generate(
              8,
              (index) => '${chapter.itemId} 第 $index 段正文内容，用于经典面板测试。',
            ).join('\n\n'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<http.Response> _api(http.Request request) async {
  // The reader may look up an adapted-drama match when controls open; answer
  // without a match so no real isolate/network path runs in the fake clock.
  final data = request.url.path.endsWith('/video-match')
      ? const <String, Object>{}
      : const <String, Object>{};
  return http.Response(
    jsonEncode({'code': 0, 'data': data}),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

class _PanelStore extends ReaderBookmarkStore {
  _PanelStore(List<ReaderBookmark> records) : records = List.of(records);
  final List<ReaderBookmark> records;
  bool failRead = false;
  bool failDelete = false;
  int deletes = 0;

  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async {
    if (failRead) throw StateError('read failed');
    return records.where((mark) => mark.bookId == bookId).toList();
  }

  @override
  Future<void> add(ReaderBookmark record) async {
    records.removeWhere((entry) => entry.key == record.key);
    records.add(record);
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    deletes++;
    if (failDelete) throw StateError('delete failed');
    records.removeWhere((entry) => entry.key == key);
    changes.value++;
  }
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();

  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 10, 30, 9),
    battery: 80,
    systemBrightness: 0.45,
  );

  @override
  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async => true;

  @override
  Future<void> suspend() async {}

  @override
  Future<void> close() async {}

  @override
  Future<ReaderFont?> pickFont() async => null;
}
