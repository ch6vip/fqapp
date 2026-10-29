import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/services/player_layout_preferences.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// 选集面板层（`Stack` 里的 `Positioned` + `DraggableScrollableSheet`）不能在
/// 换集或进分屏时被重建：旧 sheet 要到帧末 `dispose` 才 `_detach`，同一帧里
/// 新 sheet 的 `_attach` 会命中
/// `'_attachedController == null': Draggable scrollable controller is already
/// attached to a sheet.`（真机竖屏换集复现）。
void main() {
  testWidgets('the open sheet is reused when sibling layers come and go', (
    tester,
  ) async {
    final player = await _mount(tester, layers: true);
    await _openPanel(tester);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    final sheet = tester.state(find.byType(DraggableScrollableSheet));

    // 换到没有弹幕也没有热评的一集：两层从 Stack 里消失，后面的层整体前移。
    await tester.pumpWidget(_app(player, layers: false));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('story-panel')), findsOneWidget);
    // 不止「还在」：必须是同一个 State（重建会重采 extent、重新 attach）。
    expect(tester.state(find.byType(DraggableScrollableSheet)), same(sheet));

    // 再回到有弹幕的一集：反过来后移一次，同样不许重建。
    await tester.pumpWidget(_app(player, layers: true));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.state(find.byType(DraggableScrollableSheet)), same(sheet));
  });

  testWidgets('an open sheet leaves the tree before the stage goes split', (
    tester,
  ) async {
    final player = await _mount(tester, layers: true);
    await _openPanel(tester);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);

    // 进分屏：stage 被塞进 compact 视频盒，换了父级。面板层若还跟着进去，
    // 新 sheet 就与帧末才 `_detach` 的旧 sheet 同帧共存。
    await tester.pumpWidget(
      _app(player, layers: true, mode: PlayerLayoutMode.split),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    // 首帧回调把面板状态摘干净（PopScope 靠它放行返回键），不许再冒出来。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
  });
}

Future<FakeNativePlayer> _mount(
  WidgetTester tester, {
  required bool layers,
}) async {
  await tester.binding.setSurfaceSize(const Size(407, 904));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final player = FakeNativePlayer(width: 1080, height: 1920)..isPlaying = true;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
  // 面板开着时当前集的声波 Lottie 循环，pumpAndSettle 永不定帧。
  await tester.pumpWidget(_app(player, layers: layers));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return player;
}

Future<void> _openPanel(WidgetTester tester) async {
  // 目录条只在控制条可见时挂载；自动隐藏后先点画面唤回来。
  final bar = find.byKey(const ValueKey('player-catalog-bar'));
  if (bar.evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('video-surface')));
    await tester.pump();
  }
  await tester.tap(bar);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump();
}

Widget _app(
  FakeNativePlayer player, {
  required bool layers,
  PlayerLayoutMode mode = PlayerLayoutMode.immersive,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(padding: const EdgeInsets.only(top: 39, bottom: 16)),
    child: child!,
  ),
  home: VideoPlayerChrome(
    player: player,
    episodes: [
      for (var index = 1; index <= 3; index++)
        Chapter(itemId: '$index', title: '第$index集', volumeName: ''),
    ],
    currentIndex: 0,
    playingIndex: 0,
    playing: true,
    duration: player.duration,
    shortSeries: true,
    layoutMode: mode,
    // 分屏档要靠 splitPanel 才成立；沉浸档不看它。
    splitPanel: const ColoredBox(
      key: ValueKey('fake-split-panel'),
      color: Colors.blueGrey,
    ),
    danmaku: layers
        ? const [PlayletComment(id: 'd1', text: '前方高能', offsetMs: 1200)]
        : const [],
    hotComments: layers
        ? const [PlayletComment(id: 'h1', text: '热评', diggCount: 9)]
        : const [],
    onSelectEpisode: (index) async {},
    onError: (error) => throw error,
    child: const ColoredBox(color: Colors.black),
  ),
);
