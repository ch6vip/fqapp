import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';

void main() {
  for (final oldFails in [false, true]) {
    testWidgets(
      'latest filter wins over an in-flight page (old error: $oldFails)',
      (tester) async {
        final old = Completer<PlayletCommentPage>();
        final latest = Completer<PlayletCommentPage>();
        final sorts = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlayletCommentPanel(
                seriesId: 's1',
                loader:
                    ({
                      required sort,
                      required count,
                      required cursor,
                      required tag,
                    }) {
                      sorts.add(sort);
                      return sort == UgcSort.smartHot
                          ? old.future
                          : latest.future;
                    },
              ),
            ),
          ),
        );
        await tester.tap(find.text('最新'));
        await tester.pump();
        expect(sorts, [UgcSort.smartHot, UgcSort.timeDesc]);
        latest.complete(
          const PlayletCommentPage(
            comments: [PlayletComment(id: 'new', text: '新排序结果')],
          ),
        );
        await tester.pumpAndSettle();
        if (oldFails) {
          old.completeError(Exception('old request failed'));
        } else {
          old.complete(
            const PlayletCommentPage(
              comments: [PlayletComment(id: 'old', text: '过期结果')],
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('新排序结果'), findsOneWidget);
        expect(find.text('过期结果'), findsNothing);
        expect(find.text('评论加载失败'), findsNothing);
      },
    );
  }

  testWidgets(
    'failed comment pagination keeps content and retries the same cursor',
    (tester) async {
      final cursors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayletCommentPanel(
              seriesId: 's1',
              loader:
                  ({
                    required sort,
                    required count,
                    required cursor,
                    required tag,
                  }) async {
                    cursors.add(cursor);
                    if (cursors.length == 1) {
                      return const PlayletCommentPage(
                        comments: [PlayletComment(id: 'first', text: '保留评论')],
                        hasMore: true,
                        cursor: 'next',
                      );
                    }
                    if (cursors.length == 2) throw Exception('offline');
                    return const PlayletCommentPage(
                      comments: [PlayletComment(id: 'last', text: '后续评论')],
                    );
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text('保留评论'), findsOneWidget);
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(cursors, ['', 'next', 'next']);
      expect(find.text('后续评论'), findsOneWidget);
    },
  );
}
