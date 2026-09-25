import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_hot_comment_bar.dart';

/// 热评胶囊的官方行为：第 0 条常显、条数 >1 时每 5 秒换下一条、
/// 点击回调带上当前那条（官方据此组 hot_comment_id/hot_reply_id）。
///
/// 取值依据 `SeriesHotCommentView.java:600`（取第 0 条）、`:98-129`
/// （CountDownTimer(5000,5000)）、`:287-296`（200ms 位移+淡入）。
void main() {
  PlayletComment comment(String id, {int roleType = 0}) => PlayletComment(
    id: id,
    text: '内容$id',
    userName: '小明',
    playletRoleType: roleType,
  );

  Widget app(List<PlayletComment> comments, {ValueChanged<PlayletComment>? onTap}) =>
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: PlayletHotCommentBar(comments: comments, onTap: onTap),
          ),
        ),
      );

  testWidgets('an empty list renders nothing at all', (tester) async {
    await tester.pumpWidget(app(const []));
    expect(find.text('热评'), findsNothing);
    expect(find.byType(DecoratedBox), findsNothing);
  });

  testWidgets('a single comment stays on screen without a carousel', (
    tester,
  ) async {
    await tester.pumpWidget(app([comment('c1')]));
    expect(find.byKey(const ValueKey('playlet-hot-comment-c1')), findsOneWidget);
    expect(find.textContaining('内容c1'), findsOneWidget);
    // 5 秒后仍然只有第一条：官方只在条数 >1 时起定时器。
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('playlet-hot-comment-c1')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('playlet-hot-comment-c1')), findsOneWidget);
  });

  testWidgets('two comments rotate every five seconds and wrap around', (
    tester,
  ) async {
    await tester.pumpWidget(app([comment('c1'), comment('c2')]));
    expect(find.byKey(const ValueKey('playlet-hot-comment-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('playlet-hot-comment-c2')), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('playlet-hot-comment-c2')), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('playlet-hot-comment-c1')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the role prefix follows playlet_role_type', (tester) async {
    await tester.pumpWidget(app([comment('actor', roleType: 1)]));
    expect(find.textContaining('演员说：'), findsOneWidget);
    await tester.pumpWidget(app([comment('lead', roleType: 2)]));
    expect(find.textContaining('主演说：'), findsOneWidget);
    await tester.pumpWidget(app([comment('plain')]));
    expect(find.textContaining('热评：'), findsOneWidget);
  });

  testWidgets('tapping reports the comment currently shown', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      app([comment('c1'), comment('c2')], onTap: (c) => tapped.add(c.id)),
    );
    await tester.tap(find.byKey(const ValueKey('playlet-hot-comment-c1')));
    expect(tapped, ['c1']);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('playlet-hot-comment-c2')));
    expect(tapped, ['c1', 'c2']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
