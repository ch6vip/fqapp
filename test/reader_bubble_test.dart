import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_bubble.dart';

import 'support/fakes.dart';

/// Paragraph ids live in `<p idx="N">`; the idea map is keyed by exactly those.
const _html =
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">第一段话。</p><p></p>'
    '<p idx="1">第二段话。</p><p></p>'
    '<p idx="2">第三段话。</p>'
    '</article>';

final List<Chapter> _chapters = [
  Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
];

/// `bubble_data` mirrors the live payload: key `3` is the gate the official
/// client reads, and it is 0 for a paragraph that still has a non-zero total.
ChapterIdeas _ideas() => ChapterIdeas.fromPayload(const {
  'code': 0,
  'data': {
    'data': {
      // Passes the gate: shows the total, not the gated count.
      '0': {
        'count': 42,
        'bubble_data': {
          '0': {'channel': 43, 'count': 0},
          '1': {'channel': 0, 'count': 42},
          '3': {'channel': 0, 'count': 42},
        },
        'infos': [],
      },
      // Fails the gate despite having ideas on another channel.
      '1': {
        'count': 7,
        'bubble_data': {
          '1': {'channel': 0, 'count': 7},
          '3': {'channel': 43, 'count': 0},
        },
        'infos': [],
      },
      '2': {
        'count': 0,
        'bubble_data': {
          '3': {'channel': 0, 'count': 0},
        },
        'infos': [],
      },
    },
  },
});

ChapterIdeas _overCountIdeas() => ChapterIdeas.fromPayload(const {
  'code': 0,
  'data': {
    'data': {
      '0': {
        'count': 12800,
        'bubble_data': {
          '3': {'channel': 0, 'count': 12800},
        },
      },
    },
  },
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  group('bubble gating', () {
    test('every paragraph with ideas bubbles, whatever its channels', () {
      final ideas = _ideas();
      // 42, 7 and 0 respectively. The middle one carries its ideas on channel 1
      // with bubble_data[3] at 0 — under the official AB-gated variant it would
      // have been hidden, which is the bug this covers.
      expect(ideas.bubbleCounts, {0: 42, 1: 7});
      expect(ideas.bubbleCounts.containsKey(2), isFalse);
      expect(ideas.forParagraph(1)!.showsBubble, isTrue);
    });

    test('a payload without bubble_data still bubbles', () {
      final ideas = ChapterIdeas.fromPayload(const {
        'code': 0,
        'data': {
          'data': {
            '5': {'count': 3, 'infos': []},
          },
        },
      });
      expect(ideas.bubbleCounts, {5: 3});
    });

    test('the bubble prints the paragraph total', () {
      expect(_ideas().bubbleCounts[0], 42);
    });
  });

  group('bubble metrics', () {
    test('picks the size class from the effective font size', () {
      expect(
        ReaderBubbleMetrics.forFontSize(18),
        const ReaderBubbleMetrics(textSize: 8, diameter: 24),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(19),
        const ReaderBubbleMetrics(textSize: 8, diameter: 24),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(20),
        const ReaderBubbleMetrics(textSize: 9, diameter: 26),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(29),
        const ReaderBubbleMetrics(textSize: 9, diameter: 26),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(30),
        const ReaderBubbleMetrics(textSize: 10, diameter: 30),
      );
    });

    test('the bubble is a circle: width equals height', () {
      for (final size in [18.0, 24.0, 34.0]) {
        final metrics = ReaderBubbleMetrics.forFontSize(size);
        expect(metrics.width, metrics.diameter);
        expect(metrics.height, metrics.diameter);
      }
    });

    test('a large count steps the label down one size', () {
      final large = ReaderBubbleMetrics.forFontSize(30).forCount(1000);
      expect(large.textSize, 9);
      expect(large.diameter, 30);
      // Small is already at the floor.
      expect(ReaderBubbleMetrics.forFontSize(18).forCount(1000).textSize, 8);
      // The overflow threshold and below keep the class untouched.
      expect(
        ReaderBubbleMetrics.forFontSize(30).forCount(99),
        ReaderBubbleMetrics.forFontSize(30),
      );
    });
  });

  group('bubble label', () {
    testWidgets('shows the count and caps the label at 99+', (tester) async {
      Future<void> pump(int count) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderParagraphBubble(
              count: count,
              metrics: ReaderBubbleMetrics.forFontSize(18),
              preset: ReaderThemePreset.light,
            ),
          ),
        ),
      );
      await pump(42);
      expect(find.text('42'), findsOneWidget);

      await pump(99);
      expect(find.text('99'), findsOneWidget);

      // Beyond 99 the label caps, which is what the official client renders
      // while its inline switch is off.
      await pump(100);
      expect(find.text('99+'), findsOneWidget);
      expect(find.text('100'), findsNothing);

      await pump(12800);
      expect(find.text('99+'), findsOneWidget);
    });
  });

  group('bubble appearance', () {
    testWidgets('is a hollow ring, not a filled disc', (tester) async {
      // The official bubble is a stroked circle with a transparent centre, so
      // the paragraph text stays visible through it. Painting pixels is the only
      // way to assert that: a decoration assertion would pass for a filled one.
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: RepaintBoundary(
                key: boundary,
                child: ReaderParagraphBubble(
                  count: 42,
                  metrics: ReaderBubbleMetrics.forFontSize(18),
                  preset: ReaderThemePreset.light,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final painted = await tester.runAsync(() async {
        final object =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await object.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final result = (
          size: image.width,
          pixels: Uint8List.fromList(data!.buffer.asUint8List()),
        );
        image.dispose();
        return result;
      });
      final (size: width, pixels: bytes) = painted!;
      final height = bytes.length ~/ 4 ~/ width;
      int alphaAt(int x, int y) => bytes[(y * width + x) * 4 + 3];

      final metrics = ReaderBubbleMetrics.forFontSize(18);
      final d = metrics.diameter;
      // The ring sits after the leading gap, vertically centred.
      final centreX = (ReaderBubbleMetrics.gap + d / 2).round();
      final centreY = height ~/ 2;

      // A point inside the circle but clear of the label glyph must be page
      // colour: that is what "hollow" means for this bubble.
      expect(
        alphaAt(centreX, centreY - 8),
        0,
        reason: 'inside the ring, above the glyph, must stay transparent',
      );
      // The top of the ring itself is painted.
      expect(
        alphaAt(centreX, centreY - d ~/ 2),
        greaterThan(0),
        reason: 'the ring outline must be painted',
      );

      // A ring paints a small fraction of its disc; a filled bubble would paint
      // essentially all of it.
      var paintedInsideDisc = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final dx = x - centreX;
          final dy = y - centreY;
          if (dx * dx + dy * dy > (d / 2) * (d / 2)) continue;
          if (alphaAt(x, y) > 0) paintedInsideDisc++;
        }
      }
      final discArea = 3.14159 * (d / 2) * (d / 2);
      expect(paintedInsideDisc, greaterThan(0));
      expect(
        paintedInsideDisc / discArea,
        lessThan(0.6),
        reason: 'a ring covers far less of the disc than a filled bubble',
      );
    });
  });

  group('ReaderPage bubbles', () {
    Future<void> pumpReader(
      WidgetTester tester, {
      ChapterIdeas? ideas,
      ReaderPageMode mode = ReaderPageMode.paged,
      TextScaler scaler = TextScaler.noScaling,
    }) async {
      SharedPreferences.setMockInitialValues({'reader_page_mode': '$mode'});
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scaler),
            child: child!,
          ),
          home: ReaderPage(
            bookId: 'book',
            title: '测试书',
            chapters: _chapters,
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async =>
                parseChapterContent(_html).toCacheText(),
            ideasLoader: (_) async => ideas ?? ChapterIdeas.empty,
            commentResolver: (_, _) async => const BookCommentPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('draws a bubble for every paragraph that has ideas', (
      tester,
    ) async {
      await pumpReader(tester, ideas: _ideas());
      expect(find.text('42'), findsOneWidget);
      // The paragraph whose ideas sit on channel 1 still gets one.
      expect(find.text('7'), findsOneWidget);
      // The paragraph with no ideas gets none.
      expect(find.byType(ReaderParagraphBubble), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('draws no bubble without ideas', (tester) async {
      await pumpReader(tester);
      expect(find.byType(ReaderParagraphBubble), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('draws bubbles in scroll mode too', (tester) async {
      await pumpReader(tester, ideas: _ideas(), mode: ReaderPageMode.scroll);
      expect(find.text('42'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a large text scale without overflowing', (
      tester,
    ) async {
      await pumpReader(
        tester,
        ideas: _ideas(),
        scaler: const TextScaler.linear(1.8),
      );
      expect(find.text('42'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the bubble opens its paragraph expanded', (
      tester,
    ) async {
      final requested = <int>[];
      // Resolve bodies for the paragraph the bubble points at.
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'book',
            title: '测试书',
            chapters: _chapters,
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async =>
                parseChapterContent(_html).toCacheText(),
            ideasLoader: (_) async => _ideas(),
            commentResolver: (_, paragraph) async {
              requested.add(paragraph.paraIndex);
              return const BookCommentPage(
                comments: [BookComment(id: 'x', text: '这段太真实了')],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('42'));
      await tester.pumpAndSettle();

      // The panel opened already focused on that paragraph, and fetched its
      // bodies without a second tap.
      expect(requested, [0]);
      expect(find.text('这段太真实了'), findsOneWidget);
    });

    testWidgets('leaves the paragraph text intact', (tester) async {
      await pumpReader(tester, ideas: _ideas());
      // Every paragraph still renders; the bubble is additive.
      for (final text in ['第一段话。', '第二段话。', '第三段话。']) {
        expect(find.textContaining(text, findRichText: true), findsOneWidget);
      }
    });

    testWidgets('a huge count does not break the layout', (tester) async {
      await pumpReader(tester, ideas: _overCountIdeas());
      expect(find.text('99+'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the bubble sits inside the paragraph, after its text', (
      tester,
    ) async {
      await pumpReader(tester, ideas: _ideas());
      final bubble = tester.getRect(find.byType(ReaderParagraphBubble).first);
      // The paragraph that owns it: the first text block.
      final paragraph = tester.getRect(
        find.byKey(const ValueKey('reader-paragraph-0')),
      );
      // Inline, not floating over the paragraph or pushed outside its box.
      expect(bubble.top, greaterThanOrEqualTo(paragraph.top - 0.01));
      expect(bubble.bottom, lessThanOrEqualTo(paragraph.bottom + 0.01));
      expect(bubble.left, greaterThan(paragraph.left));
      // On the last line: it trails the paragraph instead of interrupting it.
      expect(bubble.center.dy, greaterThan(paragraph.center.dy));
    });
  });
}
