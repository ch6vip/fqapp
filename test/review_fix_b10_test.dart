import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_bubble.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('paragraph bubble measurement', () {
    for (final scale in [1.0, 1.8]) {
      testWidgets('bubble block measures what it renders at scale $scale', (
        tester,
      ) async {
        final layout = _bubbleLayout(scale: scale);
        final block = layout.blocks[1];
        expect(block.hasBubble, isTrue);
        await tester.pumpWidget(_blockHost(layout, block));
        final render = tester.renderObject<RenderParagraph>(
          find
              .descendant(
                of: find.byType(ReaderBlockText),
                matching: find.byType(RichText),
              )
              .first,
        );
        expect(
          render.size.height,
          moreOrLessEquals(block.height, epsilon: 0.5),
          reason:
              'block ${block.index} renders ${render.size.height}px but was '
              'measured ${block.height}px at scale $scale',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('boundary page timer', () {
    Future<ReaderPagedViewState> pumpPaged(
      WidgetTester tester, {
      required List<int> boundaries,
      required List<int> taps,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<ReaderPagedViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPagedView(
              key: key,
              layout: _plainLayout(),
              pageIndex: 0,
              hasPreviousChapter: false,
              hasNextChapter: true,
              onPageChanged: (_) {},
              onBoundary: (direction) async => boundaries.add(direction),
              onDragStart: () {},
              turnStyle: ReaderPageTurnStyle.none,
              backgroundColor: Colors.white,
              endPage: Center(
                child: ElevatedButton(
                  key: const ValueKey('b10-end-comments'),
                  onPressed: () => taps.add(1),
                  child: const Text('查看本章评论'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return key.currentState!;
    }

    testWidgets('tapping an end page action cancels the deferred advance', (
      tester,
    ) async {
      final boundaries = <int>[];
      final taps = <int>[];
      final state = await pumpPaged(tester, boundaries: boundaries, taps: taps);
      state.turnPage(1);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('b10-end-comments')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('b10-end-comments')));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(taps, hasLength(1));
      expect(boundaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('landing without interaction still advances', (tester) async {
      final boundaries = <int>[];
      final state = await pumpPaged(tester, boundaries: boundaries, taps: []);
      state.turnPage(1);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('b10-end-comments')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(boundaries, equals([1]));
      expect(tester.takeException(), isNull);
    });
  });
}

ReaderChapterLayout _plainLayout() {
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

ReaderChapterLayout _bubbleLayout({required double scale}) {
  const viewport = Size(360, 640);
  final spec = ReaderLayoutSpec(
    viewport: viewport,
    textScaler: TextScaler.linear(scale),
    preferences: const ReaderPreferences(fontSize: 18),
    fontFamily: null,
  );
  final content = ChapterContent(
    blocks: [
      ChapterParagraph(
        List.filled(6, '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。').join(),
        paraIndex: 0,
      ),
    ],
  );
  return ReaderChapterLayout(
    title: '第一章 山间来信',
    content: content,
    spec: spec,
    paragraphBubbles: const {0: 12},
    paragraphBubbleVariants: const {0: ParagraphBubbleVariant.plain},
    bubbleBuilder: (paraIndex, count, variant) => ReaderParagraphBubble(
      count: count,
      metrics: ReaderBubbleMetrics.forFontSize(
        spec.textScaler.scale(spec.bodyStyle.fontSize!),
        variant: variant,
      ),
      preset: ReaderThemePreset.light,
    ),
  );
}

Widget _blockHost(ReaderChapterLayout layout, ReaderContentBlock block) =>
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
          child: SizedBox(
            width: layout.spec.width,
            child: ReaderBlockText(block: block, spec: layout.spec),
          ),
        ),
      ),
    );
