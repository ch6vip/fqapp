import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

const _bookId = 'bookmark-ribbon-reader';
const _ribbon = ValueKey('reader-bookmark-saved-ribbon');
final _chapters = List.generate(
  3,
  (i) =>
      Chapter(itemId: 'ribbon-chapter-$i', title: '第 $i 章', volumeName: '正文'),
);

String _text(Chapter chapter) => List.generate(
  65,
  (i) => '${chapter.title} 第 $i 段。清晨的风从窗边吹来，带着山间草木的清香。',
).join('\n\n');

ReaderBookmark _mark(int offset, {int chapter = 0}) => ReaderBookmark(
  bookId: _bookId,
  chapterId: _chapters[chapter].itemId,
  title: _chapters[chapter].title,
  text: '已保存的正文位置',
  sourceOffset: offset,
  createdAt: 123,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Bookmarks bookmarks;
  late ReaderBookmarkStore persisted;
  late AppThemeStyleStore style;
  late bool previousHiveReady;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    directory = await Directory.systemTemp.createTemp('fqapp-ribbon-reader-');
    Hive.init(directory.path);
    await EncryptedHive.openBox<dynamic>(
      Hive,
      'reader_bookmarks_v1',
      keys: SecureKeyProvider(storage: InMemorySecureKeyStorage()),
    );
    previousHiveReady = ReaderBookmarkStore.hiveReady;
    ReaderBookmarkStore.hiveReady = true;
    persisted = ReaderBookmarkStore(hive: Hive);
    bookmarks = _Bookmarks();
    style = AppThemeStyleStore();
    await style.select(AppThemeStyle.classic);
  });

  tearDown(() async {
    bookmarks.changes.dispose();
    persisted.changes.dispose();
    style.dispose();
    ReaderBookmarkStore.hiveReady = previousHiveReady;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'encrypted store persists anchors and notifies additions and deletions',
    () async {
      final mark = _mark(25);
      await persisted.add(mark);
      final reopened = ReaderBookmarkStore(hive: Hive);
      try {
        expect((await reopened.loadBook(_bookId)).single.toMap(), mark.toMap());
        expect(persisted.changes.value, 1);
        await persisted.remove(mark.key);
        expect(await reopened.loadBook(_bookId), isEmpty);
        expect(persisted.changes.value, 2);
      } finally {
        reopened.changes.dispose();
      }
    },
  );

  testWidgets(
    'saved ribbon enters and leaves scrolling viewport and tracks deletion',
    (tester) async {
      await _mount(tester, style, bookmarks, mode: 'scroll');
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('reader-paragraph-list')),
      );
      final controller = list.controller!;
      final rendered = tester
          .widgetList<ReaderBlockContent>(find.byType(ReaderBlockContent))
          .first;
      final layout = ReaderChapterLayout(
        title: _chapters[0].title,
        content: ChapterContent.fromCacheText(_text(_chapters[0])),
        spec: rendered.spec,
      );
      final block = layout.blocks[25];
      final line = block.lines.first;
      final top = layout.spec.verticalPadding + block.top + line.top;
      final bottom = top + line.height;
      final mark = _mark(
        layout.sourceOffsetForDisplay(block.start + line.start),
      );
      expect(top, greaterThan(controller.position.viewportDimension * 2));
      await bookmarks.add(mark);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsNothing);

      // Only scrolling changes here: no menu or parent rebuild should be needed.
      controller.jumpTo(top - controller.position.viewportDimension - 1);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsNothing);
      controller.jumpTo(top - controller.position.viewportDimension + 1);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsOneWidget);

      // A partially clipped first line is still visible and remains bookmarked.
      controller.jumpTo(top + line.height / 2);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsOneWidget);
      controller.jumpTo(bottom + 1);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsNothing);
      controller.jumpTo(top - 1);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsOneWidget);

      await bookmarks.remove(mark.key);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsNothing);
      expect(await bookmarks.loadBook(_bookId), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'paged reader loads stored bookmark and updates ribbon on page turns',
    (tester) async {
      final mark = _mark(0);
      await bookmarks.add(mark);
      await _mount(tester, style, bookmarks, mode: 'paged');
      final pager = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      expect(pager.layout.pages.length, greaterThan(2));
      expect(pager.pageIndex, 0);
      expect(_visibleRibbons(tester), hasLength(1));
      expect((await bookmarks.loadBook(_bookId)).single.key, mark.key);

      await tester.drag(find.byType(PageView), const Offset(-310, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex,
        1,
      );
      expect(_visibleRibbons(tester), isEmpty);
      await tester.drag(find.byType(PageView), const Offset(310, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex,
        0,
      );
      expect(_visibleRibbons(tester), hasLength(1));

      await bookmarks.remove(mark.key);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'pull toggles the visible saved page and retains other pages and chapters',
    (tester) async {
      await _mount(tester, style, bookmarks, mode: 'paged');
      final pager = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      final layout = pager.layout;
      expect(layout.pages.length, greaterThan(2));
      final nextPage = _mark(
        layout.sourceOffsetForDisplay(layout.pages[1].start),
      );
      final otherChapter = _mark(0, chapter: 1);
      await bookmarks.add(nextPage);
      await bookmarks.add(otherChapter);
      await tester.pumpAndSettle();
      expect(_visibleRibbons(tester), isEmpty);

      await _pull(tester, '添加');
      expect(find.text('已添加书签'), findsOneWidget);
      expect(_visibleRibbons(tester), hasLength(1));
      final added = (await bookmarks.loadBook(_bookId)).singleWhere(
        (mark) =>
            mark.chapterId == _chapters[0].itemId && mark.key != nextPage.key,
      );
      final extra = _mark(
        layout.sourceOffsetForDisplay(
          layout.pages[0].fragments
                  .firstWhere((fragment) => !fragment.block.isTitle)
                  .start +
              1,
        ),
      );
      expect(extra.key, isNot(added.key));
      await bookmarks.add(extra);
      await tester.pumpAndSettle();
      expect(
        layout.pageForOffset(layout.displayOffsetForSource(extra.sourceOffset)),
        0,
      );

      await _pull(tester, '删除');
      expect(find.text('删除书签成功'), findsOneWidget);
      expect(find.text('已添加书签'), findsNothing);
      expect(_visibleRibbons(tester), isEmpty);
      expect(
        (await bookmarks.loadBook(_bookId)).map((mark) => mark.key),
        unorderedEquals([nextPage.key, otherChapter.key]),
      );
      expect(bookmarks.removedKeys, unorderedEquals([added.key, extra.key]));

      // A fresh gesture must show addition again after the store notification.
      await _pull(tester, '添加');
      expect(find.text('已添加书签'), findsOneWidget);
      expect(_visibleRibbons(tester), hasLength(1));
      await tester.drag(find.byType(PageView), const Offset(-310, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex,
        1,
      );
      expect(_visibleRibbons(tester), hasLength(1));
      expect(
        (await bookmarks.loadBook(_bookId)).map((mark) => mark.key),
        containsAll([nextPage.key, otherChapter.key]),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a page turn during deletion cannot redirect the captured bookmark batch',
    (tester) async {
      await _mount(tester, style, bookmarks, mode: 'paged');
      final layout = tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .layout;
      final first = _mark(0);
      final second = _mark(
        layout.sourceOffsetForDisplay(
          layout.pages[0].fragments
                  .firstWhere((fragment) => !fragment.block.isTitle)
                  .start +
              1,
        ),
      );
      final nextPage = _mark(
        layout.sourceOffsetForDisplay(layout.pages[1].start),
      );
      final otherChapter = _mark(0, chapter: 2);
      for (final mark in [first, second, nextPage, otherChapter]) {
        await bookmarks.add(mark);
      }
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      bookmarks.removeGate = gate.future;
      await _pull(tester, '删除');
      expect(bookmarks.removedKeys, [first.key]);
      await tester.drag(find.byType(PageView), const Offset(-310, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex,
        1,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(bookmarks.removedKeys, [first.key, second.key]);
      expect(
        (await bookmarks.loadBook(_bookId)).map((mark) => mark.key),
        unorderedEquals([nextPage.key, otherChapter.key]),
      );
      expect(_visibleRibbons(tester), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final operation in ['添加', '删除']) {
    testWidgets(
      'failed pull $operation keeps stored state and never reports success',
      (tester) async {
        final mark = _mark(0);
        if (operation == '删除') await bookmarks.add(mark);
        await _mount(tester, style, bookmarks, mode: 'paged');
        bookmarks.failAdd = operation == '添加';
        bookmarks.failRemove = operation == '删除';
        await _pull(tester, operation);
        expect(
          find.text(operation == '添加' ? '书签保存失败，请重试' : '书签删除失败，请重试'),
          findsOneWidget,
        );
        expect(find.text('已添加书签'), findsNothing);
        expect(find.text('删除书签成功'), findsNothing);
        expect(
          _visibleRibbons(tester),
          operation == '添加' ? isEmpty : hasLength(1),
        );
        expect(
          (await bookmarks.loadBook(_bookId)).map((mark) => mark.key),
          operation == '添加' ? isEmpty : orderedEquals([mark.key]),
        );
        bookmarks.failAdd = false;
        bookmarks.failRemove = false;
        await _pull(tester, operation);
        expect(
          find.text(operation == '添加' ? '已添加书签' : '删除书签成功'),
          findsOneWidget,
        );
        expect(
          _visibleRibbons(tester),
          operation == '添加' ? hasLength(1) : isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'joined reader uses chapter-local viewport after previous chapter preload',
    (tester) async {
      await _mount(
        tester,
        style,
        bookmarks,
        mode: 'scroll',
        joined: true,
        index: 1,
      );
      final joined = tester.state<ReaderJoinedScrollState>(
        find.byType(ReaderJoinedScroll),
      );
      final widget = tester.widget<ReaderJoinedScroll>(
        find.byType(ReaderJoinedScroll),
      );
      final layout = joined.chapterAt(1)!.layout;
      final block = layout.blocks[5];
      final line = block.lines.first;
      final top = layout.spec.verticalPadding + block.top + line.top;
      final mark = _mark(
        layout.sourceOffsetForDisplay(block.start + line.start),
        chapter: 1,
      );
      expect(joined.chapterStart(1), greaterThan(layout.spec.viewport.height));
      await bookmarks.add(mark);
      await tester.pumpAndSettle();

      joined.jumpToChapterOffset(1, top + line.height / 2);
      await tester.pumpAndSettle();
      expect(joined.position!.index, 1);
      expect(joined.position!.scroll, closeTo(top + line.height / 2, .01));
      expect(
        widget.controller.offset,
        greaterThan(top + layout.spec.viewport.height),
      );
      expect(find.byKey(_ribbon), findsOneWidget);

      joined.jumpToChapterOffset(1, top + line.height + 1);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsNothing);
      joined.jumpToChapterOffset(1, top - 1);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsOneWidget);
      await bookmarks.remove(mark.key);
      await tester.pumpAndSettle();
      expect(find.byKey(_ribbon), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

Future<void> _pull(WidgetTester tester, String operation) async {
  final surface = find.byKey(const ValueKey('reader-page-surface'));
  final gesture = await tester.startGesture(tester.getRect(surface).center);
  // The first move resolves Flutter's drag arena; subsequent deltas pull.
  await gesture.moveBy(const Offset(0, 20));
  await gesture.moveBy(const Offset(0, 50));
  await tester.pump();
  expect(find.text('下拉$operation书签'), findsOneWidget);
  await gesture.moveBy(const Offset(0, 100));
  await tester.pump();
  expect(find.text('松手$operation书签'), findsOneWidget);
  await gesture.up();
  await tester.pumpAndSettle();
}

/// PageView keeps adjacent pages mounted. A saved mark only counts when its
/// actual painted rectangle is inside the current reader viewport.
List<Rect> _visibleRibbons(WidgetTester tester) {
  final viewport = tester.getRect(
    find.byKey(const ValueKey('reader-page-surface')),
  );
  return [
    for (final element in find.byKey(_ribbon).evaluate())
      tester.getRect(
        find.byElementPredicate((candidate) => identical(candidate, element)),
      ),
  ].where((rect) => viewport.contains(rect.center)).toList();
}

Future<void> _mount(
  WidgetTester tester,
  AppThemeStyleStore style,
  ReaderBookmarkStore bookmarks, {
  required String mode,
  bool joined = false,
  int index = 0,
}) async {
  SharedPreferences.setMockInitialValues({
    'reader_page_mode': mode,
    'reader_page_turn_style': 'slide',
    'reader_scroll_chapter_mode': joined ? 'joined' : 'replace',
    'reader_follow_system_brightness': false,
    'reader_keep_screen_on': false,
    'reader_volume_key_turn': false,
  });
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppUiHost(
      store: style,
      home: ReaderPage(
        bookId: _bookId,
        title: '书签丝带验收',
        chapters: _chapters,
        startIndex: index,
        localOnly: true,
        bookmarkStore: bookmarks,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        readerDevice: _Device(),
        chapterLoader: (chapter) async => _text(chapter),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Deterministic widget-time storage; the real encrypted store is exercised
/// separately because its write queue must not cross fake/real async zones.
class _Bookmarks extends ReaderBookmarkStore {
  final _records = <String, ReaderBookmark>{};
  final removedKeys = <String>[];
  bool failAdd = false;
  bool failRemove = false;
  Future<void>? removeGate;

  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async =>
      _records.values.where((mark) => mark.bookId == bookId).toList();

  @override
  Future<void> add(ReaderBookmark record) async {
    if (failAdd) throw StateError('add failed');
    _records[record.key] = record;
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    removedKeys.add(key);
    if (failRemove) throw StateError('remove failed');
    if (removeGate != null) await removeGate;
    if (_records.remove(key) != null) changes.value++;
  }
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();

  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(time: DateTime(2026, 10, 30, 9), battery: 80);

  @override
  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async => true;

  @override
  Future<void> suspend() async {}

  @override
  Future<void> close() async {}
}
