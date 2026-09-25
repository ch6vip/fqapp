import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// 更多面板里的弹幕开关与「发弹幕」入口的用例。
///
/// 官方依据：更多面板第 5 行是弹幕开关（`oi3/k.java:554-568`，
/// SP `video_danmaku_switch_sp/key_enable_danmaku_by_user`，默认 true），
/// 横屏全屏底栏有「发弹幕」入口（`lk3/u0.java:1096-1119`），
/// 输入占位「发条友善的弹幕吧」、上限提示「弹幕最多输入%d个字」。
void main() {
  Widget app({
    bool danmakuEnabled = true,
    VoidCallback? onToggle,
    Future<void> Function(String)? onSend,
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
          onSendDanmaku: onSend,
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
    expect(find.byKey(const ValueKey('player-more-danmaku-row')), findsOneWidget);
    expect(find.text('弹幕'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-more-danmaku-switch')));
    await tester.pumpAndSettle();
    expect(toggles, 1);
  });

  testWidgets('without a toggle callback the danmaku row is absent', (
    tester,
  ) async {
    await tester.pumpWidget(app(onSend: (_) async {}));
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(find.byKey(const ValueKey('player-more-danmaku-row')), findsNothing);
    expect(find.byKey(const ValueKey('player-more-danmaku-send')), findsOneWidget);
  });

  testWidgets('发弹幕 publishes the trimmed text with the current offset', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      app(onToggle: () {}, onSend: (text) async => sent.add(text)),
    );
    await tester.pumpAndSettle();
    await openMore(tester);
    await tester.tap(find.byKey(const ValueKey('player-more-danmaku-send')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('danmaku-input')),
      '  前方高能  ',
    );
    await tester.tap(find.byKey(const ValueKey('danmaku-send')));
    await tester.pumpAndSettle();
    expect(sent, ['前方高能']);
  });

  testWidgets('an over-long danmaku is refused with the official hint', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      app(onToggle: () {}, onSend: (text) async => sent.add(text)),
    );
    await tester.pumpAndSettle();
    await openMore(tester);
    await tester.tap(find.byKey(const ValueKey('player-more-danmaku-send')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('danmaku-input')),
      '弹' * 51,
    );
    await tester.tap(find.byKey(const ValueKey('danmaku-send')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(find.text('弹幕最多输入50个字'), findsOneWidget);
  });

  testWidgets('the danmaku layer renders only for short series', (tester) async {
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
