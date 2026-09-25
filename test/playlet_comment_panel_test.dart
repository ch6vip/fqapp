import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';

/// 评论面板的交互用例：官方筛选、分页、空态、失败重试。
///
/// 取值依据 .agents/notes/proposed/architecture/2026-09-25-f04-official-evidence.md：
/// 「全部」=`UgcSort.smartHot`、「最新」=`UgcSort.timeDesc`（`gx1/n0.java:1631-1645`），
/// 分页首页 `need_count=true` 之后带 cursor（`gx1/m.java:183-245`），
/// 空态随计数变化（`gx1/n0.java:698-708`）。
void main() {
  PlayletComment comment(String id, {String text = '好看'}) =>
      PlayletComment(id: id, text: text, userName: '小明', diggCount: 2);

  Future<void> pumpPanel(
    WidgetTester tester, {
    required PlayletCommentPageLoader loader,
    int total = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletCommentPanel(
            seriesId: '123',
            loader: loader,
            initialTotal: total,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the first page uses the smart-hot sort and shows the list', (
    tester,
  ) async {
    final calls = <Map<String, Object>>[];
    await pumpPanel(
      tester,
      loader: ({required sort, required count, required cursor, required tag}) async {
        calls.add({'sort': sort, 'count': count, 'cursor': cursor, 'tag': tag});
        return PlayletCommentPage(
          comments: [comment('c1'), comment('c2')],
          totalCount: 2,
        );
      },
    );
    expect(calls.single['sort'], UgcSort.smartHot);
    expect(calls.single['count'], 10);
    expect(calls.single['cursor'], '');
    expect(find.byKey(const ValueKey('playlet-comment-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('playlet-comment-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('playlet-comment-total')), findsOneWidget);
  });

  testWidgets('the 最新 filter switches to TimeDesc and reloads', (tester) async {
    final sorts = <int>[];
    await pumpPanel(
      tester,
      loader: ({required sort, required count, required cursor, required tag}) async {
        sorts.add(sort);
        return PlayletCommentPage(comments: [comment('c1')], totalCount: 1);
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('playlet-comment-filter-最新')),
    );
    await tester.pumpAndSettle();
    expect(sorts, [UgcSort.smartHot, UgcSort.timeDesc]);
  });

  testWidgets('scrolling to the end loads the next cursor page', (tester) async {
    final cursors = <String>[];
    var page = 0;
    await pumpPanel(
      tester,
      loader: ({required sort, required count, required cursor, required tag}) async {
        cursors.add(cursor);
        page++;
        if (page == 1) {
          return PlayletCommentPage(
            comments: [for (var i = 0; i < 10; i++) comment('p1-$i')],
            totalCount: 12,
            hasMore: true,
            cursor: 'CURSOR-1',
          );
        }
        return PlayletCommentPage(
          comments: [comment('p2-0'), comment('p2-1')],
          totalCount: 12,
        );
      },
    );
    expect(cursors, ['']);
    // 面板高度是屏高 0.62，10 条不够触底；直接滚到底再等分页。
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('playlet-comment-list')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(cursors, ['', 'CURSOR-1']);
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlet-comment-p2-1')), findsOneWidget);
  });

  testWidgets('an empty list shows the official copy that matches the count', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      loader: ({required sort, required count, required cursor, required tag}) async =>
          const PlayletCommentPage(totalCount: 0),
    );
    expect(find.text('期待你的第一条剧评'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    await pumpPanel(
      tester,
      loader: ({required sort, required count, required cursor, required tag}) async =>
          const PlayletCommentPage(totalCount: 7),
    );
    expect(find.text('无相关剧评'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry that refetches', (tester) async {
    var attempts = 0;
    await pumpPanel(
      tester,
      loader: ({required sort, required count, required cursor, required tag}) async {
        attempts++;
        if (attempts == 1) throw Exception('offline');
        return PlayletCommentPage(comments: [comment('c1')], totalCount: 1);
      },
    );
    expect(find.byKey(const ValueKey('playlet-comment-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlet-comment-retry')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byKey(const ValueKey('playlet-comment-c1')), findsOneWidget);
  });

  testWidgets('the close button dismisses the sheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => PlayletCommentPanel.show(
                context,
                seriesId: '123',
                loader:
                    ({
                      required sort,
                      required count,
                      required cursor,
                      required tag,
                    }) async => PlayletCommentPage(
                      comments: [comment('c1')],
                      totalCount: 1,
                    ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlet-comment-c1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlet-comment-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlet-comment-c1')), findsNothing);
  });
}
