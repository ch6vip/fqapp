import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

void main() {
  for (final style in [ReaderPageTurnStyle.slide, ReaderPageTurnStyle.cover]) {
    for (final direction in [1, -1]) {
      for (final startX in [140.0, 280.0]) {
        testWidgets('$style direction $direction follows finger from $startX', (
          tester,
        ) async {
          await _pumpPager(tester, style);
          final viewport = tester.getRect(find.byType(PageView));
          var finger = viewport.topLeft + Offset(startX, 300);
          final gesture = await tester.startGesture(finger);
          final seamPage = direction > 0 ? 2 : 1;
          for (final distance in [30.0, 50.0, -20.0]) {
            finger += Offset(-direction * distance, 0);
            await gesture.moveTo(finger);
            await tester.pump();
            final seam = tester.getTopLeft(
              find.byKey(ValueKey('reader-text-page-$seamPage')),
            );
            expect(seam.dx, closeTo(finger.dx, 0.1));
          }
          await gesture.up();
          await tester.pumpAndSettle();
          final controller = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          final expectedPage = startX < 200
              ? (direction > 0 ? 2 : 1)
              : (direction > 0 ? 1 : 0);
          expect(controller.page, expectedPage.toDouble());
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('$style drag cancellation allows another page turn', (
      tester,
    ) async {
      await _pumpPager(tester, style);
      final viewport = tester.getRect(find.byType(PageView));
      final gesture = await tester.startGesture(viewport.center);
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveTo(Offset(viewport.right - 40, viewport.center.dy));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      expect(controller.page, 1);
      unawaited(
        tester
            .state<ReaderPagedViewState>(find.byType(ReaderPagedView))
            .turnPage(1),
      );
      await tester.pumpAndSettle();
      expect(controller.page, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style dragging outside the viewport cannot skip a page', (
      tester,
    ) async {
      await _pumpPager(tester, style);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-900, 0));
      await tester.pump();
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      expect(controller.page, 2);
      await tester
          .state<ReaderPagedViewState>(find.byType(ReaderPagedView))
          .turnPage(1);
      await tester.pump();
      expect(controller.page, 2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.page, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style can unmount during a drag', (tester) async {
      await _pumpPager(tester, style);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    for (final direction in [1, -1]) {
      testWidgets('$style fast release $direction never reveals a third page', (
        tester,
      ) async {
        await _pumpPager(tester, style);
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        final from = direction > 0 ? 1 : 2;
        controller.jumpToPage(from);
        await tester.pump();
        final positions = <double>[];
        controller.addListener(() => positions.add(controller.page!));

        // Release before reaching the edge so the fling still has velocity.
        await tester.fling(
          find.byType(PageView),
          Offset(-direction * 150, 0),
          8000,
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 8));

        expect(positions, isNotEmpty);
        expect(positions, everyElement(inInclusiveRange(1.0, 2.0)));
        expect(controller.page, from + direction);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$style fast drag $direction turns only one page', (
        tester,
      ) async {
        await _pumpPager(tester, style);
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        final from = direction > 0 ? 1 : 2;
        controller.jumpToPage(from);
        await tester.pump();
        await tester.fling(
          find.byType(PageView),
          Offset(-direction * 600, 0),
          1500,
        );
        await tester.pumpAndSettle();
        expect(controller.page, from + direction);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Future<void> _pumpPager(WidgetTester tester, ReaderPageTurnStyle style) async {
  await tester.binding.setSurfaceSize(const Size(600, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final layout = ReaderChapterLayout(
    title: '第一章 测试',
    content: ChapterContent(
      blocks: [
        for (var i = 0; i < 60; i++)
          ChapterParagraph('清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。'),
      ],
    ),
    spec: ReaderLayoutSpec(
      viewport: const Size(400, 800),
      textScaler: TextScaler.noScaling,
      preferences: const ReaderPreferences(),
      fontFamily: null,
    ),
  );
  expect(layout.pages.length, greaterThan(2));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 100),
          child: ReaderPagedView(
            layout: layout,
            pageIndex: 1,
            hasPreviousChapter: true,
            hasNextChapter: true,
            onPageChanged: (_) {},
            onBoundary: (_) async {},
            onDragStart: () {},
            turnStyle: style,
            backgroundColor: Colors.white,
          ),
        ),
      ),
    ),
  );
}
