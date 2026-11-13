import 'dart:async';
import 'dart:ui' show SemanticsAction, Tristate;
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/reader/reader_book_notes.dart';
import 'package:fqapp/widgets/reader/reader_book_panel.dart';
import 'package:fqapp/widgets/reader/reader_directory_sheet.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

final _book = MediaItem(
  id: 'panel-book',
  title: '缓存书名',
  cover: '',
  author: '缓存作者',
  badge: '',
  ep: '',
  kind: 'book',
  intro: '离线保留的简介',
  categories: ['缓存分类'],
);
const _author = BookAuthor(id: 'author-7', name: '详情作者');
const _detail = BookDetail(
  bookId: 'panel-book',
  title: '完整书名',
  author: _author,
  abstract: '重新加载后的完整简介',
  tags: ['完整分类'],
);
final _chapters = [
  for (var i = 0; i < 40; i++)
    Chapter(
      itemId: 'chapter-$i',
      title: '第 $i 章${i == 2 || i == 5 ? ' · 相逢' : ''}',
      volumeName: '',
    ),
];

class _Bookmarks extends ReaderBookmarkStore {
  final records = <ReaderBookmark>[];
  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async =>
      records.where((r) => r.bookId == bookId).toList();
}

class _Underlines extends ReaderUnderlineStore {
  final paragraphs = <ReaderUnderline>[];
  final ranges = <ReaderRangeUnderline>[];
  @override
  Future<List<ReaderUnderline>> loadBook(String bookId) async =>
      paragraphs.where((r) => r.bookId == bookId).toList();
  @override
  Future<List<ReaderRangeUnderline>> loadBookRanges(String bookId) async =>
      ranges.where((r) => r.bookId == bookId).toList();
  @override
  Future<Map<String, ReaderUnderline>> load(
    String bookId,
    String chapterId,
  ) async => {
    for (final r in paragraphs)
      if (r.bookId == bookId && r.chapterId == chapterId) r.key: r,
  };
  @override
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) async => ranges
      .where((r) => r.bookId == bookId && r.chapterId == chapterId)
      .toList();
}

class _PanelFixture {
  final bookmarks = _Bookmarks();
  final underlines = _Underlines();
  final insets = ValueNotifier<double>(0);
  final events = <Object>[];
  int? selectedChapter;
  int detailLoads = 0;
  Future<BookDetail> Function()? detailLoader;
  late AppThemeStyleStore style;

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
    bool showAi = false,
    bool aiCached = false,
    List<Chapter>? chapters,
    double currentProgress = .426,
    AiChapterCheckState aiState = AiChapterCheckState.checked,
    ReaderThemePreset preset = ReaderThemePreset.light,
  }) async {
    style = AppThemeStyleStore();
    await style.select(AppThemeStyle.classic);
    addTearDown(style.dispose);
    addTearDown(bookmarks.changes.dispose);
    addTearDown(underlines.changes.dispose);
    addTearDown(insets.dispose);
    _size(tester, size);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(
          Brightness.light,
          style: AppThemeStyle.classic,
        ),
        builder: (context, child) => AppUiScope(
          store: style,
          child: ValueListenableBuilder<double>(
            valueListenable: insets,
            builder: (context, bottom, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
                viewInsets: EdgeInsets.only(bottom: bottom),
              ),
              child: child!,
            ),
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                child: const Text('打开书籍面板'),
                onPressed: () async {
                  selectedChapter = await showModalBottomSheet<int>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    sheetAnimationStyle: AnimationStyle.noAnimation,
                    builder: (context) => Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.viewInsetsOf(context).bottom,
                      ),
                      child: FractionallySizedBox(
                        heightFactor: .92,
                        child: ReaderBookPanel(
                          book: _book,
                          preset: preset,
                          loadDetail: () {
                            detailLoads++;
                            return detailLoader?.call() ??
                                Future.value(_detail);
                          },
                          directory: ReaderDirectorySheet(
                            chapters: chapters ?? _chapters,
                            currentIndex: 2,
                            currentProgress: currentProgress,
                            cachedIds: const {'chapter-2'},
                            bookId: _book.id,
                            aiStatuses: [
                              AiChapterCheckStatus(
                                bookId: _book.id,
                                chapterId: 'chapter-2',
                                chapterVersion: '',
                                state: aiState,
                                updatedAt: DateTime(2026),
                              ),
                            ],
                            aiController: AiReadingController.instance,
                            embedded: true,
                            preset: preset,
                          ),
                          notes: ReaderBookNotes(
                            bookId: _book.id,
                            chapters: chapters ?? _chapters,
                            preset: preset,
                            bookmarkStore: bookmarks,
                            underlineStore: underlines,
                            onBookmark: events.add,
                            onUnderline: events.add,
                            onRangeUnderline: events.add,
                          ),
                          onDetails: () => events.add('details'),
                          onAuthor: events.add,
                          onSearch: () => events.add('search'),
                          onNight: () => events.add('night'),
                          onSettings: () => events.add('settings'),
                          onAi: showAi ? () => events.add('ai') : null,
                          aiLabel: aiCached ? 'AI 已校对' : 'AI 校对',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开书籍面板'));
    await tester.pumpAndSettle();
  }
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _key(String key) => find.byKey(ValueKey(key));
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester, String text) async {
  if (_key('reader-chapter-search').evaluate().isEmpty) {
    await _tap(tester, _key('reader-catalogue-search-toggle'));
  }
  await tester.enterText(_key('reader-chapter-search'), text);
  await tester.pump(const Duration(milliseconds: 220));
  await tester.pumpAndSettle();
}

double _directoryOffset(WidgetTester tester) =>
    tester.widget<ListView>(_key('reader-directory-scroll')).controller!.offset;

double _notesOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: _key('reader-book-notes-scroll'),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position
    .pixels;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    http.runWithClient(
      () => ApiClient.instance,
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 0, 'data': <String, Object>{}}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
  });
  setUp(() {
    setSingleChapterPrefs({
      'reader_page_mode': 'paged',
      'reader_page_turn_style': 'none',
    });
    resetAppUiTestDiagnostics();
    testerBinding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'fqapp/system_tts',
      'fqapp/system_tts_events',
      'fqapp/native_player',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (call) async => call.method == 'initialize' ? 4000 : null,
      );
    }
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'fqapp/system_tts',
      'fqapp/system_tts_events',
      'fqapp/native_player',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  testWidgets(
    'opens on embedded directory with selected cached chapter and rounded progress',
    (tester) async {
      final fixture = _PanelFixture();
      await fixture.open(tester);
      expect(_key('reader-directory-row-2').hitTestable(), findsOneWidget);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pump();
        expect(
          tester
              .getSemantics(_key('reader-directory-row-2'))
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
      } finally {
        semantics.dispose();
      }
      expect(find.text('读到43%'), findsOneWidget);
      expect(find.text('已缓存'), findsOneWidget);
      expect(find.text('AI 已校对'), findsOneWidget);
      final progress = tester.getRect(_key('reader-directory-title-progress'));
      final ai = tester.getRect(find.text('AI 已校对'));
      expect(progress.right, lessThan(ai.left), reason: '右侧只保留 AI 与缓存两行');
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.text('共 40 章'), findsOneWidget);
      expect(tester.getTopLeft(find.text('共 40 章')).dx, 20);
      expect(_key('reader-book-ai'), findsNothing);
      expect(find.text('目录 · 40 章'), findsNothing);
      expect(_key('reader-book-title').hitTestable(), findsOneWidget);
      final titleArea = tester.getRect(_key('reader-book-title'));
      final searchArea = tester.getRect(_key('reader-book-full-search'));
      final cover = tester.getRect(_key('reader-book-cover'));
      expect(find.text('搜全文'), findsOneWidget);
      expect(titleArea.right, greaterThanOrEqualTo(searchArea.right));
      expect(searchArea.top, greaterThanOrEqualTo(titleArea.bottom));
      expect(tester.getRect(find.text('完整书名')).top, greaterThan(cover.top));
      final authorText = tester.getRect(find.text('详情作者'));
      final searchText = tester.getRect(find.text('搜全文'));
      expect(authorText.bottom, lessThan(cover.bottom));
      expect(
        authorText.center.dy,
        closeTo(searchText.center.dy, .5),
        reason: '作者和搜索文字在同一水平线上',
      );
      expect(
        tester.getRect(find.text('完整书名')).left,
        closeTo(authorText.left, .5),
      );
      expect(
        titleArea.right,
        closeTo(
          tester.getSize(find.byType(ReaderBookPanel)).width - cover.left,
          .5,
        ),
        reason: '头部两侧留白一致',
      );
      expect(fixture.detailLoads, 1);
      expect(AppUiScope.debugFallbackReads, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'full search exposes a button and 48px hit target at $width, ${scale}x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final fixture = _PanelFixture();
            await fixture.open(tester, size: Size(width, 844), scale: scale);
            final search = _key('reader-book-full-search');
            final node = tester.getSemantics(search);
            expect(node.flagsCollection.isButton, isTrue);
            expect(
              node.getSemanticsData().hasAction(SemanticsAction.tap),
              isTrue,
            );
            expect(node.label, contains('搜全文'));
            final target = tester.getRect(search);
            expect(target.width, greaterThanOrEqualTo(48));
            expect(target.height, greaterThanOrEqualTo(48));
            final panel = tester.getRect(find.byType(ReaderBookPanel));
            expect(target.left, greaterThanOrEqualTo(panel.left));
            expect(target.right, lessThanOrEqualTo(panel.right));
            // The extra touch area below the short visual chip is interactive.
            await tester.tapAt(target.bottomCenter - const Offset(0, 1));
            await tester.pumpAndSettle();
            expect(fixture.events, ['search']);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          } finally {
            semantics.dispose();
          }
        },
      );
    }

    for (final state in [
      AiChapterCheckState.running,
      AiChapterCheckState.failed,
    ]) {
      testWidgets(
        'embedded long title retains readable allocation at $width, 2x, 100%, $state and cached',
        (tester) async {
          final fixture = _PanelFixture();
          final chapters = [
            for (var i = 0; i < 8; i++)
              Chapter(
                itemId: 'chapter-$i',
                title: '第 $i 章 山风穿过树林之后我们终于在漫长旅途尽头重逢的故事',
                volumeName: '',
              ),
          ];
          await fixture.open(
            tester,
            size: Size(width, 844),
            scale: 2,
            chapters: chapters,
            currentProgress: 1,
            aiState: state,
          );
          final row = _key('reader-directory-row-2');
          final title = tester.getRect(find.text(chapters[2].title));
          final progress = tester.getRect(
            _key('reader-directory-title-progress'),
          );
          final status = tester.getRect(
            find.text(
              state == AiChapterCheckState.running ? 'AI 校对中' : 'AI 校对失败',
            ),
          );
          final cached = tester.getRect(find.text('已缓存'));
          final bounds = tester.getRect(row);
          expect(row.hitTestable(), findsOneWidget);
          expect(find.text('读到100%'), findsOneWidget);
          expect(
            title.width,
            greaterThanOrEqualTo(30 * 3),
            reason: 'At least three scaled CJK characters remain per line.',
          );
          expect(
            title.height,
            greaterThan(30),
            reason: 'The actual long title occupies two lines.',
          );
          expect(progress.top, greaterThanOrEqualTo(title.bottom - .5));
          expect(progress.left, closeTo(title.left, .5));
          expect(progress.right, lessThanOrEqualTo(title.right + .5));
          expect(title.right, lessThan(status.left));
          expect(progress.right, lessThan(status.left));
          expect(status.bottom, lessThanOrEqualTo(cached.top));
          for (final rect in [title, progress, status, cached]) {
            expect(rect.top, greaterThanOrEqualTo(bounds.top));
            expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
          }
          final list = tester.widget<ListView>(_key('reader-directory-scroll'));
          expect(bounds.height, closeTo(list.itemExtent!, .5));
          expect(
            bounds.height,
            greaterThanOrEqualTo(title.height + progress.height),
          );
          expect(
            bounds.height,
            lessThanOrEqualTo(title.height + progress.height + 16.5),
            reason: 'Fixed fast-scroll extent follows actual text metrics.',
          );
          // Non-current rows use the same fixed stride without a progress child.
          final other = _key('reader-directory-row-3');
          expect(tester.getSize(other).height, closeTo(bounds.height, .5));
          expect(
            find.descendant(of: other, matching: find.text('读到100%')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final cached in [false, true]) {
    testWidgets('AI action is available from every tab, cached=$cached', (
      tester,
    ) async {
      final fixture = _PanelFixture();
      await fixture.open(tester, showAi: true, aiCached: cached);
      for (var tab = 0; tab < 3; tab++) {
        await _tap(tester, _key('reader-book-tab-$tab'));
        await _tap(tester, _key('reader-book-ai'));
      }
      expect(fixture.events, ['ai', 'ai', 'ai']);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'pending metadata does not keep the active directory or notes animating',
    (tester) async {
      final fixture = _PanelFixture();
      final detail = Completer<BookDetail>();
      fixture.detailLoader = () => detail.future;
      await fixture.open(tester);
      expect(_key('reader-directory-row-2').hitTestable(), findsOneWidget);
      await _tap(tester, _key('reader-book-tab-2'));
      expect(find.text('本书还没有书签或划线').hitTestable(), findsOneWidget);
      detail.complete(_detail);
      await tester.pumpAndSettle();
      await _tap(tester, _key('reader-book-tab-0'));
      expect(find.text('重新加载后的完整简介').hitTestable(), findsOneWidget);
      expect(fixture.detailLoads, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'chapter filter and reverse order return catalogue index through the shell route',
    (tester) async {
      final fixture = _PanelFixture();
      await fixture.open(tester);
      await _query(tester, '相逢');
      expect(find.text('找到 2 章'), findsOneWidget);
      expect(_key('reader-directory-row-0'), findsNothing);
      expect(
        tester.getTopLeft(_key('reader-directory-row-2')).dy,
        lessThan(tester.getTopLeft(_key('reader-directory-row-5')).dy),
      );
      await _tap(tester, _key('reader-catalogue-order'));
      expect(
        tester.getTopLeft(_key('reader-directory-row-5')).dy,
        lessThan(tester.getTopLeft(_key('reader-directory-row-2')).dy),
      );
      await _tap(tester, _key('reader-directory-row-5'));
      expect(fixture.selectedChapter, 5);
      expect(find.byType(ReaderBookPanel), findsNothing);
    },
  );

  testWidgets(
    'tabs retain real directory query/scroll and notes filter/scroll/confirmation',
    (tester) async {
      final fixture = _PanelFixture();
      for (var i = 0; i < 20; i++) {
        fixture.bookmarks.records.add(
          ReaderBookmark(
            bookId: _book.id,
            chapterId: 'chapter-2',
            title: '第二章',
            text: '持久摘录 $i',
            sourceOffset: i,
            createdAt: i + 1,
          ),
        );
      }
      await fixture.open(tester);
      await _query(tester, '章');
      await tester.drag(_key('reader-directory-scroll'), const Offset(0, -430));
      await tester.pumpAndSettle();
      final directoryOffset = _directoryOffset(tester);
      expect(directoryOffset, greaterThan(100));
      await _tap(tester, _key('reader-book-tab-2'));
      await _tap(tester, _key('reader-book-notes-filter-bookmarks'));
      await tester.drag(
        _key('reader-book-notes-scroll'),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      final notesOffset = _notesOffset(tester);
      expect(notesOffset, greaterThan(100));
      await _tap(tester, _key('reader-book-tab-0'));
      expect(find.text('重新加载后的完整简介').hitTestable(), findsOneWidget);
      await _tap(tester, _key('reader-book-tab-1'));
      expect(
        tester
            .widget<TextField>(_key('reader-chapter-search'))
            .controller!
            .text,
        '章',
      );
      expect(_directoryOffset(tester), closeTo(directoryOffset, 1));
      await _tap(tester, _key('reader-book-tab-2'));
      expect(_notesOffset(tester), closeTo(notesOffset, 1));
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(
                const ValueKey('reader-book-notes-filter-bookmarks'),
                skipOffstage: false,
              ),
            )
            .selected,
        isTrue,
      );
      // An in-progress confirmation belongs to the notes tab, rather than a route.
      final deletes = find.byTooltip('删除书签').hitTestable();
      await _tap(tester, deletes.first);
      await _tap(tester, _key('reader-book-tab-0'));
      await _tap(tester, _key('reader-book-tab-2'));
      expect(_key('reader-book-notes-confirm-delete'), findsOneWidget);
      expect(fixture.detailLoads, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed details keep cached metadata and retry enriches title/author callbacks',
    (tester) async {
      final fixture = _PanelFixture();
      var fail = true;
      fixture.detailLoader = () async {
        if (fail) throw StateError('offline');
        return _detail;
      };
      await fixture.open(tester);
      expect(find.text('缓存书名'), findsOneWidget);
      await _tap(tester, _key('reader-book-author'));
      expect(
        fixture.events,
        isEmpty,
        reason: 'An author name without a real id cannot navigate.',
      );
      await _tap(tester, _key('reader-book-title'));
      expect(fixture.events, ['details']);
      await _tap(tester, _key('reader-book-tab-0'));
      expect(find.text('离线保留的简介'), findsOneWidget);
      expect(find.text('缓存分类'), findsOneWidget);
      expect(find.text('书籍信息暂时无法加载'), findsOneWidget);
      fail = false;
      await _tap(tester, find.text('重试'));
      expect(fixture.detailLoads, 2);
      expect(find.text('完整书名'), findsOneWidget);
      expect(find.text('重新加载后的完整简介'), findsOneWidget);
      expect(find.text('完整分类'), findsOneWidget);
      expect(find.text('书籍信息暂时无法加载'), findsNothing);
      await _tap(tester, _key('reader-book-author'));
      expect(fixture.events.last, same(_author));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'full search, night and settings remain reachable from every tab',
    (tester) async {
      final fixture = _PanelFixture();
      await fixture.open(tester, preset: ReaderThemePreset.dark);
      for (var tab = 0; tab < 3; tab++) {
        await _tap(tester, _key('reader-book-tab-$tab'));
        await _tap(tester, find.byTooltip('全文搜索'));
        await _tap(tester, find.text('日间'));
        await _tap(tester, find.text('设置'));
      }
      expect(fixture.events, [
        'search',
        'night',
        'settings',
        'search',
        'night',
        'settings',
        'search',
        'night',
        'settings',
      ]);
      expect(_key('reader-book-close'), findsNothing);
      final panelTop = tester.getTopLeft(find.byType(ReaderBookPanel));
      await tester.dragFrom(
        panelTop + const Offset(190, 8),
        const Offset(0, 700),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReaderBookPanel), findsNothing);
    },
  );

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets(
      'bounded shell works at ${size.width}x${size.height}, 2x text, keyboard and reduced motion',
      (tester) async {
        final fixture = _PanelFixture();
        await fixture.open(
          tester,
          size: size,
          scale: 2,
          showAi: true,
          preset: ReaderThemePreset.dark,
        );
        await _tap(tester, _key('reader-catalogue-search-toggle'));
        // Simulate the same reduced viewport and keyboard inset as the page route.
        fixture.insets.value = size.height < 400 ? 100 : 220;
        await tester.pumpAndSettle();
        expect(find.text('设置').hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
        for (var tab = 0; tab < 3; tab++) {
          await _tap(tester, _key('reader-book-tab-$tab'));
          expect(tester.takeException(), isNull);
        }
        fixture.insets.value = 0;
        await tester.pumpAndSettle();
        expect(_key('reader-book-ai').hitTestable(), findsOneWidget);
        await _tap(tester, find.byTooltip('全文搜索'));
        expect(fixture.events.last, 'search');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final kind in [
    'paragraph-id',
    'paragraph-ordinal',
    'range-with-replacement',
  ]) {
    testWidgets(
      'real ReaderPage notes navigate across chapters by $kind and highlight exact source',
      (tester) async {
        final bookmarks = _Bookmarks();
        final underlines = _Underlines();
        addTearDown(bookmarks.changes.dispose);
        addTearDown(underlines.changes.dispose);
        final style = AppThemeStyleStore();
        addTearDown(style.dispose);
        await style.select(AppThemeStyle.classic);
        final replacements = TextReplacementStore();
        addTearDown(replacements.dispose);
        final engine = TextReplacementEngine();
        final source = ChapterContent(
          blocks: [
            const ChapterParagraph('短标', paraIndex: 10),
            for (var i = 0; i < 14; i++)
              ChapterParagraph(
                '第 $i 段背景文字，${'山风穿过树林，落叶在脚边发出轻响。' * 8}',
                paraIndex: 20 + i,
              ),
            const ChapterParagraph('我们在这里找到唯一目标选文，故事继续。', paraIndex: 72),
          ],
          illustrationsChecked: true,
        );
        if (kind == 'range-with-replacement') {
          await replacements.save(
            enabled: true,
            rules: [
              TextReplacementRule(
                id: 'expand-prefix',
                pattern: '短标',
                replacement: '展开之后的序章。' * 120,
              ),
            ],
          );
        }
        final originSource = ChapterContent.fromPlainText(
          '起始章的正文。',
          illustrationsChecked: true,
        );
        await tester.runAsync(
          () => engine.transform(
            source: originSource,
            chapterTitle: '起始章',
            snapshot: replacements.snapshot,
          ),
        );
        // Warm the real replacement engine outside fake async, as the reader's
        // existing replacement regressions do, so worker-isolate time is real.
        await tester.runAsync(
          () => engine.transform(
            source: source,
            chapterTitle: '目标章',
            snapshot: replacements.snapshot,
          ),
        );
        final chapters = [
          Chapter(itemId: 'origin', title: '起始章', volumeName: ''),
          Chapter(itemId: 'target', title: '目标章', volumeName: ''),
        ];
        _size(tester, const Size(390, 800));
        await tester.pumpWidget(
          AppUiHost(
            store: style,
            home: ReaderPage(
              bookId: _book.id,
              title: _book.title,
              chapters: chapters,
              startIndex: 1,
              localOnly: true,
              bookDetail: _detail,
              readerDevice: _Device(),
              readerStore: MemoryReaderStore(),
              chapterCache: MemoryChapterCache(),
              bookmarkStore: bookmarks,
              underlineStore: underlines,
              replacementStore: replacements,
              replacementEngine: engine,
              chapterLoader: (chapter) async => chapter.itemId == 'target'
                  ? source.toCacheText()
                  : originSource.toCacheText(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final reference = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .layout;
        final paragraph = reference.blocks.singleWhere(
          (block) => block.paraIndex == 72,
        );
        final start = kind == 'range-with-replacement'
            ? paragraph.start + paragraph.text.indexOf('唯一目标选文')
            : paragraph.start;
        final end = kind == 'range-with-replacement'
            ? start + '唯一目标选文'.length
            : paragraph.end;
        final expectedPage = reference.pageForOffset(start);
        expect(expectedPage, greaterThan(0));
        String recordKey;
        if (kind == 'range-with-replacement') {
          final mark = ReaderRangeUnderline(
            bookId: _book.id,
            chapterId: 'target',
            text: '唯一目标选文',
            start: reference.sourceOffsetForDisplay(start),
            end: reference.sourceOffsetForDisplay(end),
          );
          expect(
            mark.start,
            lessThan(start),
            reason: 'Replacement prefix really shifts display coordinates.',
          );
          underlines.ranges.add(mark);
          recordKey = mark.key;
        } else {
          final mark = ReaderUnderline(
            bookId: _book.id,
            chapterId: 'target',
            text: paragraph.text,
            paraIndex: kind == 'paragraph-id' ? 72 : null,
            blockIndex: kind == 'paragraph-id' ? 999 : paragraph.index - 1,
          );
          underlines.paragraphs.add(mark);
          recordKey = mark.key;
        }
        // Leave the reference chapter through the actual embedded directory.
        await _openReaderPanel(tester);
        await _tap(tester, _key('reader-directory-row-0'));
        final origin = tester.widget<ReaderPagedView>(
          find.byType(ReaderPagedView),
        );
        expect(
          origin.layout.blocks.any((b) => b.text.contains('起始章的正文')),
          isTrue,
        );
        await _openReaderPanel(tester);
        await _tap(tester, _key('reader-book-tab-2'));
        await _tap(tester, _key('reader-book-notes-open-underline:$recordKey'));
        expect(find.byType(ReaderBookPanel), findsNothing);
        final landed = tester.widget<ReaderPagedView>(
          find.byType(ReaderPagedView),
        );
        expect(landed.pageIndex, expectedPage);
        expect(landed.selection?.start, start);
        expect(landed.selection?.end, end);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}

final testerBinding = TestWidgetsFlutterBinding.ensureInitialized();

Future<void> _openReaderPanel(WidgetTester tester) async {
  if (_key('reader-classic-toolbar').evaluate().isEmpty) {
    await tester.tapAt(tester.getRect(_key('reader-page-surface')).center);
    await tester.pumpAndSettle();
  }
  await _tap(tester, _key('reader-catalogue-entry'));
  expect(find.byType(ReaderBookPanel), findsOneWidget);
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
    systemBrightness: .45,
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
