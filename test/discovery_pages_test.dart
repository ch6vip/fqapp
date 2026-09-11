import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/author_profile.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/author_page.dart';
import 'package:fqapp/pages/rank_page.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/detail/detail_reviews.dart';
import 'package:fqapp/widgets/search/search_discovery.dart';

/// In-memory history so the search page never touches the platform store.
class _MemoryHistory implements SearchHistoryRepository {
  @override
  Future<List<String>> load() async => const [];

  @override
  Future<List<String>> add(String query) async => const [];

  @override
  Future<List<String>> remove(String query) async => const [];

  @override
  Future<void> clear() async {}
}

const _author = AuthorProfile(
  id: '1988336383174046',
  name: '七彩虹桥的吕师傅',
  description: '人生是旷野呀朋友！',
  level: '作家Lv.5',
  followerCount: 20905,
  workCount: 5,
  works: [
    AuthorWork(
      id: '7676082357077543960',
      title: '发现青梅真香且喜欢我，我重生了',
      abstract: '【轻松校园】',
      category: '都市脑洞',
      creationStatus: 1,
      wordNumber: 115815,
    ),
    AuthorWork(
      id: '7491705400958405694',
      title: '霸凌？穿书黄毛！学霸也是霸！',
      category: '都市脑洞',
      creationStatus: 0,
      wordNumber: 1328318,
    ),
  ],
);

const _catalog = RankCatalog(
  rankId: '7098235271900037133',
  tabs: [
    RankTab(name: '巅峰榜', algo: 200),
    RankTab(name: '完本榜', algo: 100),
  ],
  categories: [
    RankCategory(name: '全部', id: 0),
    RankCategory(name: '穿越', id: 37),
  ],
);

RankBoard _board({bool hasMore = false, int count = 2, int startAt = 1}) =>
    RankBoard(
      hasMore: hasMore,
      entries: [
        for (var i = 0; i < count; i++)
          RankEntry(
            position: startAt + i,
            id: 'book-$i',
            title: '锦衣夜行九万里 $i',
            author: '安岳的白沐潼',
            abstract: '锦衣公子神通骨',
            category: '传统玄幻',
            creationStatus: 1,
            wordNumber: 2009374,
          ),
      ],
    );

void main() {
  group('SearchSuggestionList', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<SearchSuggestion> suggestions,
      ValueChanged<String>? onSelect,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchSuggestionList(
            suggestions: suggestions,
            onSelect: onSelect ?? (_) {},
          ),
        ),
      ),
    );

    testWidgets('renders each suggestion and reports selection', (
      tester,
    ) async {
      String? picked;
      await pump(
        tester,
        suggestions: const [
          SearchSuggestion(text: '修仙精品小说', highlighted: '<em>修仙</em>精品小说'),
          SearchSuggestion(text: '穿越+系统+修仙'),
        ],
        onSelect: (value) => picked = value,
      );
      expect(find.byKey(const Key('search_suggestions')), findsOneWidget);
      // A highlighted suggestion is rich text, a plain one is a Text widget.
      expect(find.text('修仙精品小说', findRichText: true), findsOneWidget);
      expect(find.text('穿越+系统+修仙'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('search_suggestion_穿越+系统+修仙')),
      );
      await tester.pump();
      expect(picked, '穿越+系统+修仙');
    });

    testWidgets('the highlight is kept as rich text, tags stripped', (
      tester,
    ) async {
      await pump(
        tester,
        suggestions: const [
          SearchSuggestion(text: '修仙精品小说', highlighted: '<em>修仙</em>精品小说'),
        ],
      );
      final rich = tester.widget<RichText>(find.byType(RichText).last);
      final plain = rich.text.toPlainText();
      // The markup itself must never be shown.
      expect(plain, '修仙精品小说');
      expect(plain.contains('<em>'), isFalse);
    });

    testWidgets('an empty list renders nothing', (tester) async {
      await pump(tester, suggestions: const []);
      expect(find.byKey(const Key('search_suggestions')), findsNothing);
    });
  });

  group('HotSearchBoard', () {
    testWidgets('renders words and reports selection', (tester) async {
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HotSearchBoard(
              hot: const HotSearch(words: ['洞房夜，摸到了老婆的狐狸耳朵', '看过的书']),
              onSelect: (value) => picked = value,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('search_hot_words')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search_hot_看过的书')));
      await tester.pump();
      expect(picked, '看过的书');
    });

    testWidgets('an empty board renders nothing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HotSearchBoard(hot: HotSearch.empty, onSelect: (_) {}),
          ),
        ),
      );
      expect(find.byKey(const Key('search_hot_words')), findsNothing);
    });
  });

  group('SearchPage discovery', () {
    Future<void> pump(
      WidgetTester tester, {
      required SearchSuggestLoader suggest,
      required HotSearchLoader hot,
    }) => tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader: (query, {required tabType, required offset}) async =>
              const [],
          historyStore: _MemoryHistory(),
          suggestLoader: suggest,
          hotSearchLoader: hot,
        ),
      ),
    );

    testWidgets('shows the hot board while the query is empty', (tester) async {
      await pump(
        tester,
        suggest: (_) async => const [],
        hot: () async => const HotSearch(words: ['热搜词']),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search_hot_words')), findsOneWidget);
      expect(find.text('热搜词'), findsOneWidget);
    });

    testWidgets('typing shows suggestions after the debounce', (tester) async {
      final queries = <String>[];
      await pump(
        tester,
        suggest: (query) async {
          queries.add(query);
          return const [SearchSuggestion(text: '修仙精品小说')];
        },
        hot: () async => HotSearch.empty,
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '修仙');
      // Not yet: the debounce has not elapsed.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('search_suggestions')), findsNothing);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(queries, ['修仙']);
      expect(find.byKey(const Key('search_suggestions')), findsOneWidget);
    });

    testWidgets('tapping a suggestion runs that search', (tester) async {
      final searched = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            searchLoader: (query, {required tabType, required offset}) async {
              searched.add(query);
              return const [];
            },
            historyStore: _MemoryHistory(),
            suggestLoader: (_) async => const [
              SearchSuggestion(text: '修仙精品小说'),
            ],
            hotSearchLoader: () async => const HotSearch(words: ['热搜词']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '修仙');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('search_suggestion_修仙精品小说')));
      await tester.pumpAndSettle();
      expect(searched, contains('修仙精品小说'));
      // Once a search has run, the suggestion panel yields to the results.
      expect(find.byKey(const Key('search_suggestions')), findsNothing);
    });

    testWidgets('clearing the field drops stale suggestions', (tester) async {
      await pump(
        tester,
        suggest: (_) async => const [SearchSuggestion(text: '修仙精品小说')],
        hot: () async => HotSearch.empty,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '修仙');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search_suggestions')), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search_suggestions')), findsNothing);
    });
  });

  group('AuthorPage', () {
    Future<void> pump(
      WidgetTester tester, {
      AuthorLoader? loader,
      String id = '1988336383174046',
    }) => tester.pumpWidget(
      MaterialApp(
        home: AuthorPage(
          authorId: id,
          fallbackName: '七彩虹桥的吕师傅',
          loader: loader ?? (_) async => _author,
        ),
      ),
    );

    testWidgets('shows the profile and every work', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('author_name')), findsOneWidget);
      expect(find.text('作家Lv.5'), findsOneWidget);
      expect(find.text('2.1万粉丝 · 5 部作品'), findsOneWidget);
      expect(find.byKey(const Key('author_description')), findsOneWidget);
      expect(find.text('全部作品'), findsOneWidget);
      expect(find.text('发现青梅真香且喜欢我，我重生了'), findsOneWidget);
    });

    testWidgets('a failure offers a retry that reloads', (tester) async {
      var attempts = 0;
      await pump(
        tester,
        loader: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return _author;
        },
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('author_retry')), findsOneWidget);
      expect(find.text('作家Lv.5'), findsNothing);

      await tester.tap(find.byKey(const Key('author_retry')));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('作家Lv.5'), findsOneWidget);
    });

    testWidgets('an empty profile reports it instead of spinning', (
      tester,
    ) async {
      await pump(tester, loader: (_) async => AuthorProfile.empty);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('author_retry')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an author with no works still shows the header', (
      tester,
    ) async {
      await pump(
        tester,
        loader: (_) async =>
            const AuthorProfile(id: '1', name: '无作品作者', followerCount: 12),
      );
      await tester.pumpAndSettle();
      expect(find.text('无作品作者'), findsWidgets);
      expect(find.text('暂无可展示的作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('RankPage', () {
    Future<void> pump(
      WidgetTester tester, {
      RankPageLoader? pageLoader,
      RankCatalogLoader? catalogLoader,
    }) => tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          catalogLoader: catalogLoader ?? () async => _catalog,
          pageLoader:
              pageLoader ??
              ({
                required rankId,
                required algo,
                required categoryId,
                required offset,
                required startAt,
              }) async => _board(),
        ),
      ),
    );

    testWidgets('loads the first rank and lists its entries', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rank_list')), findsOneWidget);
      expect(find.text('锦衣夜行九万里 0'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
      expect(find.text('安岳的白沐潼 · 传统玄幻 · 连载中'), findsWidgets);
    });

    testWidgets('switching rank asks for the new algo', (tester) async {
      final requests = <int>[];
      await pump(
        tester,
        pageLoader:
            ({
              required rankId,
              required algo,
              required categoryId,
              required offset,
              required startAt,
            }) async {
              requests.add(algo);
              return _board();
            },
      );
      await tester.pumpAndSettle();
      expect(requests, [200]);

      await tester.tap(find.byKey(const ValueKey('rank_tab_100')));
      await tester.pumpAndSettle();
      expect(requests, [200, 100]);
    });

    testWidgets('switching category asks for the new sub id', (tester) async {
      final requests = <int>[];
      await pump(
        tester,
        pageLoader:
            ({
              required rankId,
              required algo,
              required categoryId,
              required offset,
              required startAt,
            }) async {
              requests.add(categoryId);
              return _board();
            },
      );
      await tester.pumpAndSettle();
      expect(requests, [0]);

      await tester.tap(find.byKey(const ValueKey('rank_category_37')));
      await tester.pumpAndSettle();
      expect(requests, [0, 37]);
    });

    testWidgets('a later page continues the numbering', (tester) async {
      final starts = <int>[];
      await pump(
        tester,
        pageLoader:
            ({
              required rankId,
              required algo,
              required categoryId,
              required offset,
              required startAt,
            }) async {
              starts.add(startAt);
              return offset == 0
                  ? _board(hasMore: true, count: 30)
                  : _board(startAt: startAt, count: 5);
            },
      );
      await tester.pumpAndSettle();
      expect(starts, [1]);

      // Scroll to the bottom to trigger the next page.
      await tester.drag(
        find.byKey(const Key('rank_list')),
        const Offset(0, -6000),
      );
      await tester.pumpAndSettle();
      expect(starts, [1, 31]);
      // The continuation is numbered after the first page, not restarted.
      expect(find.text('31'), findsOneWidget);
    });

    testWidgets('an empty catalogue reports it and can retry', (tester) async {
      var attempts = 0;
      await pump(
        tester,
        catalogLoader: () async {
          attempts++;
          if (attempts == 1) return RankCatalog.empty;
          return _catalog;
        },
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rank_retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('rank_retry')));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.byKey(const Key('rank_list')), findsOneWidget);
    });

    testWidgets('a failing page load can be retried', (tester) async {
      var attempts = 0;
      await pump(
        tester,
        pageLoader:
            ({
              required rankId,
              required algo,
              required categoryId,
              required offset,
              required startAt,
            }) async {
              attempts++;
              if (attempts == 1) throw StateError('offline');
              return _board();
            },
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rank_retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('rank_retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rank_list')), findsOneWidget);
    });
  });

  group('DetailReviews replies', () {
    final comments = [
      const BookComment(
        id: '7532767563971527448',
        text: '太好看了',
        userName: '读者',
        replyCount: 5,
        diggCount: 3,
      ),
    ];

    Future<void> pump(WidgetTester tester, {ReviewReplyLoader? replyLoader}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DetailReviews(
                  page: BookCommentPage(comments: comments, totalCount: 1),
                  bookId: '7491705400958405694',
                  replyLoader: replyLoader,
                ),
              ),
            ),
          ),
        );

    testWidgets('replies load lazily on tap, not up front', (tester) async {
      var calls = 0;
      await pump(
        tester,
        replyLoader: (commentId) async {
          calls++;
          expect(commentId, '7532767563971527448');
          return const CommentReplyPage(
            totalCount: 5,
            replies: [
              CommentReply(
                id: 'r1',
                text: '不就是虐文吗？等我消息',
                userName: '^沈菥.',
                diggCount: 3,
              ),
            ],
          );
        },
      );
      // Nothing fetched until the reader asks.
      expect(calls, 0);
      expect(find.text('回复 5'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('detail_reply_toggle_7532767563971527448')),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('不就是虐文吗？等我消息'), findsOneWidget);
      expect(find.text('^沈菥.'), findsOneWidget);
    });

    testWidgets('tapping again collapses the replies', (tester) async {
      await pump(
        tester,
        replyLoader: (_) async => const CommentReplyPage(
          totalCount: 5,
          replies: [CommentReply(id: 'r1', text: '第一条回复')],
        ),
      );
      final toggle = find.byKey(
        const ValueKey('detail_reply_toggle_7532767563971527448'),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('第一条回复'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('第一条回复'), findsNothing);
    });

    testWidgets('a failed load is reported without breaking the list', (
      tester,
    ) async {
      await pump(tester, replyLoader: (_) async => throw StateError('offline'));
      await tester.tap(
        find.byKey(const ValueKey('detail_reply_toggle_7532767563971527448')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('detail_reply_error_7532767563971527448')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('no loader means no reply affordance', (tester) async {
      await pump(tester);
      // The count is still shown, but it is not a control.
      expect(
        find.byKey(const ValueKey('detail_reply_toggle_7532767563971527448')),
        findsNothing,
      );
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('an empty reply list says so', (tester) async {
      await pump(
        tester,
        replyLoader: (_) async => const CommentReplyPage(totalCount: 5),
      );
      await tester.tap(
        find.byKey(const ValueKey('detail_reply_toggle_7532767563971527448')),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无回复'), findsOneWidget);
    });
  });

  group('detail chapter preview', () {
    testWidgets('media item preview keeps the id and title', (tester) async {
      // The author and rank pages hand a summary to the detail page; the item
      // must carry the id so the detail page can resolve the real record.
      const work = AuthorWork(id: '42', title: '作品');
      expect(work.id, '42');
      final item = MediaItem(
        id: work.id,
        title: work.title,
        cover: work.cover,
        author: '',
        badge: work.category,
        ep: '',
        kind: 'book',
      );
      expect(item.id, '42');
      expect(item.kind, 'book');
    });
  });
}
