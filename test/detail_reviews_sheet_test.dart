import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/widgets/detail/detail_reviews.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';
import 'package:fqapp/widgets/home/home_stream_footer.dart';
import 'package:fqapp/widgets/reader/reader_illustration.dart';
import 'package:fqapp/widgets/detail/detail_reviews_sheet.dart';

void main() {
  testWidgets(
    'image-only book reviews display an image without an empty body',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DetailCommentTile(
              comment: BookComment(
                id: 'image-review',
                imageUrls: ['https://example.test/review.jpg'],
              ),
            ),
          ),
        ),
      );
      expect(find.byType(ReaderIllustration), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail_review_text_image-review')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'DetailReviews limits preview comments to 3 and triggers onOpenAll',
    (tester) async {
      var opened = false;
      final comments = List.generate(
        6,
        (i) => BookComment(
          id: 'c_$i',
          text: '评论内容 $i',
          userName: '读者 $i',
          replyCount: i,
          diggCount: i * 2,
        ),
      );
      final page = BookCommentPage(
        comments: comments,
        totalCount: 42,
        hasMore: true,
        nextOffset: 6,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DetailReviews(
                page: page,
                bookId: 'test_book',
                onOpenAll: () => opened = true,
              ),
            ),
          ),
        ),
      );

      // 预览只渲染 3 条，用的是紧凑样式（不是弹层里的 DetailCommentTile）。
      expect(find.byType(DetailCommentTile), findsNothing);
      expect(
        find.byKey(const ValueKey('detail_review_text_c_0')),
        findsOneWidget,
      );
      expect(find.text('评论内容 0'), findsOneWidget);
      expect(find.text('评论内容 1'), findsOneWidget);
      expect(find.text('评论内容 2'), findsOneWidget);
      expect(find.text('评论内容 3'), findsNothing);

      // 改版后只保留头部一个「全部」入口，不再在底部重复一个按钮。
      expect(find.text('查看全部 42 条书评'), findsNothing);
      expect(find.textContaining('42 条 · 全部'), findsOneWidget);

      await tester.tap(find.byKey(const Key('detail_reviews_more')));
      expect(opened, isTrue);
    },
  );

  testWidgets(
    'DetailReviewsSheet renders comments, pagination, and Lucide icons',
    (tester) async {
      final comments = [
        const BookComment(
          id: 'c_1',
          text: '写的真不错',
          userName: '书友小李',
          replyCount: 2,
          diggCount: 10,
        ),
        const BookComment(
          id: 'c_2',
          text: '第二条书评',
          userName: '书友小张',
          replyCount: 0,
          diggCount: 5,
        ),
      ];

      var loaderCalls = 0;
      final initialPage = BookCommentPage(
        comments: comments,
        totalCount: 3,
        hasMore: true,
        nextOffset: 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDetailReviewsSheet(
                  context,
                  bookId: 'book_123',
                  title: '测试书籍标题',
                  initialComments: initialPage,
                  loader: (offset) async {
                    loaderCalls++;
                    return const BookCommentPage(
                      comments: [
                        BookComment(
                          id: 'c_3',
                          text: '第三条追加书评',
                          userName: '书友小王',
                        ),
                      ],
                      totalCount: 3,
                      hasMore: false,
                    );
                  },
                ),
                child: const Text('打开全部书评'),
              ),
            ),
          ),
        ),
      );

      // Open sheet
      await tester.tap(find.text('打开全部书评'));
      await tester.pumpAndSettle();

      // Verify title and total count
      expect(find.text('全部书评 · 3'), findsOneWidget);
      expect(find.text('测试书籍标题'), findsOneWidget);

      // Verify comments rendered
      expect(find.text('写的真不错'), findsOneWidget);
      expect(find.text('第二条书评'), findsOneWidget);

      // Verify all icons in sheet are flutter_lucide
      for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
        expect(
          icon.icon?.fontPackage,
          'flutter_lucide',
          reason: 'Icon ${icon.icon} should belong to flutter_lucide',
        );
      }

      // Scroll to bottom or tap "加载更多" to trigger pagination
      final loadMoreFinder = find.text('加载更多');
      if (loadMoreFinder.evaluate().isNotEmpty) {
        await tester.tap(loadMoreFinder);
        await tester.pumpAndSettle();
        expect(loaderCalls, 1);
        expect(find.text('第三条追加书评'), findsOneWidget);
      }
    },
  );

  testWidgets('DetailReviewsSheet handles empty state gracefully', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDetailReviewsSheet(
                context,
                bookId: 'book_empty',
                title: '无评论书籍',
                initialComments: const BookCommentPage(
                  comments: [],
                  totalCount: 0,
                  hasMore: false,
                ),
              ),
              child: const Text('打开空书评'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开空书评'));
    await tester.pumpAndSettle();

    expect(find.text('全部书评'), findsOneWidget);
    expect(find.text('暂无书评'), findsOneWidget);
    // 空态改用共享紧凑态，不再自己拼图标 + 文案。
    expect(find.byType(HomeStateView), findsOneWidget);
  });

  testWidgets('首页评论加载失败走共享错误态，重试后恢复', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDetailReviewsSheet(
                context,
                bookId: 'book_retry',
                title: '重试书籍',
                initialComments: const BookCommentPage(
                  comments: [],
                  totalCount: 0,
                  hasMore: true,
                  nextOffset: 0,
                ),
                loader: (offset) async {
                  calls++;
                  if (calls == 1) throw StateError('offline');
                  return const BookCommentPage(
                    comments: [BookComment(id: 'c1', text: '恢复后的书评')],
                    totalCount: 1,
                    hasMore: false,
                  );
                },
              ),
              child: const Text('打开重试书评'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开重试书评'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeStateView), findsOneWidget);
    expect(find.text('加载书评失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('恢复后的书评'), findsOneWidget);
  });

  testWidgets('流尾：还有更多用加载更多，到底用共享 done 文案', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDetailReviewsSheet(
                context,
                bookId: 'book_more',
                title: '分页书籍',
                initialComments: const BookCommentPage(
                  comments: [BookComment(id: 'c1', text: '第一条书评')],
                  totalCount: 2,
                  hasMore: true,
                  nextOffset: 1,
                ),
                loader: (offset) async => const BookCommentPage(
                  comments: [BookComment(id: 'c2', text: '第二条书评')],
                  totalCount: 2,
                  hasMore: false,
                ),
              ),
              child: const Text('打开分页书评'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开分页书评'));
    await tester.pumpAndSettle();
    expect(find.text('加载更多'), findsOneWidget);
    expect(find.text('已显示全部内容'), findsNothing);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    expect(find.text('第二条书评'), findsOneWidget);
    expect(find.byType(HomeStreamFooter), findsOneWidget);
    expect(find.text('已显示全部内容'), findsOneWidget);
  });
}
