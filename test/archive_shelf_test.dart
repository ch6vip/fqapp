import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/shelf/shelf_cover_image.dart';
import 'package:fqapp/widgets/wenku/archive_shelf.dart';
import 'package:fqapp/widgets/wenku/src/archive_shelf_entry.dart';
import 'package:fqapp/widgets/wenku/src/performance_preferences.dart';

ArchiveShelfEntry _entry(
  String id, {
  String? title,
  String chapterLabel = '',
  bool read = false,
  bool finished = false,
  double? fraction,
  int? totalChapters,
  String kind = 'book',
  String ep = '',
}) => ArchiveShelfEntry(
  item: MediaItem(
    id: id,
    title: title ?? '书$id',
    cover: '',
    author: '作者$id',
    badge: '',
    ep: ep,
    kind: kind,
  ),
  read: read,
  finished: finished,
  fraction: fraction,
  chapterLabel: chapterLabel.isEmpty ? null : chapterLabel,
  totalChapters: totalChapters,
);

Widget _app(
  Widget child, {
  bool disableAnimations = false,
  PerformancePreferences? preferences,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: Scaffold(
        body: SingleChildScrollView(
          child: preferences == null
              ? child
              : PerformanceScope(preferences: preferences, child: child),
        ),
      ),
    ),
  ),
);

Future<void> _setSurface(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

IconButton _iconButton(WidgetTester tester, IconData icon) =>
    tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byIcon(icon),
            matching: find.byWidgetPredicate((widget) => widget is IconButton),
          )
          .first,
    );

void _tapCover(WidgetTester tester, int slot) {
  final ink = tester
      .widgetList<InkWell>(
        find.descendant(
          of: find.byKey(ValueKey('archive-cover-$slot')),
          matching: find.byType(InkWell),
        ),
      )
      .first;
  ink.onTap!();
}

void main() {
  testWidgets('空表不渲染滚动条', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: const [],
          directReading: false,
          onOpen: (_) => opened = true,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('archive-file-carousel')), findsNothing);
    expect(find.byType(ArchiveFileCarousel), findsOneWidget);
    expect(opened, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单本使用不可拖动物理', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [_entry('a')],
          directReading: false,
          onOpen: (_) {},
        ),
      ),
    );
    final scrollable = tester.widget<Scrollable>(
      find.byKey(const ValueKey('archive-file-carousel')),
    );
    expect(scrollable.physics, isA<NeverScrollableScrollPhysics>());
  });

  testWidgets('520dp 宽度、30 本时池大小 64', (tester) async {
    await _setSurface(tester, const Size(520, 900));
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [for (var i = 0; i < 30; i++) _entry('$i')],
          directReading: false,
          onOpen: (_) {},
        ),
      ),
    );
    final state = tester.state<ArchiveFileCarouselState>(
      find.byType(ArchiveFileCarousel),
    );
    expect(state.debugPoolCount, 64);
  });

  testWidgets('repeatFill=false 时两端箭头按位置禁用', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final entries = [_entry('a'), _entry('b'), _entry('c')];

    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: entries,
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
          initialIndex: 0,
          animateEntrance: false,
        ),
        disableAnimations: true,
      ),
    );
    expect(_iconButton(tester, CupertinoIcons.chevron_left).onPressed, isNull);
    expect(
      _iconButton(tester, CupertinoIcons.chevron_right).onPressed,
      isNotNull,
    );
  });

  testWidgets('repeatFill=false 时最后一本禁用下一箭头', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final entries = [_entry('a'), _entry('b'), _entry('c')];
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: entries,
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
          initialIndex: 2,
          animateEntrance: false,
        ),
        disableAnimations: true,
      ),
    );
    expect(
      _iconButton(tester, CupertinoIcons.chevron_left).onPressed,
      isNotNull,
    );
    expect(_iconButton(tester, CupertinoIcons.chevron_right).onPressed, isNull);
  });

  testWidgets('shelf3d=false 使用平面轮播', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [_entry('a'), _entry('b')],
          directReading: false,
          onOpen: (_) {},
        ),
        preferences: const PerformancePreferences(enabled: true),
      ),
    );
    expect(find.byKey(const ValueKey('archive-flat-carousel')), findsOneWidget);
    expect(find.byKey(const ValueKey('archive-file-carousel')), findsNothing);
  });

  testWidgets('TickerMode 关闭时入场直接完成，切回不重播', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final entries = [_entry('a'), _entry('b')];

    Widget host({required bool enabled}) => _app(
      TickerMode(
        enabled: enabled,
        child: ArchiveFileCarousel(
          entries: entries,
          directReading: false,
          onOpen: (_) {},
          animateEntrance: true,
        ),
      ),
    );

    await tester.pumpWidget(host(enabled: false));
    final state = tester.state<ArchiveFileCarouselState>(
      find.byType(ArchiveFileCarousel),
    );
    expect(state.entranceCompleted, isTrue);

    await tester.pumpWidget(host(enabled: true));
    expect(state.entranceCompleted, isTrue);
    expect(state.debugEntranceClock.value, 1);
  });

  testWidgets('入场动画 520ms', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [_entry('a'), _entry('b')],
          directReading: false,
          onOpen: (_) {},
          animateEntrance: true,
        ),
      ),
    );
    final state = tester.state<ArchiveFileCarouselState>(
      find.byType(ArchiveFileCarousel),
    );
    expect(state.entranceCompleted, isFalse);
    await tester.pump(const Duration(milliseconds: 260));
    expect(state.debugEntranceClock.value, greaterThan(0));
    expect(state.debugEntranceClock.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.entranceCompleted, isTrue);
  });

  testWidgets('reorder 后按 identity 保持焦点', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final a = _entry('a');
    final b = _entry('b');
    final c = _entry('c');

    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [a, b, c],
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
          initialIndex: 1,
        ),
        disableAnimations: true,
      ),
    );
    final state = tester.state<ArchiveFileCarouselState>(
      find.byType(ArchiveFileCarousel),
    );
    expect(state.focusedIdentity, 'book:b');

    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [c, a, b],
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
          initialIndex: 0,
        ),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    expect(state.focusedIdentity, 'book:b');
    expect(state.debugCentreSlot, 2);
  });

  testWidgets('repeatFill=false 从 2 本增长到 30 本仍保持焦点', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final a = _entry('a');
    final b = _entry('b');

    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [a, b],
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
          initialIndex: 1,
        ),
        disableAnimations: true,
      ),
    );
    final state = tester.state<ArchiveFileCarouselState>(
      find.byType(ArchiveFileCarousel),
    );
    expect(state.focusedIdentity, 'book:b');

    final grown = [for (var i = 0; i < 30; i++) i == 15 ? b : _entry('x$i')];
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: grown,
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
          initialIndex: 0,
        ),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    expect(state.focusedIdentity, 'book:b');
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑态 interactive=false 禁止拖动且点按直接打开条目', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final entries = [_entry('a'), _entry('b'), _entry('c')];
    ArchiveShelfEntry? opened;

    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: entries,
          directReading: false,
          onOpen: (entry) => opened = entry,
          repeatFill: false,
          interactive: false,
          selecting: true,
          selected: const {'book:b'},
        ),
        disableAnimations: true,
      ),
    );
    final scrollable = tester.widget<Scrollable>(
      find.byKey(const ValueKey('archive-file-carousel')),
    );
    expect(scrollable.physics, isA<NeverScrollableScrollPhysics>());

    _tapCover(tester, 1);
    await tester.pump();
    expect(opened?.identity, 'book:b');
  });

  testWidgets('非编辑态点按非中心条目先居中而不打开', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final entries = [_entry('a'), _entry('b'), _entry('c')];
    ArchiveShelfEntry? opened;

    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: entries,
          directReading: false,
          onOpen: (entry) => opened = entry,
          repeatFill: false,
        ),
        disableAnimations: true,
      ),
    );
    _tapCover(tester, 1);
    await tester.pump();
    expect(opened, isNull);
    final state = tester.state<ArchiveFileCarouselState>(
      find.byType(ArchiveFileCarousel),
    );
    expect(state.debugCentreSlot, 1);
  });

  testWidgets('窄屏说明行显示 detailLine（阅读进度）', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    final entries = [
      _entry('a'),
      _entry('b', chapterLabel: '第2章 · 共9章', read: true),
    ];
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: entries,
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
          initialIndex: 1,
        ),
        disableAnimations: true,
      ),
    );
    expect(find.text('第2章 · 共9章'), findsOneWidget);
  });

  testWidgets('宽屏 880dp 显示信息栏与整书进度', (tester) async {
    await _setSurface(tester, const Size(1000, 800));
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [
            _entry(
              'a',
              read: true,
              fraction: .42,
              chapterLabel: '第4章 · 共9章',
              totalChapters: 9,
            ),
            _entry('b'),
          ],
          directReading: false,
          onOpen: (_) {},
        ),
        disableAnimations: true,
      ),
    );
    expect(find.byKey(const ValueKey('archive-shelf-wide')), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('archive-shelf-wide')),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(bar.value, .42);
    expect(find.text('第4章 · 共9章'), findsOneWidget);
  });

  testWidgets('封面只在焦点 ±1 挂载', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [for (var i = 0; i < 5; i++) _entry('$i')],
          directReading: false,
          onOpen: (_) {},
          repeatFill: false,
        ),
        disableAnimations: true,
      ),
    );
    expect(find.byType(ShelfCoverImage), findsNWidgets(2));
  });

  testWidgets('lane 超过条目数后仍按取模显示序号', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [_entry('a'), _entry('b'), _entry('c')],
          directReading: false,
          onOpen: (_) {},
        ),
        disableAnimations: true,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byIcon(CupertinoIcons.chevron_right));
      await tester.pump();
    }
    final state = tester.state<ArchiveFileCarouselState>(
      find.byType(ArchiveFileCarousel),
    );
    expect(state.debugFocus, 5);
    expect(find.text('03 / 03'), findsOneWidget);
  });

  testWidgets('投影顶面长按也进入编辑态', (tester) async {
    await _setSurface(tester, const Size(400, 800));
    ArchiveShelfEntry? longPressed;
    await tester.pumpWidget(
      _app(
        ArchiveFileCarousel(
          entries: [_entry('a')],
          directReading: false,
          onOpen: (_) {},
          onLongPress: (entry) => longPressed = entry,
          repeatFill: false,
        ),
        disableAnimations: true,
      ),
    );
    final box = tester.renderObject<ArchiveBoxDepthRender>(
      find.byKey(const ValueKey('archive-slot-0')),
    );
    await tester.longPressAt(box.localToGlobal(box.debugCapCentre));
    await tester.pump();
    expect(longPressed?.identity, 'book:a');
  });
}
