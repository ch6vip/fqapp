import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';
import 'package:fqapp/widgets/player/playlet_reply_panel.dart';

void main() {
  const comment = PlayletComment(
    id: 'c1',
    text: '剧情讨论',
    userName: '小明',
    diggCount: 3,
    replyCount: 2,
  );

  Future<void> pump(
    WidgetTester tester, {
    required PlayletReplyPageLoader replies,
    String focusCommentId = '',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletCommentPanel(
            seriesId: '123',
            focusCommentId: focusCommentId,
            replyLoader: replies,
            loader:
                ({
                  required sort,
                  required count,
                  required cursor,
                  required tag,
                }) async => const PlayletCommentPage(
                  comments: [comment],
                  totalCount: 1,
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('anonymous replies page through the selected comment', (
    tester,
  ) async {
    final calls = <String>[];
    await pump(
      tester,
      replies: ({required commentId, required count, required cursor}) async {
        calls.add('$commentId:$cursor');
        expect(count, 10);
        return cursor.isEmpty
            ? const CommentReplyPage(
                replies: [CommentReply(id: 'r1', text: '第一条回复')],
                totalCount: 2,
                cursor: 'next',
                hasMore: true,
              )
            : const CommentReplyPage(
                replies: [
                  CommentReply(id: 'r1', text: '第一条回复'),
                  CommentReply(id: 'r2', text: '第二条回复'),
                ],
                totalCount: 2,
              );
      },
    );
    expect(find.byType(TextField), findsNothing);
    // 服务端点赞数是只读内容，点击不会伪造计数或显示登录入口。
    await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(calls, isEmpty);
    await tester.tap(find.text('2 条回复'));
    await tester.pumpAndSettle();
    expect(calls, ['c1:']);
    expect(find.text('第一条回复'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlet-replies-more')));
    await tester.pumpAndSettle();
    expect(calls, ['c1:', 'c1:next']);
    expect(find.text('第一条回复'), findsOneWidget, reason: '分页交叠不能重复显示');
    expect(find.text('第二条回复'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlet-replies-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlet-comment-c1')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playlet-comment-filter-全部')),
      findsOneWidget,
    );
    expect(find.text('发布'), findsNothing);
  });

  testWidgets(
    'reply pagination failures preserve the list and retry the cursor',
    (tester) async {
      final cursors = <String>[];
      await pump(
        tester,
        replies: ({required commentId, required count, required cursor}) async {
          cursors.add(cursor);
          if (cursors.length == 1) {
            return const CommentReplyPage(
              replies: [CommentReply(id: 'r1', text: '已读回复')],
              totalCount: 2,
              cursor: 'next',
              hasMore: true,
            );
          }
          if (cursors.length == 2) throw Exception('offline');
          return const CommentReplyPage(
            replies: [CommentReply(id: 'r2', text: '重试成功')],
          );
        },
      );
      await tester.tap(find.text('2 条回复'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('playlet-replies-more')));
      await tester.pumpAndSettle();
      expect(find.text('已读回复'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('playlet-replies-retry')));
      await tester.pumpAndSettle();
      expect(cursors, ['', 'next', 'next']);
      expect(find.text('重试成功'), findsOneWidget);
    },
  );

  testWidgets(
    'hot comments retain their parent discussion and anonymous replies',
    (tester) async {
      final requested = <String>[];
      await pump(
        tester,
        focusCommentId: 'c1',
        replies: ({required commentId, required count, required cursor}) async {
          requested.add(commentId);
          return const CommentReplyPage(
            replies: [CommentReply(id: 'r2', text: '讨论回复')],
          );
        },
      );
      expect(find.byKey(const ValueKey('playlet-comment-c1')), findsOneWidget);
      await tester.tap(find.text('2 条回复'));
      await tester.pumpAndSettle();
      expect(requested, ['c1']);
      expect(find.text('讨论回复'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('empty replies have a return path without an editor', (
    tester,
  ) async {
    await pump(
      tester,
      replies: ({required commentId, required count, required cursor}) async =>
          CommentReplyPage.empty,
    );
    await tester.tap(find.text('2 条回复'));
    await tester.pumpAndSettle();
    expect(find.text('暂无回复'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlet-replies-back')));
    await tester.pumpAndSettle();
    expect(find.text('全部'), findsOneWidget);
  });
}
