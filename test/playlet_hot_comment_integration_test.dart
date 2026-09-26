import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'package:fqapp/models/playlet_comment.dart';

import 'support/fakes.dart';
import 'package:flutter/material.dart';

/// 播放页热评行的接入用例：仅在有热评、竖屏、未清屏/锁定时出现，
/// 点击回调带上当前那条。
void main() {
  PlayletComment comment(String id) =>
      PlayletComment(id: id, text: '内容$id', userName: '小明');

  Widget app({
    required bool shortSeries,
    List<PlayletComment> hot = const [],
    ValueChanged<PlayletComment>? onTap,
  }) {
    final player = FakeNativePlayer()..isPlaying = true;
    addTearDown(player.dispose);
    return MaterialApp(
      home: Scaffold(
        body: VideoPlayerChrome(
          player: player,
          title: '剧',
          episodes: [Chapter(itemId: '1', title: '第一集', volumeName: '')],
          currentIndex: 0,
          duration: const Duration(minutes: 2),
          playing: true,
          shortSeries: shortSeries,
          hotComments: hot,
          onHotCommentTap: onTap,
          onSelectEpisode: (_) async {},
          onError: (error) => throw error,
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
  }

  testWidgets('the hot bar is absent without data and for non-shortseries', (
    tester,
  ) async {
    await tester.pumpWidget(app(shortSeries: true));
    await tester.pumpAndSettle();
    expect(find.text('热评'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.pumpWidget(app(shortSeries: false, hot: [comment('c1')]));
    await tester.pumpAndSettle();
    expect(find.text('热评'), findsNothing, reason: '通用播放器没有热评位');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the hot bar appears in portrait and reports its tap', (
    tester,
  ) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      app(
        shortSeries: true,
        hot: [comment('c1')],
        onTap: (c) => tapped.add(c.id),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlet-hot-comment-c1')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('playlet-hot-comment-c1')));
    expect(
      tester
          .getRect(find.byKey(const ValueKey('playlet-hot-comment-c1')))
          .overlaps(
            tester.getRect(find.byKey(const ValueKey('video-seek-layer'))),
          ),
      isFalse,
      reason: '没有原著卡时，热评也不能落入进度拖动触区',
    );
    expect(tapped, ['c1']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'clearing the screen hides the hot bar with the rest of the chrome',
    (tester) async {
      await tester.pumpWidget(app(shortSeries: true, hot: [comment('c1')]));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('playlet-hot-comment-c1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('playlet-hot-comment-c1')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
