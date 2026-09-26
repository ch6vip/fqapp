import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// 无账号模式保留弹幕开关与渲染，不显示发送入口。
void main() {
  Widget app({
    bool danmakuEnabled = true,
    VoidCallback? onToggle,
    List<PlayletComment> danmaku = const [],
  }) {
    final player = FakeNativePlayer()..isPlaying = true;
    addTearDown(player.dispose);
    return MaterialApp(
      home: Scaffold(
        body: VideoPlayerChrome(
          player: player,
          title: '剧',
          episodes: [Chapter(itemId: 'v1', title: '第一集', volumeName: '')],
          currentIndex: 0,
          duration: const Duration(minutes: 2),
          playing: true,
          shortSeries: true,
          danmaku: danmaku,
          danmakuEnabled: danmakuEnabled,
          onToggleDanmaku: onToggle,
          onSelectEpisode: (_) async {},
          onError: (error) => throw error,
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
  }

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
  }

  testWidgets('the more panel carries the danmaku switch', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(app(onToggle: () => toggles++));
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(
      find.byKey(const ValueKey('player-more-danmaku-row')),
      findsOneWidget,
    );
    expect(find.text('弹幕'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-more-danmaku-switch')));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('player-more-danmaku-switch')),
          )
          .value,
      isFalse,
    );
    expect(find.text('发弹幕'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('without a toggle callback the danmaku row is absent', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(find.byKey(const ValueKey('player-more-danmaku-row')), findsNothing);
    expect(
      find.byKey(const ValueKey('player-more-danmaku-send')),
      findsNothing,
    );
  });

  testWidgets('the danmaku layer renders only for short series', (
    tester,
  ) async {
    final entry = PlayletComment(
      id: 'd1',
      text: '前方高能',
      dataType: UgcRelativeType.seriesVideo,
      offsetMs: 15000,
    );
    await tester.pumpWidget(app(danmaku: [entry], onToggle: () {}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-danmaku-layer')), findsOneWidget);
    // 假播放器起播在 20s，弹幕时间点要落在飞行窗口内才会出现。
    expect(find.byKey(const ValueKey('danmaku-d1')), findsOneWidget);
  });
}
