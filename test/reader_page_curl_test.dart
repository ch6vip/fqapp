import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_page_curl.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderPageCurlGeometry', () {
    const size = Size(400, 800);

    test('forward fold travels right to left with progress', () {
      final start = ReaderPageCurlGeometry(
        size: size,
        progress: 0,
        forward: true,
      );
      final mid = ReaderPageCurlGeometry(
        size: size,
        progress: 0.5,
        forward: true,
      );
      final end = ReaderPageCurlGeometry(
        size: size,
        progress: 1,
        forward: true,
      );
      expect(start.foldBottom.dx, moreOrLessEquals(400));
      expect(mid.foldBottom.dx, moreOrLessEquals(200));
      expect(end.foldBottom.dx, moreOrLessEquals(0));
    });

    test('backward fold travels left to right with progress', () {
      final start = ReaderPageCurlGeometry(
        size: size,
        progress: 0,
        forward: false,
      );
      final end = ReaderPageCurlGeometry(
        size: size,
        progress: 1,
        forward: false,
      );
      expect(start.foldBottom.dx, moreOrLessEquals(0));
      expect(end.foldBottom.dx, moreOrLessEquals(400));
    });

    test('fold is vertical at the ends, tilted mid-turn', () {
      final start = ReaderPageCurlGeometry(
        size: size,
        progress: 0,
        forward: true,
      );
      final mid = ReaderPageCurlGeometry(
        size: size,
        progress: 0.5,
        forward: true,
      );
      expect(start.foldTop.dx, moreOrLessEquals(start.foldBottom.dx));
      expect(mid.foldTop.dx, greaterThan(mid.foldBottom.dx));
    });

    test('reflection fixes the fold line', () {
      for (final forward in [true, false]) {
        final geo = ReaderPageCurlGeometry(
          size: size,
          progress: 0.5,
          forward: forward,
        );
        final top = MatrixUtils.transformPoint(geo.reflection, geo.foldTop);
        final bottom = MatrixUtils.transformPoint(
          geo.reflection,
          geo.foldBottom,
        );
        expect(top.dx, moreOrLessEquals(geo.foldTop.dx, epsilon: 0.5));
        expect(top.dy, moreOrLessEquals(geo.foldTop.dy, epsilon: 0.5));
        expect(bottom.dx, moreOrLessEquals(geo.foldBottom.dx, epsilon: 0.5));
        expect(bottom.dy, moreOrLessEquals(geo.foldBottom.dy, epsilon: 0.5));
      }
    });

    test('reflection swaps the two sides of the fold', () {
      final geo = ReaderPageCurlGeometry(
        size: size,
        progress: 0.5,
        forward: true,
      );
      // A point on the flap side of the (tilted) fold lands on the visible
      // side after reflection: the signed distance to the fold line flips.
      double side(Offset point) {
        final d = geo.foldTop - geo.foldBottom;
        return (point.dx - geo.foldBottom.dx) * d.dy -
            (point.dy - geo.foldBottom.dy) * d.dx;
      }

      final flapPoint = Offset(geo.foldBottom.dx + 50, 400);
      expect(side(flapPoint), greaterThan(0));
      final mirrored = MatrixUtils.transformPoint(geo.reflection, flapPoint);
      expect(side(mirrored), lessThan(0));
    });

    test('progress clamps to 0..1', () {
      final under = ReaderPageCurlGeometry(
        size: size,
        progress: -0.5,
        forward: true,
      );
      final over = ReaderPageCurlGeometry(
        size: size,
        progress: 1.5,
        forward: true,
      );
      expect(under.foldBottom.dx, moreOrLessEquals(400));
      expect(over.foldBottom.dx, moreOrLessEquals(0));
    });
  });

  group('ReaderPageCurl widget', () {
    for (final forward in [true, false]) {
      for (final progress in [0.0, 0.5, 1.0]) {
        testWidgets(
          'renders at progress $progress forward=$forward',
          (tester) async {
            await tester.pumpWidget(
              MaterialApp(
                home: SizedBox(
                  width: 400,
                  height: 800,
                  child: ReaderPageCurl(
                    outgoing: const ColoredBox(
                      color: Colors.white,
                      child: Text('outgoing'),
                    ),
                    incoming: const ColoredBox(
                      color: Colors.grey,
                      child: Text('incoming'),
                    ),
                    progress: progress,
                    forward: forward,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  test('curl style persists through preferences', () async {
    SharedPreferences.setMockInitialValues({
      'reader_page_turn_style': 'curl',
    });
    final loaded = await ReaderPreferences.load();
    expect(loaded.pageTurnStyle, ReaderPageTurnStyle.curl);
  });

  group('ReaderPagedView with curl', () {
    Future<ReaderPagedViewState> pumpPaged(
      WidgetTester tester, {
      required List<int> pages,
      required List<int> boundaries,
      bool tapTurns = false,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<ReaderPagedViewState>();
      final layout = _twoPageLayout();
      var pageIndex = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: tapTurns
                    ? (details) => unawaited(
                        key.currentState!.turnPage(
                          details.localPosition.dx < 200 ? -1 : 1,
                        ),
                      )
                    : null,
                child: ReaderPagedView(
                  key: key,
                  layout: layout,
                  pageIndex: pageIndex,
                  hasPreviousChapter: false,
                  hasNextChapter: true,
                  onPageChanged: (index) {
                    pages.add(index);
                    setState(() => pageIndex = index);
                  },
                  onBoundary: (direction) async => boundaries.add(direction),
                  onDragStart: () {},
                  turnStyle: ReaderPageTurnStyle.curl,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return key.currentState!;
    }

    testWidgets('turnPage curls to the next page', (tester) async {
      final pages = <int>[];
      final boundaries = <int>[];
      final state = await pumpPaged(
        tester,
        pages: pages,
        boundaries: boundaries,
      );
      expect(state, isNotNull);
      // turnPage awaits the curl animation, which only advances on pumps:
      // start it without awaiting, then settle.
      unawaited(state.turnPage(1));
      await tester.pumpAndSettle();
      expect(pages, equals([1]));
      expect(state.currentPage, 1);
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('consecutive taps animate and retain each destination page', (
      tester,
    ) async {
      final pages = <int>[];
      final boundaries = <int>[];
      final state = await pumpPaged(
        tester,
        pages: pages,
        boundaries: boundaries,
        tapTurns: true,
      );
      for (final target in [1, 2, 1, 0]) {
        final forward = target > state.currentPage!;
        await tester.tapAt(Offset(forward ? 350 : 50, 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.byType(ReaderPageCurl), findsOneWidget);
        await tester.pumpAndSettle();
        expect(state.currentPage, target);
        expect(find.byType(ReaderPageCurl), findsNothing);
      }
      expect(pages, [1, 2, 1, 0]);
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('consecutive swipes retain each destination page', (
      tester,
    ) async {
      final pages = <int>[];
      final boundaries = <int>[];
      final state = await pumpPaged(
        tester,
        pages: pages,
        boundaries: boundaries,
      );
      for (final target in [1, 2, 1, 0]) {
        final forward = target > state.currentPage!;
        await tester.drag(
          find.byType(ReaderPagedView),
          Offset(forward ? -150 : 150, 0),
        );
        await tester.pumpAndSettle();
        expect(state.currentPage, target);
        expect(find.byType(ReaderPageCurl), findsNothing);
      }
      expect(pages, [1, 2, 1, 0]);
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long drag left completes the curl', (tester) async {
      final pages = <int>[];
      final boundaries = <int>[];
      await pumpPaged(tester, pages: pages, boundaries: boundaries);
      await tester.drag(find.byType(ReaderPagedView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(pages, equals([1]));
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    // Multi-phase drags drive a raw TestGesture with no pumps between
    // moves: `timedDrag`'s small steps never deliver a working drag here
    // (the old short-drag test passed vacuously — the drag never completed,
    // so the page count stayed empty for the wrong reason).
    testWidgets('a short drag left completes the curl without retreat', (
      tester,
    ) async {
      // Legado has no distance threshold: a drag that never moves back
      // completes on release, however short. The old 0.35/fling rule is gone.
      final pages = <int>[];
      final boundaries = <int>[];
      await pumpPaged(tester, pages: pages, boundaries: boundaries);
      final center = tester.getCenter(find.byType(ReaderPagedView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(pages, equals([1]));
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a drag that retreats cancels the curl', (tester) async {
      // Legado's isCancel: the last move retreated, so the release restores.
      final pages = <int>[];
      final boundaries = <int>[];
      await pumpPaged(tester, pages: pages, boundaries: boundaries);
      final center = tester.getCenter(find.byType(ReaderPagedView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-120, 0));
      await gesture.moveBy(const Offset(80, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(pages, isEmpty);
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a drag that retreats then advances again completes', (
      tester,
    ) async {
      // Legado recomputes isCancel on every move: only the last move's
      // direction decides, so a retreat followed by a renewed advance
      // still completes.
      final pages = <int>[];
      final boundaries = <int>[];
      await pumpPaged(tester, pages: pages, boundaries: boundaries);
      final center = tester.getCenter(find.byType(ReaderPagedView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-120, 0));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(const Offset(-60, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(pages, equals([1]));
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('turnPage past the last page requests the boundary', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundaries = <int>[];
      final key = GlobalKey<ReaderPagedViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPagedView(
              key: key,
              layout: _onePageLayout(),
              pageIndex: 0,
              hasPreviousChapter: false,
              hasNextChapter: true,
              onPageChanged: (_) {},
              onBoundary: (direction) async => boundaries.add(direction),
              onDragStart: () {},
              turnStyle: ReaderPageTurnStyle.curl,
              backgroundColor: Colors.white,
            ),
          ),
        ),
      );
      await tester.pump();
      unawaited(key.currentState!.turnPage(1));
      await tester.pumpAndSettle();
      expect(boundaries, equals([1]));
      expect(tester.takeException(), isNull);
    });
  });
}

ReaderChapterLayout _twoPageLayout() {
  const viewport = Size(400, 800);
  final spec = ReaderLayoutSpec(
    viewport: viewport,
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  final content = ChapterContent(
    blocks: [
      ChapterParagraph(
        List.filled(40, '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远山。').join(),
        paraIndex: 0,
      ),
    ],
  );
  final layout = ReaderChapterLayout(
    title: '第一章',
    content: content,
    spec: spec,
  );
  assert(layout.pages.length >= 2, 'expected at least two pages');
  return layout;
}

ReaderChapterLayout _onePageLayout() {
  const viewport = Size(400, 800);
  final spec = ReaderLayoutSpec(
    viewport: viewport,
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  return ReaderChapterLayout(
    title: '第一章',
    content: ChapterContent(
      blocks: [const ChapterParagraph('第一段话。', paraIndex: 0)],
    ),
    spec: spec,
  );
}
