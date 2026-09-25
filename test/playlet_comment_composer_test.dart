import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';

/// 评论输入条的用例：官方编辑器语义——空串不发、发送失败保留草稿并提示、
/// 成功后清空并重拉第一页。
void main() {
  PlayletComment comment(String id) =>
      PlayletComment(id: id, text: '好看', userName: '小明');

  Future<void> pump(
    WidgetTester tester, {
    required Future<void> Function(String) submit,
    List<String>? submitted,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletCommentPanel(
            seriesId: '123',
            submitComment: submit,
            loader:
                ({required sort, required count, required cursor, required tag}) async =>
                    PlayletCommentPage(comments: [comment('c1')], totalCount: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the composer sends the trimmed text and clears afterwards', (
    tester,
  ) async {
    final sent = <String>[];
    await pump(tester, submit: (text) async => sent.add(text));
    await tester.enterText(
      find.byKey(const ValueKey('playlet-comment-input')),
      '  这条真好  ',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-send')));
    await tester.pumpAndSettle();
    expect(sent, ['这条真好']);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('playlet-comment-input')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('an empty input never calls the API', (tester) async {
    final sent = <String>[];
    await pump(tester, submit: (text) async => sent.add(text));
    await tester.enterText(
      find.byKey(const ValueKey('playlet-comment-input')),
      '    ',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-send')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
  });

  testWidgets('a failed publish keeps the draft and shows the reason', (
    tester,
  ) async {
    await pump(
      tester,
      submit: (text) async => throw Exception('网络开小差了'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('playlet-comment-input')),
      '草稿',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-comment-send')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('playlet-comment-input')))
          .controller!
          .text,
      '草稿',
      reason: '失败不能吞掉用户输入的草稿',
    );
    // 原始异常不得直接上屏（理由见 user_facing_error.dart），面板给出的
    // 是统一的用户文案。
    expect(find.text('加载失败，请稍后重试'), findsOneWidget);
  });
}
