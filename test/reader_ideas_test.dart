import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/reader_illustration.dart';

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
      Future<CommentReplyPage> Function(String commentId)? replyLoader,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: _ideas(),
              preset: ReaderThemePreset.light,
              loadComments: load,
              replyLoader: replyLoader,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows paragraph images and opens the zoomable viewer', (
      tester,
    ) async {
      final page = parseParagraphComments({
        'data': {
          'data_list': [
            {
              'comment': {
                'common': {
                  'content': {
                    'text': '带图评论',
                    'image_data_list': {
                      'image_data': [
                        {'web_url': 'https://example.test/comment.jpg'},
                      ],
                    },
                  },
                },
              },
            },
          ],
        },
      });
      await pumpSheet(tester, load: (_, _) async => page);
      expect(find.text('带图评论'), findsOneWidget);
      expect(find.byType(ReaderIllustration), findsOneWidget);
      await tester.tap(find.byType(ReaderIllustration));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('关闭插图'));
      await tester.pumpAndSettle();
      expect(find.text('带图评论'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

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
                replyCount: 2,
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
      expect(find.text('回复 2'), findsOneWidget);
      expect(find.text('2024-02-29'), findsOneWidget);
      // The date belongs below the body, aligned with the reply affordance.
      expect(
        tester.getTopLeft(find.text('2024-02-29')).dy,
        greaterThan(tester.getBottomLeft(find.text('这段太真实了')).dy),
      );
      expect(
        tester.getTopLeft(find.text('2024-02-29')).dy,
        tester.getTopLeft(find.text('回复 2')).dy,
      );
    });

    testWidgets('点「回复 N」就地展开回复，再点收起（issue #95）', (tester) async {
      var loads = 0;
      final page = CommentReplyPage(
        totalCount: 2,
        replies: [
          CommentReply(
            id: 'r1',
            text: '同感',
            userName: '读者乙',
            createdAt: DateTime(2024, 3, 1),
          ),
          CommentReply(
            id: 'r2',
            text: '我也这么想',
            userName: '读者丙',
            createdAt: DateTime(2024, 3, 2),
          ),
        ],
      );
      await pumpSheet(
        tester,
        load: (_, _) async => BookCommentPage(
          comments: [
            BookComment(
              id: 'a1',
              text: '这段太真实了',
              userName: '读者甲',
              replyCount: 2,
              createdAt: DateTime(2024, 2, 29),
            ),
          ],
        ),
        replyLoader: (_) async {
          loads++;
          return page;
        },
      );

      // 展开前：官方 b9g「展开%d条回复」，只有计数没有正文。
      expect(find.text('展开 2 条回复'), findsOneWidget);
      expect(find.text('同感'), findsNothing);

      await tester.tap(find.text('展开 2 条回复'));
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.textContaining('同感', findRichText: true), findsOneWidget);
      expect(find.textContaining('我也这么想', findRichText: true), findsOneWidget);
      // 展开后：官方 b9i「收起」。
      expect(find.text('收起'), findsOneWidget);
      expect(find.text('展开 2 条回复'), findsNothing);

      // 再点收起，回到可展开态且不重复请求。
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.text('展开 2 条回复'), findsOneWidget);
      expect(find.textContaining('同感', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有 replyLoader 时回复计数只读，不出现可点控件', (tester) async {
      await pumpSheet(
        tester,
        load: (_, _) async => BookCommentPage(
          comments: [
            BookComment(
              id: 'a1',
              text: '只读',
              userName: '读者甲',
              replyCount: 2,
              createdAt: DateTime(2024, 2, 29),
            ),
          ],
        ),
      );
      expect(find.text('回复 2'), findsOneWidget);
      // 离线调用方拿不到只有失败可能的控件。
      expect(find.byKey(const ValueKey('reader_reply_toggle_a1')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无二级评论时不出现回复入口，也不显示暂无回复（issue #173）', (tester) async {
      var loads = 0;
      await pumpSheet(
        tester,
        load: (_, _) async => BookCommentPage(
          comments: [
            BookComment(
              id: 'a1',
              text: '没有回复的评论',
              userName: '读者甲',
              createdAt: DateTime(2024, 2, 29),
            ),
          ],
        ),
        replyLoader: (_) async {
          loads++;
          return CommentReplyPage.empty;
        },
      );

      expect(find.text('没有回复的评论'), findsOneWidget);
      expect(find.text('展开 0 条回复'), findsNothing);
      expect(find.text('回复'), findsNothing);
      expect(
        find.byKey(const ValueKey('reader_reply_toggle_a1')),
        findsNothing,
      );
      expect(find.text('暂无回复'), findsNothing);
      // 没有可点的 0 回复入口，自然也没有发出请求。
      expect(loads, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('评论正文里的表情令牌渲染成图片（issue #173）', (tester) async {
      await pumpSheet(
        tester,
        load: (_, _) async => BookCommentPage(
          comments: [BookComment(id: 'a1', text: '这段[微笑]太真实了')],
        ),
      );

      expect(find.text('[微笑]'), findsNothing);
      expect(find.text('这段[微笑]太真实了'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
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
