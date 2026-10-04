import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/widgets/detail/detail_reviews.dart';
import 'package:fqapp/widgets/detail/detail_reviews_sheet.dart';

void main() {
  testWidgets('DetailReviews limits preview comments to 3 and triggers onOpenAll', (
    tester,
  ) async {
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

    // Only 3 comments rendered in preview
    expect(find.byType(DetailCommentTile), findsNWidgets(3));
    expect(find.text('评论内容 0'), findsOneWidget);
    expect(find.text('评论内容 1'), findsOneWidget);
    expect(find.text('评论内容 2'), findsOneWidget);
    expect(find.text('评论内容 3'), findsNothing);

    // Bottom "查看全部 42 条书评" button rendered
    expect(find.text('查看全部 42 条书评'), findsOneWidget);

    // Tapping bottom button triggers onOpenAll
    await tester.tap(find.text('查看全部 42 条书评'));
    expect(opened, isTrue);

    // Tapping top button with key detail_reviews_more also triggers onOpenAll
    opened = false;
    await tester.tap(find.byKey(const Key('detail_reviews_more')));
    expect(opened, isTrue);
  });

  testWidgets('DetailReviewsSheet renders comments, pagination, and Lucide icons', (
    tester,
  ) async {
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
  });

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
  });
}
