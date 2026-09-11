import 'package:flutter/material.dart';
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
    test('only paragraphs passing the channel-3 gate bubble', () {
      final ideas = _ideas();
      // 42 passes; 7 and 0 do not, even though 7 has ideas on channel 1.
      expect(ideas.bubbleCounts, {0: 42});
      expect(ideas.forParagraph(1)!.hasIdeas, isTrue);
      expect(ideas.forParagraph(1)!.showsBubble, isFalse);
    });

    test('a payload without bubble_data falls back to having ideas', () {
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

    test('the bubble prints the total, not the gated channel count', () {
      expect(_ideas().bubbleCounts[0], 42);
    });
  });

  group('bubble metrics', () {
    test('picks the size class from the effective font size', () {
      expect(
        ReaderBubbleMetrics.forFontSize(18),
        const ReaderBubbleMetrics(textSize: 8, width: 26, height: 24),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(19),
        const ReaderBubbleMetrics(textSize: 8, width: 26, height: 24),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(20),
        const ReaderBubbleMetrics(textSize: 9, width: 28, height: 26),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(29),
        const ReaderBubbleMetrics(textSize: 9, width: 28, height: 26),
      );
      expect(
        ReaderBubbleMetrics.forFontSize(30),
        const ReaderBubbleMetrics(textSize: 10, width: 32, height: 30),
      );
    });

    test('a four-digit count shrinks the font and squares the box', () {
      final large = ReaderBubbleMetrics.forFontSize(30).forCount(1000);
      expect(large.textSize, 9);
      expect(large.width, large.height);
      // Three digits and below keep the class untouched.
      expect(
        ReaderBubbleMetrics.forFontSize(30).forCount(999),
        ReaderBubbleMetrics.forFontSize(30),
      );
    });
  });

  group('bubble label', () {
    testWidgets('shows the count and clamps at 999+', (tester) async {
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

      await pump(999);
      expect(find.text('999'), findsOneWidget);

      await pump(1000);
      expect(find.text('999+'), findsOneWidget);
      expect(find.text('1000'), findsNothing);

      await pump(12800);
      expect(find.text('999+'), findsOneWidget);
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

    testWidgets('draws a bubble only for the gated paragraph', (tester) async {
      await pumpReader(tester, ideas: _ideas());
      expect(find.text('42'), findsOneWidget);
      // The paragraph with 7 ideas on another channel gets no bubble.
      expect(find.text('7'), findsNothing);
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
      expect(find.text('999+'), findsOneWidget);
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
