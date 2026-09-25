import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';

/// 点赞与回复的用例。
///
/// 官方行为依据：点赞走独立 digg 接口、失败回滚
/// （`gx1/n0.java:489-509` 的本地乐观更新；`social/t.java:803-831` 的请求），
/// 回复走 `reply/add`（`nx1/d.java:217-231`），编辑器带「回复 @某某」。
void main() {
  PlayletComment comment(String id, {bool userDigg = false, int digg = 3}) =>
      PlayletComment(
        id: id,
        text: '好看',
        userName: '小明',
        diggCount: digg,
        userDigg: userDigg,
      );

  Future<void> pump(
    WidgetTester tester, {
    List<PlayletComment> comments = const [],
    Future<void> Function(PlayletComment, bool)? digg,
    Future<void> Function(PlayletComment, String)? reply,
    Future<void> Function(String)? submit,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletCommentPanel(
            seriesId: '123',
            diggComment: digg,
            replyComment: reply,
            submitComment: submit,
            loader:
                ({required sort, required count, required cursor, required tag}) async =>
                    PlayletCommentPage(comments: comments, totalCount: comments.length),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a like updates locally and reports the toggle', (tester) async {
    final calls = <String>[];
    await pump(
      tester,
      comments: [comment('c1')],
      digg: (c, liked) async => calls.add('${c.id}:$liked'),
    );
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlet-comment-like-c1')));
    await tester.pumpAndSettle();
    expect(calls, ['c1:true']);
    // 官方本地乐观更新：计数立刻 +1，图标变选中的实心。
    expect(find.byIcon(Icons.thumb_up_alt_rounded), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('a failed like rolls the local state back', (tester) async {
    await pump(
      tester,
      comments: [comment('c1')],
      digg: (c, liked) async => throw Exception('未登录'),
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-like-c1')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_up_alt_rounded), findsNothing);
    expect(find.text('3'), findsOneWidget, reason: '失败必须回滚计数');
    // 原始异常不上屏，给的是统一文案。
    expect(find.text('加载失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('cancelling a like never drives the count below zero', (
    tester,
  ) async {
    final calls = <String>[];
    await pump(
      tester,
      comments: [comment('c1', userDigg: true, digg: 0)],
      digg: (c, liked) async => calls.add('$liked'),
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-like-c1')));
    await tester.pumpAndSettle();
    expect(calls, ['false']);
    // 计数不能被减成负数：文本是单个 '0'（回复计数也是 0，所以按出现次数断言）。
    expect(find.text('0'), findsNWidgets(2));
  });

  testWidgets('without a digg callback the like row is read-only', (
    tester,
  ) async {
    await pump(tester, comments: [comment('c1')]);
    await tester.tap(find.byKey(const ValueKey('playlet-comment-like-c1')));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_alt_rounded), findsNothing);
  });

  testWidgets('replying targets the tapped comment and goes through reply/add', (
    tester,
  ) async {
    final replied = <String>[];
    await pump(
      tester,
      comments: [comment('c1')],
      reply: (c, text) async => replied.add('${c.id}:$text'),
    );
    expect(find.byKey(const ValueKey('playlet-comment-reply-target')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlet-comment-reply-c1')));
    await tester.pumpAndSettle();
    expect(find.text('回复 @小明'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('playlet-comment-input')),
      '同感',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-send')));
    await tester.pumpAndSettle();
    expect(replied, ['c1:同感']);
    expect(
      find.byKey(const ValueKey('playlet-comment-reply-target')),
      findsNothing,
      reason: '发送成功后回复目标要复位',
    );
  });

  testWidgets('the reply target can be cancelled before sending', (tester) async {
    final replied = <String>[];
    final submitted = <String>[];
    await pump(
      tester,
      comments: [comment('c1')],
      reply: (c, text) async => replied.add(text),
      submit: (text) async => submitted.add(text),
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-reply-c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlet-comment-reply-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlet-comment-reply-target')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('playlet-comment-input')),
      '普通评论',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-send')));
    await tester.pumpAndSettle();
    expect(replied, isEmpty);
    expect(submitted, ['普通评论'], reason: '取消回复后回到发评论');
  });

  testWidgets('a failed reply keeps the target so the user can retry', (
    tester,
  ) async {
    await pump(
      tester,
      comments: [comment('c1')],
      reply: (c, text) async => throw Exception('网络开小差'),
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-reply-c1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('playlet-comment-input')),
      '草稿',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-send')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlet-comment-reply-target')),
      findsOneWidget,
    );
  });
}
