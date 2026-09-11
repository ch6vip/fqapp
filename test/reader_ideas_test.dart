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
      required Future<BookCommentPage> Function(ParagraphIdeas) load,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: _ideas(),
              paragraphTexts: const {0: '“对不起......”', 2: '耳边传来稀奇古怪的声音。'},
              preset: ReaderThemePreset.light,
              loadComments: load,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('lists only paragraphs that carry ideas', (tester) async {
      await pumpSheet(tester, load: (_) async => const BookCommentPage());
      expect(find.text('段评'), findsOneWidget);
      expect(find.text('共 15 条 · 2 段'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-idea-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-idea-2')), findsOneWidget);
      // Paragraph 1 has no ideas, so it must not appear.
      expect(find.byKey(const ValueKey('reader-idea-1')), findsNothing);
      expect(find.text('第 1 段 · 12'), findsOneWidget);
      expect(find.text('第 3 段 · 3'), findsOneWidget);
    });

    testWidgets('opens on the first paragraph and shows its comments', (
      tester,
    ) async {
      final requested = <int>[];
      await pumpSheet(
        tester,
        load: (paragraph) async {
          requested.add(paragraph.paraIndex);
          return const BookCommentPage(
            comments: [
              BookComment(
                id: 'a1',
                text: '这段太真实了',
                userName: '读者甲',
                diggCount: 4,
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
      expect(find.text('赞 4'), findsOneWidget);
      // The paragraph itself is quoted above the list for context.
      expect(find.byKey(const Key('reader-ideas-quote')), findsOneWidget);

      // Switching paragraphs loads that one, and returning reuses the cache.
      await tester.tap(find.byKey(const ValueKey('reader-idea-2')));
      await tester.pumpAndSettle();
      expect(requested, [0, 2]);
      await tester.tap(find.byKey(const ValueKey('reader-idea-0')));
      await tester.pumpAndSettle();
      expect(requested, [0, 2]);
    });

    testWidgets('opens on the tapped paragraph', (tester) async {
      final requested = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: _ideas(),
              paragraphTexts: const {0: '第一段', 2: '第三段'},
              preset: ReaderThemePreset.light,
              initialParaIndex: 2,
              loadComments: (paragraph) async {
                requested.add(paragraph.paraIndex);
                return const BookCommentPage();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requested, [2]);
    });

    testWidgets('the 全部/最新 filters reorder without refetching', (tester) async {
      final requested = <int>[];
      await pumpSheet(
        tester,
        load: (paragraph) async {
          requested.add(paragraph.paraIndex);
          return BookCommentPage(
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
      // 全部 keeps the upstream order.
      expect(find.text('较早的评论'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader-ideas-filter-newest')),
      );
      await tester.pumpAndSettle();
      // 最新 sorts by publish time, and does not hit the loader again.
      expect(requested, [0]);
      final newest = tester.getTopLeft(find.text('最新的评论')).dy;
      final older = tester.getTopLeft(find.text('较早的评论')).dy;
      expect(newest, lessThan(older));
    });

    testWidgets('reports a failed load without losing the strip', (
      tester,
    ) async {
      await pumpSheet(tester, load: (_) async => throw StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('段评暂时无法加载'), findsOneWidget);
      // The other paragraph is still selectable.
      expect(find.byKey(const ValueKey('reader-idea-2')), findsOneWidget);
    });

    testWidgets('says so when the chapter has no ideas', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: ChapterIdeas.empty,
              paragraphTexts: const {},
              preset: ReaderThemePreset.light,
              loadComments: (_) async => const BookCommentPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本章还没有段评'), findsOneWidget);
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
            chapterLoader: (_) async => _html,
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
    }

    testWidgets('shows the idea count and opens the sheet', (tester) async {
      final resolved = <String>[];
      await pumpReader(
        tester,
        ideasLoader: (_) async => _ideas(),
        commentResolver: (itemId, paragraph) async {
          resolved.add('$itemId:${paragraph.paraIndex}');
          return const BookCommentPage(
            comments: [BookComment(id: 'a1', text: '第一段的段评')],
          );
        },
      );
      await openControls(tester);
      final ideas = find.byKey(const ValueKey('reader-ideas'));
      expect(ideas, findsOneWidget);
      expect(find.text('段评 · 15'), findsOneWidget);

      await tester.ensureVisible(ideas);
      await tester.tap(ideas);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-idea-0')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-idea-0')));
      await tester.pumpAndSettle();
      expect(resolved, ['c1:0']);
      expect(find.text('第一段的段评'), findsOneWidget);
    });

    testWidgets('hides the action when the chapter has no ideas', (
      tester,
    ) async {
      await pumpReader(tester, ideasLoader: (_) async => ChapterIdeas.empty);
      await openControls(tester);
      expect(find.byKey(const ValueKey('reader-ideas')), findsNothing);
    });

    testWidgets('a failed idea load leaves the reader usable', (tester) async {
      await pumpReader(
        tester,
        ideasLoader: (_) async => throw StateError('offline'),
      );
      await openControls(tester);
      expect(find.byKey(const ValueKey('reader-ideas')), findsNothing);
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
