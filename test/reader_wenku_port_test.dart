import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/reader_directory_sheet.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_value_slider.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';

final _chapters = <Chapter>[
  Chapter(itemId: 'one', title: '第一章', volumeName: '卷一'),
  Chapter(itemId: 'two', title: '第二章', volumeName: '卷一'),
];

void main() {
  setUp(() {
    setSingleChapterPrefs({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets(
    'reader-owned panels keep system bars and a bookmark can jump chapters',
    (tester) async {
      await _size(tester);
      final device = _Device();
      final marks = _Bookmarks();
      await marks.add(
        const ReaderBookmark(
          bookId: 'wenku-port',
          chapterId: 'two',
          title: '第二章',
          text: '目标位置',
          sourceOffset: 500,
          createdAt: 1,
        ),
      );
      await tester.pumpWidget(_app(_reader(bookmarks: marks, device: device)));
      await tester.pumpAndSettle();
      await _menu(tester);
      device.immersive.clear();
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      expect(device.immersive, isNotEmpty);
      expect(device.immersive.every((enabled) => enabled), isTrue);
      await tester.tap(find.byKey(const ValueKey('reader-settings-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('reader-bookmark-${marks.entries.single.key}')),
      );
      await tester.pumpAndSettle();
      final pager = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      expect(pager.layout.blocks.first.text, contains('第二章'));
      expect(pager.pageIndex, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets('IME and viewport relayout do not invalidate a chapter search', (
    tester,
  ) async {
    await _size(tester);
    await tester.pumpWidget(_app(_reader()));
    await tester.pumpAndSettle();
    await _menu(tester);
    await tester.tap(find.byKey(const ValueKey('reader-find-entry')));
    await tester.pumpAndSettle();
    // Simulate a geometry change while the input is focused. Search addresses
    // original text, not the old measured-layout object's identity.
    await tester.binding.setSurfaceSize(const Size(420, 720));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-find-field')),
      '唯一目标',
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reader-find-result-0')));
    await tester.pumpAndSettle();
    expect(find.text('正文已更新，请重新查找'), findsNothing);
    expect(
      tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex,
      greaterThan(0),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
    'scroll typography preview retains one source anchor and avoids intermediate saves',
    (tester) async {
      await _size(tester);
      setSingleChapterPrefs({'reader_page_mode': 'scroll'});
      final store = _CountingStore();
      await tester.pumpWidget(_app(_reader(store: store)));
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('reader-paragraph-list')),
      );
      list.controller!.jumpTo(700);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      final anchor = store.entry!['textOffset'] as int;
      await _menu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('reader-settings-category-font')),
      );
      await tester.pumpAndSettle();
      final before = store.writes;
      final slider = tester.widget<ReaderValueSlider>(
        find.ancestor(
          of: find.byKey(const ValueKey('reader-font-size')),
          matching: find.byType(ReaderValueSlider),
        ),
      );
      slider.onInteractionChanged!(true);
      for (final size in [20.0, 25.0, 16.0, 24.0, 18.0]) {
        slider.onPreview!(size);
        await tester.pump(const Duration(milliseconds: 140));
        await tester.pump();
      }
      expect(store.writes, before);
      slider.onCommitted!(18);
      slider.onInteractionChanged!(false);
      await tester.pumpAndSettle();
      expect(store.entry!['textOffset'], anchor);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a newer bookmark selection cancels an older pending chapter change',
    (tester) async {
      await _size(tester);
      final store = _BlockingReaderStore();
      final marks = _Bookmarks();
      const older = ReaderBookmark(
        bookId: 'wenku-port',
        chapterId: 'two',
        title: '第二章',
        text: '旧请求',
        sourceOffset: 400,
        createdAt: 1,
      );
      const newer = ReaderBookmark(
        bookId: 'wenku-port',
        chapterId: 'one',
        title: '第一章',
        text: '新请求',
        sourceOffset: 700,
        createdAt: 2,
      );
      await marks.add(older);
      await marks.add(newer);
      await tester.pumpWidget(_app(_reader(store: store, bookmarks: marks)));
      await tester.pumpAndSettle();
      await _menu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
      await tester.pumpAndSettle();
      final blocked = Completer<void>();
      store.nextWrite = blocked.future;
      await tester.tap(find.byKey(ValueKey('reader-bookmark-${older.key}')));
      await tester.pumpAndSettle();
      await _menu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('reader-bookmark-${newer.key}')));
      await tester.pumpAndSettle();
      blocked.complete();
      await tester.pumpAndSettle();
      final pager = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      expect(pager.layout.blocks.first.text, contains('第一章'));
      expect(
        pager.pageIndex,
        pager.layout.pageForOffset(pager.layout.displayOffsetForSource(700)),
      );
      expect(store.entry?['chapterId'], 'one');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets(
    'directory groups available volumes and search finds collapsed chapters',
    (tester) async {
      await _size(tester);
      await tester.pumpWidget(
        _app(
          ReaderDirectorySheet(
            chapters: [
              Chapter(itemId: 'a', title: '晨光', volumeName: '卷一'),
              Chapter(itemId: 'b', title: '暮色', volumeName: '卷二'),
            ],
            currentIndex: 0,
            cachedIds: const {},
            bookId: 'wenku-directory',
            aiStatuses: const [],
            aiController: AiReadingController.instance,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('晨光'), findsOneWidget);
      expect(find.text('暮色'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-volume-卷二')));
      await tester.pumpAndSettle();
      expect(find.text('暮色'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-volume-卷二')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('reader-catalogue-search-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-chapter-search')),
        '卷二',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('暮色'), findsOneWidget);
      expect(find.text('晨光'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real slider gesture keeps pointer through preview and commits on release',
    (tester) async {
      await _size(tester);
      final store = _CountingStore();
      await tester.pumpWidget(_app(_reader(store: store)));
      await tester.pumpAndSettle();
      await _menu(tester);
      final before = store.writes;
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-chrome-progress-slider')),
      );
      final gesture = await tester.startGesture(
        rect.centerLeft + const Offset(10, 0),
      );
      await tester.pump();
      await gesture.moveTo(rect.centerRight - const Offset(10, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(store.writes, before);
      expect(
        find.byKey(const ValueKey('reader-liquid-dock')).hitTestable(),
        findsNothing,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.writes, greaterThan(before));
      expect(
        find.byKey(const ValueKey('reader-liquid-dock')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(320, 560), const Size(800, 360)]) {
    testWidgets('category layout fits $size with large type', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.6),
              disableAnimations: true,
              highContrast: true,
            ),
            child: PerformanceScope(
              preferences: const PerformancePreferences(enabled: true),
              child: child!,
            ),
          ),
          home: ReaderAppearanceSheet(
            initialValue: const ReaderPreferences(),
            onChanged: (_) {},
            onPickFont: () async => null,
            deviceAvailable: false,
            systemBrightness: null,
            onBrightness: (_) {},
            onBrightnessEnd: () {},
            onFollowSystem: () {},
            autoTurnActive: false,
            onAutoTurn: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey('reader-settings-category-font')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'six dock actions are real and the appearance scope is a category grid',
    (tester) async {
      await _size(tester);
      await tester.pumpWidget(_app(_reader()));
      await tester.pumpAndSettle();
      await _menu(tester);
      for (final key in [
        'reader-catalogue-entry',
        'reader-bookmarks-entry',
        'reader-settings',
        'reader-operations-entry',
        'reader-find-entry',
        'reader-night-entry',
      ]) {
        expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-settings-category-grid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-settings-category-font')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-settings-category-theme')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('reader-settings-category-font')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-font-size')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-settings-category-grid')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'chapter scrub previews without crossing chapters or writing intermediate history',
    (tester) async {
      await _size(tester);
      final store = _CountingStore();
      await tester.pumpWidget(_app(_reader(store: store)));
      await tester.pumpAndSettle();
      await _menu(tester);
      final before = store.writes;
      var control = tester.widget<ReaderControls>(find.byType(ReaderControls));
      control.onPreviewChanged(true);
      control.onPreview(.6);
      await tester.pump();
      await tester.pump();
      expect(store.writes, before);
      expect(
        tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex,
        greaterThan(0),
      );
      control = tester.widget<ReaderControls>(find.byType(ReaderControls));
      control.onCommitted(1);
      await tester.pumpAndSettle();
      expect(store.entry?['chapterId'], 'one');
      expect(store.entry?['episode'], 0);
      expect(store.writes, greaterThan(before));
      final pager = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      expect(pager.pageIndex, pager.layout.pages.length - 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'search result lands on the matching page and local bookmark returns there',
    (tester) async {
      await _size(tester);
      final marks = _Bookmarks();
      await tester.pumpWidget(_app(_reader(bookmarks: marks)));
      await tester.pumpAndSettle();
      await _menu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-find-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '唯一目标',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('reader-find-result-0')));
      await tester.pumpAndSettle();
      final page = tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .pageIndex;
      expect(page, greaterThan(0));
      await _menu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
      await tester.pumpAndSettle();
      expect(marks.entries, hasLength(1));
      expect(marks.entries.single.sourceOffset, greaterThan(0));
      await tester.tap(
        find.byKey(ValueKey('reader-bookmark-${marks.entries.single.key}')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex,
        page,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets('bookmarking the chapter top saves body text, not the title', (
    tester,
  ) async {
    await _size(tester);
    final marks = _Bookmarks();
    await tester.pumpWidget(_app(_reader(bookmarks: marks)));
    await tester.pumpAndSettle();
    await _menu(tester);
    await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
    await tester.pumpAndSettle();
    expect(marks.entries, hasLength(1));
    final mark = marks.entries.single;
    expect(mark.title, '第一章');
    expect(mark.text, isNot('第一章'));
    expect(mark.text, contains('这是第0段的正文'));
    expect(mark.sourceOffset, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
    'typography preview hides only paint and persists final value on nested back',
    (tester) async {
      await _size(tester);
      final changes = <ReaderPreferences>[];
      final previews = <bool>[];
      await tester.pumpWidget(
        _app(
          ReaderAppearanceSheet(
            initialValue: const ReaderPreferences(),
            onChanged: changes.add,
            onPickFont: () async => null,
            deviceAvailable: true,
            systemBrightness: .4,
            onBrightness: (_) {},
            onBrightnessEnd: () {},
            onFollowSystem: () {},
            autoTurnActive: false,
            onAutoTurn: () {},
            onPreviewChanged: previews.add,
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('reader-settings-category-font')),
      );
      await tester.pumpAndSettle();
      final slider = tester.widget<ReaderValueSlider>(
        find.byType(ReaderValueSlider).first,
      );
      final sliderRect = tester.getRect(
        find.byKey(const ValueKey('reader-font-size')),
      );
      slider.onInteractionChanged!(true);
      slider.onPreview!(23);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.getRect(find.byKey(const ValueKey('reader-font-size'))),
        sliderRect,
      );
      expect(
        find.byKey(const ValueKey('reader-settings-close')).hitTestable(),
        findsNothing,
      );
      expect(changes.last.fontSize, 23);
      slider.onCommitted!(24);
      slider.onInteractionChanged!(false);
      await tester.pumpAndSettle();
      expect(changes.last.fontSize, 24);
      expect(previews, [true, false]);
      expect(
        find.byKey(const ValueKey('reader-settings-close')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('chapter scrub uses current chapter bounds in joined scrolling', (
    tester,
  ) async {
    await _size(tester);
    setSingleChapterPrefs({
      'reader_page_mode': 'scroll',
      'reader_scroll_chapter_mode': 'joined',
    });
    final store = _CountingStore();
    await tester.pumpWidget(_app(_reader(store: store)));
    await tester.pumpAndSettle();
    await _menu(tester);
    final controls = tester.widget<ReaderControls>(find.byType(ReaderControls));
    controls.onPreviewChanged(true);
    controls.onPreview(1);
    await tester.pump();
    await tester.pump();
    controls.onCommitted(1);
    await tester.pumpAndSettle();
    expect(store.entry?['chapterId'], 'one');
    expect(store.entry?['episode'], 0);
    expect(store.entry?['position'], greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _size(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _menu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
}

Widget _app(Widget child) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, highContrast: true),
    child: PerformanceScope(
      preferences: const PerformancePreferences(enabled: true),
      child: child!,
    ),
  ),
  home: child,
);

ReaderPage _reader({
  MemoryReaderStore? store,
  ReaderBookmarkStore? bookmarks,
  _Device? device,
}) => ReaderPage(
  bookId: 'wenku-port',
  title: '阅读移植回归',
  chapters: _chapters,
  startIndex: 0,
  localOnly: true,
  readerStore: store ?? MemoryReaderStore(),
  bookmarkStore: bookmarks,
  readerDevice: device ?? _Device(),
  chapterCache: MemoryChapterCache(),
  chapterLoader: (_) async => List.generate(
    60,
    (i) => '这是第$i段的正文。山间的风越过窗台，书页随着阳光缓缓翻开。${i == 40 ? '唯一目标就在这里。' : ''}',
  ).join('\n\n'),
);

class _Device extends ReaderDevice {
  final immersive = <bool>[];
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
  }) async {
    immersive.add(enabled);
  }

  @override
  Future<void> close() async {}
}

class _CountingStore extends MemoryReaderStore {
  int writes = 0;
  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    writes++;
    await super.addHistory(value);
  }
}

class _BlockingReaderStore extends MemoryReaderStore {
  Future<void>? nextWrite;
  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    final pending = nextWrite;
    nextWrite = null;
    await pending;
    await super.addHistory(value);
  }
}

class _Bookmarks extends ReaderBookmarkStore {
  final entries = <ReaderBookmark>[];
  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async =>
      entries.where((m) => m.bookId == bookId).toList();
  @override
  Future<void> add(ReaderBookmark mark) async {
    entries.removeWhere((m) => m.key == mark.key);
    entries.add(mark);
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    entries.removeWhere((m) => m.key == key);
    changes.value++;
  }
}
