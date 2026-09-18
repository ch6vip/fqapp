import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';

import 'support/fakes.dart';

/// Upstream chapter markup: paragraph ids live in `<p idx="N">` and the idea
/// list is keyed by exactly those ids.
const _html =
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">“对不起......”</p><p></p>'
    '<p idx="1">“老子是兔子啊！”</p><p></p>'
    '<p idx="2">耳边传来稀奇古怪的声音。</p>'
    '</article>';

final List<Chapter> _chapters = [
  Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
  Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
];

ChapterIdeas _ideas() => ChapterIdeas.fromPayload(const {
  'code': 0,
  'data': {
    'data': {
      '0': {
        'count': 12,
        'infos': [
          {'comment_id': 'a1'},
          {'comment_id': 'a2'},
        ],
      },
      '2': {
        'count': 3,
        'infos': [
          {'comment_id': 'b1'},
        ],
      },
    },
  },
});

void main() {
  // The reader resolves its preferences through SharedPreferences, which never
  // answers in a widget test unless a mock store is installed first.
  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  group('paragraph ids', () {
    test('parses the upstream idx attribute', () {
      final content = parseChapterContent(_html);
      final paragraphs = content.blocks.whereType<ChapterParagraph>().toList();
      // The first block is the chapter-title div, which carries no idx.
      expect(paragraphs.map((p) => p.paraIndex).toList(), [null, 0, 1, 2]);
      expect(paragraphs.first.text, '第一章');
      expect(paragraphs[1].text, '“对不起......”');
      expect(paragraphs.last.paraIndex, 2);
    });

    test('leaves paraIndex null without the attribute', () {
      final content = parseChapterContent('<p>第一段</p><p>第二段</p>');
      final paragraphs = content.blocks.whereType<ChapterParagraph>().toList();
      expect(paragraphs, hasLength(2));
      expect(paragraphs.every((p) => p.paraIndex == null), isTrue);
    });

    test('survives the structured cache round trip', () {
      final original = parseChapterContent(_html);
      final restored = ChapterContent.fromCacheText(original.toCacheText());
      final paragraphs = restored.blocks.whereType<ChapterParagraph>().toList();
      expect(paragraphs.map((p) => p.paraIndex).toList(), [null, 0, 1, 2]);
    });

    test('reads an older cache without ids as null', () {
      const legacy =
          '\u001efqapp:chapter:2\n'
          '{"version":2,"illustrationsChecked":true,"legacyText":"a",'
          '"blocks":[{"type":"text","text":"旧缓存段落"}]}';
      final content = ChapterContent.fromCacheText(legacy);
      final paragraphs = content.blocks.whereType<ChapterParagraph>().toList();
      expect(paragraphs.single.paraIndex, isNull);
      expect(paragraphs.single.text, '旧缓存段落');
    });
  });

  group('ReaderIdeasSheet', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required Future<BookCommentPage> Function(ParagraphIdeas, String?) load,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: _ideas(),
              preset: ReaderThemePreset.light,
              loadComments: load,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the selected count above a direct comment list', (
      tester,
    ) async {
      await pumpSheet(tester, load: (_, _) async => const BookCommentPage());
      expect(find.text('12条评论'), findsOneWidget);
      expect(find.text('共 15 条 · 2 段'), findsNothing);
      expect(find.text('全部'), findsNothing);
      expect(find.text('最新'), findsNothing);
      expect(find.text('第 1 段 · 12'), findsNothing);
      expect(find.text('“对不起......”'), findsNothing);
      expect(find.text('暂无评论'), findsOneWidget);
    });

    testWidgets('opens on the first paragraph and shows its comments', (
      tester,
    ) async {
      final requested = <int>[];
      await pumpSheet(
        tester,
        load: (paragraph, _) async {
          requested.add(paragraph.paraIndex);
          return BookCommentPage(
            comments: [
              BookComment(
                id: 'a1',
                text: '这段太真实了',
                userName: '读者甲',
                diggCount: 4,
                createdAt: DateTime(2024, 2, 29),
              ),
            ],
          );
        },
      );
      // The official panel is a single paragraph's list, so the selected one
      // loads as soon as it opens rather than waiting for a tap.
      expect(requested, [0]);
      expect(find.text('这段太真实了'), findsOneWidget);
      expect(find.text('读者甲'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('回复'), findsOneWidget);
      expect(find.text('2024-02-29'), findsOneWidget);
      // The date belongs below the body, aligned with the reply affordance.
      expect(
        tester.getTopLeft(find.text('2024-02-29')).dy,
        greaterThan(tester.getBottomLeft(find.text('这段太真实了')).dy),
      );
      expect(
        tester.getTopLeft(find.text('2024-02-29')).dy,
        tester.getTopLeft(find.text('回复')).dy,
      );
    });

    testWidgets('opens on the tapped paragraph', (tester) async {
      final requested = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: _ideas(),
              preset: ReaderThemePreset.light,
              initialParaIndex: 2,
              loadComments: (paragraph, _) async {
                requested.add(paragraph.paraIndex);
                return const BookCommentPage();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requested, [2]);
      expect(find.text('3条评论'), findsOneWidget);
    });

    testWidgets(
      'keeps upstream order and shows the total rather than page size',
      (tester) async {
        final requested = <int>[];
        await pumpSheet(
          tester,
          load: (paragraph, _) async {
            requested.add(paragraph.paraIndex);
            return BookCommentPage(
              totalCount: 522,
              comments: [
                BookComment(
                  id: 'old',
                  text: '较早的评论',
                  createdAt: DateTime(2026, 1, 1),
                ),
                BookComment(
                  id: 'new',
                  text: '最新的评论',
                  createdAt: DateTime(2026, 9, 1),
                ),
              ],
            );
          },
        );
        expect(requested, [0]);
        expect(find.text('522条评论'), findsOneWidget);
        final newest = tester.getTopLeft(find.text('最新的评论')).dy;
        final older = tester.getTopLeft(find.text('较早的评论')).dy;
        expect(older, lessThan(newest));
      },
    );

    testWidgets('retries a failed load for the same paragraph', (tester) async {
      final requested = <int>[];
      await pumpSheet(
        tester,
        load: (paragraph, _) async {
          requested.add(paragraph.paraIndex);
          if (requested.length == 1) throw StateError('offline');
          return const BookCommentPage(
            comments: [BookComment(id: 'retry', text: '重新加载的评论')],
          );
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('评论加载失败'), findsOneWidget);
      expect(find.text('12条评论'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(requested, [0, 0]);
      expect(find.text('重新加载的评论'), findsOneWidget);
      expect(find.text('评论加载失败'), findsNothing);
    });

    testWidgets('pages in more comments as the list reaches the bottom', (
      tester,
    ) async {
      final cursors = <String?>[];
      final firstPage = BookCommentPage(
        comments: [
          for (var i = 0; i < 30; i++) BookComment(id: 'p1-$i', text: '第一页 $i'),
        ],
        totalCount: 35,
        hasMore: true,
        nextOffset: 20,
      );
      await pumpSheet(tester, load: (paragraph, cursor) async {
        cursors.add(cursor);
        if (cursor == null) return firstPage;
        return const BookCommentPage(
          comments: [BookComment(id: 'p2', text: '第二页的唯一评论')],
          totalCount: 35,
          nextOffset: 40,
        );
      });
      await tester.pumpAndSettle();
      expect(cursors, [null]);
      expect(find.text('第二页的唯一评论'), findsNothing);

      await tester.drag(
        find.byKey(const Key('reader-ideas-comments')),
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();
      expect(cursors, [null, '20']);
      expect(find.text('第二页的唯一评论'), findsOneWidget);

      // Exhausted: scrolling further issues no more requests.
      await tester.drag(
        find.byKey(const Key('reader-ideas-comments')),
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();
      expect(cursors, [null, '20']);
    });

    testWidgets('a failed next page offers a retry that appends', (
      tester,
    ) async {
      var allowSecondPage = false;
      final firstPage = BookCommentPage(
        comments: [
          for (var i = 0; i < 30; i++) BookComment(id: 'p1-$i', text: '第一页 $i'),
        ],
        totalCount: 31,
        hasMore: true,
        nextOffset: 20,
      );
      await pumpSheet(tester, load: (paragraph, cursor) async {
        if (cursor == null) return firstPage;
        // Fails until the test allows it, so the auto-retry that further
        // scroll events trigger cannot heal the list before the tap.
        if (!allowSecondPage) throw StateError('offline');
        return const BookCommentPage(
          comments: [BookComment(id: 'p2', text: '重试后的第二页')],
          nextOffset: 40,
        );
      });
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('reader-ideas-comments')),
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();
      expect(find.text('加载失败，点击重试'), findsOneWidget);
      expect(find.text('重试后的第二页'), findsNothing);

      allowSecondPage = true;
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(find.text('重试后的第二页'), findsOneWidget);
    });

    testWidgets('a short first page preloads the next one without scrolling', (
      tester,
    ) async {
      final cursors = <String?>[];
      await pumpSheet(tester, load: (paragraph, cursor) async {
        cursors.add(cursor);
        if (cursor == null) {
          return const BookCommentPage(
            comments: [BookComment(id: 'p1', text: '只有一条的第一页')],
            totalCount: 2,
            hasMore: true,
            nextOffset: 20,
          );
        }
        return const BookCommentPage(
          comments: [
            BookComment(id: 'p2', text: '补进来的第二条'),
          ],
          totalCount: 2,
          nextOffset: 40,
        );
      });
      await tester.pumpAndSettle();
      expect(cursors, [null, '20']);
      expect(find.text('只有一条的第一页'), findsOneWidget);
      expect(find.text('补进来的第二条'), findsOneWidget);
    });

    testWidgets('says so when the chapter has no ideas', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: ChapterIdeas.empty,
              preset: ReaderThemePreset.light,
              loadComments: (_, _) async => const BookCommentPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本章还没有段评'), findsOneWidget);
      expect(find.text('0条评论'), findsOneWidget);
    });
  });

  group('ReaderPage ideas', () {
    Future<void> pumpReader(
      WidgetTester tester, {
      required ChapterIdeasLoader ideasLoader,
      ParagraphCommentResolver? commentResolver,
    }) async {
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
            // Injected so the reader neither touches Hive nor (per the offline
            // rule) fetches ideas on its own.
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async => parseChapterContent(_html).toCacheText(),
            ideasLoader: ideasLoader,
            commentResolver: commentResolver,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openControls(WidgetTester tester) async {
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      // Secondary actions (缓存/排版) live inside 设置.
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
    }

    testWidgets('opens the sheet from the in-text bubble', (tester) async {
      final resolved = <String>[];
      await pumpReader(
        tester,
        ideasLoader: (_) async => _ideas(),
        commentResolver: (itemId, paragraph, _) async {
          resolved.add('$itemId:${paragraph.paraIndex}');
          return const BookCommentPage(
            comments: [BookComment(id: 'a1', text: '第一段的段评')],
          );
        },
      );
      // The in-text bubble is the only entry point now; the menu row was
      // removed once bubbles carried the same information.
      await tester.tap(find.text('12'));
      await tester.pumpAndSettle();
      expect(find.text('12条评论'), findsOneWidget);
      expect(resolved, ['c1:0']);
      expect(find.text('第一段的段评'), findsOneWidget);
      final panel = tester.getRect(find.byType(BottomSheet));
      // The reference leaves roughly the upper third of the reader visible.
      expect(panel.top, inInclusiveRange(230, 270));
      expect(
        tester.getCenter(find.byKey(const Key('reader-ideas-title'))).dx,
        closeTo(200, 1),
      );
      await tester.tap(find.byKey(const Key('reader-ideas-close')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderIdeasSheet), findsNothing);
      expect(find.byType(ReaderPage), findsOneWidget);
    });

    testWidgets('the control menu has no ideas entry any more', (tester) async {
      await pumpReader(tester, ideasLoader: (_) async => ChapterIdeas.empty);
      await openControls(tester);
      // Bubbles replaced the menu row; the four primary actions remain.
      expect(find.text('段评'), findsNothing);
      expect(find.text('目录'), findsOneWidget);
      expect(find.text('缓存'), findsOneWidget);
    });

    testWidgets('a failed idea load leaves the reader usable', (tester) async {
      await pumpReader(
        tester,
        ideasLoader: (_) async => throw StateError('offline'),
      );
      await openControls(tester);
      expect(find.text('段评'), findsNothing);
      expect(tester.takeException(), isNull);
      // The four primary actions stay available.
      expect(find.text('目录'), findsOneWidget);
      expect(find.text('缓存'), findsOneWidget);
    });

    testWidgets('refetches ideas for the next chapter', (tester) async {
      final calls = <String>[];
      await pumpReader(
        tester,
        ideasLoader: (itemId) async {
          calls.add(itemId);
          return itemId == 'c1' ? _ideas() : ChapterIdeas.empty;
        },
      );
      expect(calls, ['c1']);
      await openControls(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(calls, ['c1', 'c2']);
    });
  });
}
