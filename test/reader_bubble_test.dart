import 'dart:async';
import 'dart:convert';
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
    test('the plain bubble is square at every size class', () {
      // cni 72x72 (24x24dp), cnj 78x78 (26x26dp), cnk 90x90 (30x30dp).
      expect(ReaderBubbleMetrics.forFontSize(18).width, 24);
      expect(ReaderBubbleMetrics.forFontSize(18).height, 24);
      expect(ReaderBubbleMetrics.forFontSize(20).width, 26);
      expect(ReaderBubbleMetrics.forFontSize(29).height, 26);
      expect(ReaderBubbleMetrics.forFontSize(30).width, 30);
      expect(ReaderBubbleMetrics.forFontSize(30).height, 30);
      expect(
        ReaderBubbleMetrics.forFontSize(29).asset,
        'assets/images/bubble/para_bubble_plain_normal.webp',
      );
    });

    test('the checkmark and pen-nib masks are wider than tall', () {
      // cnq 78x72 (26x24dp), cnr 84x78 (28x26dp), cns 97x90 (32.3x30dp);
      // the author group shares the geometry (cne/cnf/cng).
      for (final variant in [
        ParagraphBubbleVariant.users,
        ParagraphBubbleVariant.author,
      ]) {
        expect(ReaderBubbleMetrics.forFontSize(18, variant: variant).width, 26);
        expect(
          ReaderBubbleMetrics.forFontSize(18, variant: variant).height,
          24,
        );
        expect(ReaderBubbleMetrics.forFontSize(29, variant: variant).width, 28);
        expect(
          ReaderBubbleMetrics.forFontSize(30, variant: variant).width,
          variant == ParagraphBubbleVariant.users
              ? closeTo(97 / 3, 0.01)
              : 32.0,
        );
        expect(
          ReaderBubbleMetrics.forFontSize(30, variant: variant).height,
          30,
        );
      }
      expect(
        ReaderBubbleMetrics.forFontSize(
          19,
          variant: ParagraphBubbleVariant.users,
        ).asset,
        'assets/images/bubble/para_bubble_users_small.webp',
      );
      expect(
        ReaderBubbleMetrics.forFontSize(
          19,
          variant: ParagraphBubbleVariant.author,
        ).asset,
        'assets/images/bubble/para_bubble_author_small.webp',
      );
    });

    test('a large count steps the label down one size', () {
      final large = ReaderBubbleMetrics.forFontSize(30).forCount(1000);
      expect(large.textSize, 9);
      expect(large.width, ReaderBubbleMetrics.forFontSize(30).width);
      expect(large.height, ReaderBubbleMetrics.forFontSize(30).height);
      // Small is already at the floor.
      expect(ReaderBubbleMetrics.forFontSize(18).forCount(1000).textSize, 8);
      // The overflow threshold and below keep the class untouched.
      final untouched = ReaderBubbleMetrics.forFontSize(30).forCount(99);
      expect(untouched.textSize, ReaderBubbleMetrics.forFontSize(30).textSize);
      expect(untouched.asset, ReaderBubbleMetrics.forFontSize(30).asset);
    });
  });

  group('bubble variant gating', () {
    test(
      'plain for ordinary comments, checkmark for many users, nib for the author',
      () {
        // Build the three buckets directly through the parsed payload.
        final parsed = ChapterIdeas.fromPayload(const {
          'code': 0,
          'data': {
            'data': {
              '0': {'count': 5, 'user_count': 0, 'is_author_comment': false},
              '1': {'count': 5, 'user_count': 3, 'is_author_comment': false},
              '2': {'count': 5, 'user_count': 0, 'is_author_comment': true},
            },
          },
        });
        expect(
          parsed.forParagraph(0)!.bubbleVariant,
          ParagraphBubbleVariant.plain,
        );
        expect(
          parsed.forParagraph(1)!.bubbleVariant,
          ParagraphBubbleVariant.users,
        );
        expect(
          parsed.forParagraph(2)!.bubbleVariant,
          ParagraphBubbleVariant.author,
        );
        expect(parsed.bubbleVariants, {
          0: ParagraphBubbleVariant.plain,
          1: ParagraphBubbleVariant.users,
          2: ParagraphBubbleVariant.author,
        });
      },
    );
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
    testWidgets('paints the official mask: outlined body, hollow interior', (
      tester,
    ) async {
      // The official artwork is a black alpha mask of a speech-bubble outline
      // tinted at draw time. Painting pixels is the only way to assert the
      // tinted bitmap really is an outline with a transparent interior.
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
      // The asset decodes on a real async loader the fake clock does not drive;
      // give it a beat of real time, then pump the delivered image in.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
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

      // Measured from cni.webp: the body's top stroke sits ~4.5-5.5dp below
      // the top of the 24x24dp square box, above the label column (12dp from
      // the box's left edge).
      const centreX = ReaderBubbleMetrics.gap + 12;
      final centreY = height ~/ 2;
      // Small box: 24x24dp.
      final boxTop = centreY - 12;

      // The outline is painted where the body's top stroke must be.
      expect(
        alphaAt(centreX.round(), (boxTop + 5).round()),
        greaterThan(0),
        reason: 'the bubble outline must be painted',
      );
      // A point inside the body between the top stroke (~5.5dp) and the label
      // glyphs (~8dp) must stay page colour: that is what "outlined, not
      // filled" means for this bubble.
      // 6dp sits at the stroke's antialiased tail edge, so accept near-zero:
      // a filled bubble would paint 255 here.
      expect(
        alphaAt(centreX.round(), boxTop + 6),
        lessThan(32),
        reason:
            'inside the bubble body, above the glyph, must stay near-transparent',
      );

      // The mask is mostly transparent (15.8% opaque); a filled bubble would
      // paint essentially the whole box.
      var paintedInBox = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          if (alphaAt(x, y) > 0) paintedInBox++;
        }
      }
      expect(paintedInBox, greaterThan(0));
      expect(
        paintedInBox / (width * height),
        lessThan(0.6),
        reason: 'the official outline covers a small fraction of its box',
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
            commentResolver: (_, _, _) async => const BookCommentPage(),
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

    for (final previouslyChecked in [false, true]) {
      testWidgets('old caches (paragraph ids checked: $previouslyChecked) '
          'acquire real paragraph ids and keep them on reopen', (tester) async {
        final cache = MemoryChapterCache();
        cache.content['book'] = {
          'c1': _legacyCache(previouslyChecked: previouslyChecked),
        };
        final fresh = Completer<String>();
        var requests = 0;
        final history = MemoryReaderStore();
        Widget app() => MaterialApp(
          home: ReaderPage(
            bookId: 'book',
            title: '测试书',
            chapters: _chapters,
            startIndex: 0,
            readerStore: history,
            chapterCache: cache,
            chapterLoader: (_) {
              requests++;
              return fresh.future;
            },
            ideasLoader: (_) async => _ideas(),
            commentResolver: (_, _, _) async => const BookCommentPage(),
          ),
        );
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(requests, 1);
        expect(
          find.textContaining('第一段话。', findRichText: true),
          findsOneWidget,
        );
        expect(find.byType(ReaderParagraphBubble), findsNothing);

        fresh.complete(parseChapterContent(_html).toCacheText());
        await tester.pumpAndSettle();
        expect(find.text('42'), findsOneWidget);
        expect(find.text('7'), findsOneWidget);
        final saved = ChapterContent.fromCacheText(
          cache.content['book']!['c1']!,
        );
        expect(saved.paragraphIdsChecked, isTrue);
        expect(
          saved
              .withoutLeadingTitle('第一章')
              .blocks
              .whereType<ChapterParagraph>()
              .map((p) => p.paraIndex),
          [0, 1, 2],
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(requests, 1);
        expect(find.text('42'), findsOneWidget);
        expect(find.text('7'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final hasIdeas in [false, true]) {
      testWidgets(
        hasIdeas
            ? 'failed paragraph-id refresh preserves readable cached text'
            : 'old caches without ideas do not request paragraph ids',
        (tester) async {
          final cache = MemoryChapterCache();
          final old = _legacyCache();
          cache.content['book'] = {'c1': old};
          var requests = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderPage(
                bookId: 'book',
                title: '测试书',
                chapters: _chapters,
                startIndex: 0,
                readerStore: MemoryReaderStore(),
                chapterCache: cache,
                chapterLoader: (_) async {
                  requests++;
                  throw Exception('offline');
                },
                ideasLoader: (_) async =>
                    hasIdeas ? _ideas() : ChapterIdeas.empty,
                commentResolver: (_, _, _) async => const BookCommentPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(requests, hasIdeas ? 1 : 0);
          expect(cache.content['book']!['c1'], old);
          expect(
            find.textContaining('第一段话。', findRichText: true),
            findsOneWidget,
          );
          expect(find.byType(ReaderParagraphBubble), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

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
            commentResolver: (_, paragraph, _) async {
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

// Image-aware caches written before the current paragraph parser revision.
String _legacyCache({bool previouslyChecked = false}) =>
    '\u001efqapp:chapter:2\n${jsonEncode({
      'version': 2,
      'illustrationsChecked': true,
      if (previouslyChecked) 'paragraphIdsChecked': true,
      'legacyText': '第一章\n第一段话。\n第二段话。\n第三段话。',
      'blocks': [
        for (final text in ['第一章', '第一段话。', '第二段话。', '第三段话。']) {'type': 'text', 'text': text},
      ],
    })}';
