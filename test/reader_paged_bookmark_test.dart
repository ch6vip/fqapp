import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_bookmark_ribbon.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_page_curl.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

const _savedKey = ValueKey('reader-bookmark-saved-ribbon');
const _oldColor = Colors.orange;
const _newColor = Colors.blue;

void main() {
  for (final style in [ReaderPageTurnStyle.slide, ReaderPageTurnStyle.cover]) {
    for (final direction in [1, -1]) {
      testWidgets(
        '$style bookmark stays with its page during drag $direction',
        (tester) async {
          await _pumpPager(tester, style);
          final viewport = tester.getRect(find.byType(PageView));
          final ribbon = find.byKey(_savedKey);
          final origin = tester.getTopLeft(ribbon);
          final gesture = await tester.startGesture(viewport.center);
          await gesture.moveBy(Offset(-direction * 80, 0));
          await tester.pump();
          await gesture.moveBy(Offset(-direction * 40, 0));
          await tester.pump();

          final page = find.byKey(const ValueKey('reader-text-page-1'));
          final pageLeft = tester.getTopLeft(page).dx;
          expect(ribbon, findsOneWidget);
          expect(
            tester.getTopLeft(ribbon).dx,
            closeTo(pageLeft + viewport.width - 14, 0.1),
          );
          // Forward cover keeps the old sheet pinned while the new sheet
          // covers it. Slide and backward cover move this sheet itself.
          final expectedShift =
              style == ReaderPageTurnStyle.cover && direction > 0
              ? 0.0
              : -direction * 120.0;
          expect(
            tester.getTopLeft(ribbon).dx,
            closeTo(origin.dx + expectedShift, 0.1),
          );
          final incoming = find.byKey(
            ValueKey('reader-text-page-${1 + direction}'),
          );
          expect(incoming, findsOneWidget);

          // Retreat beyond the starting point, then cancel: the same bookmark
          // must return with the page and no mark may remain on its neighbour.
          await gesture.moveTo(viewport.center + Offset(direction * 20, 0));
          await tester.pump();
          await gesture.cancel();
          await tester.pumpAndSettle();
          expect(
            tester
                .state<ReaderPagedViewState>(find.byType(ReaderPagedView))
                .currentPage,
            1,
          );
          expect(ribbon, findsOneWidget);
          expect(tester.getTopLeft(ribbon).dx, closeTo(origin.dx, 0.1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'curl includes the mark on both outgoing faces and cancels cleanly',
    (tester) async {
      await _pumpPager(tester, ReaderPageTurnStyle.curl);
      final origin = tester.getTopLeft(find.byKey(_savedKey));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();

      final curlFinder = find.byType(ReaderPageCurl);
      final curl = tester.widget<ReaderPageCurl>(curlFinder);
      expect(curl.progress, greaterThan(0));
      expect(curl.progress, lessThan(1));
      final outgoingMarks = find.descendant(
        of: curlFinder,
        matching: find.byKey(_savedKey),
      );
      // The front and reflected back both use the outgoing page surface.
      expect(outgoingMarks, findsNWidgets(2));
      final positions = outgoingMarks.evaluate().map((element) {
        final box = element.findRenderObject()! as RenderBox;
        return box.localToGlobal(Offset.zero).dx;
      }).toList();
      expect((positions[0] - positions[1]).abs(), greaterThan(10));
      expect(
        find.descendant(
          of: find.byWidget(curl.incoming),
          matching: find.byKey(_savedKey),
        ),
        findsNothing,
      );

      await gesture.moveBy(const Offset(80, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPageCurl), findsNothing);
      expect(find.byKey(_savedKey), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(_savedKey)).dx,
        closeTo(origin.dx, 0.1),
      );
      expect(
        tester
            .state<ReaderPagedViewState>(find.byType(ReaderPagedView))
            .currentPage,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final style in [
    ReaderPageTurnStyle.slide,
    ReaderPageTurnStyle.cover,
    ReaderPageTurnStyle.curl,
  ]) {
    for (final outgoingMarked in [true, false]) {
      testWidgets(
        '$style chapter snapshot keeps independent bookmark state ($outgoingMarked)',
        (tester) async {
          final oldLayout = _layout('旧章节', horizontalPadding: 8);
          final turn = ReaderChapterTurn(
            direction: 1,
            page: oldLayout.pages.last,
            spec: oldLayout.spec,
            bookmarked: outgoingMarked,
            bookmarkColor: _oldColor,
          );
          await _pumpPager(
            tester,
            style,
            bookmarkedPages: outgoingMarked ? const {} : const {1},
            chapterTurn: turn,
            horizontalPadding: 48,
          );
          await tester.pump(const Duration(milliseconds: 70));
          final oldMark = find.byWidgetPredicate(
            (widget) =>
                widget is ReaderBookmarkRibbon && widget.color == _oldColor,
          );
          final newMark = find.byWidgetPredicate(
            (widget) =>
                widget is ReaderBookmarkRibbon && widget.color == _newColor,
          );
          final viewport = tester.getRect(find.byType(PageView));
          if (outgoingMarked) {
            expect(newMark, findsNothing);
            for (final mark in tester.widgetList<ReaderBookmarkRibbon>(
              oldMark,
            )) {
              expect(mark.textInset, 8);
            }
            if (style == ReaderPageTurnStyle.curl) {
              expect(oldMark, findsNWidgets(2));
            } else {
              expect(oldMark, findsOneWidget);
              final x = tester.getTopLeft(oldMark).dx;
              if (style == ReaderPageTurnStyle.slide) {
                expect(x, lessThan(viewport.right - 6));
              } else {
                expect(x, closeTo(viewport.right - 6, 0.1));
              }
            }
          } else {
            expect(oldMark, findsNothing);
            // One live destination and one animated destination surface.
            expect(newMark, findsNWidgets(2));
            for (final mark in tester.widgetList<ReaderBookmarkRibbon>(
              newMark,
            )) {
              expect(mark.textInset, 48);
            }
            if (style == ReaderPageTurnStyle.curl) {
              final curl = tester.widget<ReaderPageCurl>(
                find.byType(ReaderPageCurl),
              );
              expect(
                find.descendant(
                  of: find.byWidget(curl.outgoing),
                  matching: find.byKey(_savedKey),
                ),
                findsNothing,
              );
            }
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final inset in [8.0, 20.0, 48.0]) {
    testWidgets(
      'page ribbon stays in the $inset text margin with a right gap',
      (tester) async {
        await _pumpPager(
          tester,
          ReaderPageTurnStyle.slide,
          horizontalPadding: inset,
        );
        final page = tester.getRect(
          find.byKey(const ValueKey('reader-text-page-1')),
        );
        final ribbon = tester.getRect(find.byKey(_savedKey));
        expect(ribbon.right, lessThan(page.right));
        expect(ribbon.left, greaterThanOrEqualTo(page.right - inset + 2));
        expect(ribbon.width, inset == 8 ? 4 : 10);
        expect(
          tester.widget<ReaderBookmarkRibbon>(find.byKey(_savedKey)).textInset,
          inset,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('pager without bookmarked pages adds no decorations', (
    tester,
  ) async {
    await _pumpPager(
      tester,
      ReaderPageTurnStyle.slide,
      bookmarkedPages: const {},
    );
    expect(find.byType(ReaderBookmarkRibbon), findsNothing);
  });
}

Future<void> _pumpPager(
  WidgetTester tester,
  ReaderPageTurnStyle style, {
  Set<int> bookmarkedPages = const {1},
  ReaderChapterTurn? chapterTurn,
  double horizontalPadding = 20,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ReaderPagedView(
          layout: _layout('新章节', horizontalPadding: horizontalPadding),
          pageIndex: 1,
          hasPreviousChapter: true,
          hasNextChapter: true,
          onPageChanged: (_) {},
          onBoundary: (_) async {},
          onDragStart: () {},
          turnStyle: style,
          backgroundColor: Colors.white,
          bookmarkedPages: bookmarkedPages,
          bookmarkColor: _newColor,
          chapterTurn: chapterTurn,
        ),
      ),
    ),
  );
}

ReaderChapterLayout _layout(String title, {double horizontalPadding = 20}) {
  final layout = ReaderChapterLayout(
    title: title,
    content: ChapterContent(
      blocks: [
        for (var i = 0; i < 60; i++)
          ChapterParagraph('清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。', paraIndex: i),
      ],
    ),
    spec: ReaderLayoutSpec(
      viewport: const Size(400, 800),
      textScaler: TextScaler.noScaling,
      preferences: ReaderPreferences(horizontalPadding: horizontalPadding),
      fontFamily: null,
    ),
  );
  assert(layout.pages.length > 2);
  return layout;
}
