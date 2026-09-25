import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5}),
  );

  // 打开面板后不能用 pumpAndSettle：当前集的「播放中」声波 Lottie 是循环
  // 动画（官方 loop），会永不定帧。打开动画 200ms（§批次一），用固定 pump。
  Future<void> openEpisodes(WidgetTester tester) async {
    // 目录条在控制条可见时才挂载；settle 可能已越过 4s 自动隐藏线，先点
    // 画面把控制条唤回来。
    if (find.byKey(const ValueKey('player-catalog-bar')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('player-catalog-bar')));
    // 打开动画 200ms：pump 必须带时长——Ticker 首个 tick 把起点定在当下，
    // 无时长的 pump 不推进测试时钟，动画永远停在 elapsed 0（§26 踩坑）。
    // 面板开着时当前集的循环声波 Lottie 让 pumpAndSettle 永不结束，只能
    // 用固定时长 pump。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
  }

  testWidgets('71 episodes use six columns with 30-episode page tabs', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final videoBefore = tester.getRect(
      find.byKey(const ValueKey('video-frame')),
    );
    final callsBefore = List<String>.of(fixture.player.calls);
    await openEpisodes(tester);
    final panel = tester.getRect(find.byKey(const ValueKey('story-panel')));
    expect(panel.height, closeTo((904 - 39) * .55, 1));
    expect(find.byKey(const ValueKey('story-episode-grid')), findsOneWidget);
    // 官方面板没有搜索、没有「正在播放/找集」工具行（`catalogdialog/v2`）。
    expect(find.byType(TextField), findsNothing);
    expect(find.text('找集'), findsNothing);
    expect(find.textContaining('正在播放'), findsNothing);
    // 打开面板不暂停播放（官方 `k.smali` H0 无 pause）。
    expect(fixture.player.calls, callsBefore);

    // 六列方形格子（`gj3/o.java:749`、`hj3/r0.java:713-728`）。
    final first = tester.getRect(_episode(0));
    expect(tester.getRect(_episode(5)).top, closeTo(first.top, .1));
    expect(tester.getRect(_episode(6)).top, greaterThan(first.bottom));
    expect(first.width, closeTo((407 - 24 - 40) / 6, 1));
    expect(first.height, closeTo(first.width * 52 / 53, 1));

    // 长剧 30 集分页 tab（`gj3/o.java:812-846`）。
    expect(find.text('1-30'), findsOneWidget);
    expect(find.text('31-60'), findsOneWidget);
    expect(find.text('61-71'), findsOneWidget);

    // 点分页 tab 跳页：61-71 页起点可见。
    await tester.tap(find.text('61-71'));
    await tester.pump();
    await tester.pump();
    expect(_episode(60).hitTestable(), findsOneWidget);
    await tester.tap(_episode(70));
    await tester.pumpAndSettle();
    expect(fixture.selected, [70]);
    expect(find.byKey(const ValueKey('story-panel')), findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('video-frame'))),
      videoBefore,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening centers the current episode and pages to its group', (
    tester,
  ) async {
    await _mount(tester, currentIndex: 67);
    await openEpisodes(tester);
    expect(_episode(67).hitTestable(), findsOneWidget);
    // 当前集所在分页被选中（选中=加粗深色，`hj3/p.java:97-124`）。
    final activePage = tester.widget<Text>(find.text('61-71'));
    expect(activePage.style?.fontWeight, FontWeight.bold);
    final idlePage = tester.widget<Text>(find.text('1-30'));
    expect(idlePage.style?.fontWeight, FontWeight.normal);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening vertically centers the current tile in the viewport', (
    tester,
  ) async {
    // 真机踩坑：定位在面板 200ms 展开动画期间执行，用的是瞬时小视口，
    // 展开完成后当前集停在列表顶部而不是居中（§26.2）。选列表中段的
    // 39 集（不受 maxScrollExtent 截断），断言格子中心=视口中心+12dp。
    await _mount(tester, currentIndex: 39);
    await openEpisodes(tester);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('story-episodes')),
    );
    final current = tester.getRect(_episode(39));
    expect(current.center.dy, closeTo(viewport.center.dy + 12, 1.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'current tile is orange with the corner playing lottie; watched tiles are gray',
    (tester) async {
      await _mount(
        tester,
        currentIndex: 3,
        watched: {0, 1, 2},
      );
      await openEpisodes(tester);
      Text tileText(int index) => tester.widget<Text>(
        find.descendant(of: _episode(index), matching: find.byType(Text)).first,
      );
      // 当前集：文字 #FFFA6725 粗体、底 #1AFA6725（`r0.java:449-457`）。
      final current = tileText(3);
      expect(current.style?.color, const Color(0xFFFA6725));
      expect(current.style?.fontWeight, FontWeight.bold);
      // 当前集底色 #1AFA6725 只出现在这一块格子上。
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Material && widget.color == const Color(0x1AFA6725),
        ),
        findsOneWidget,
      );
      // 播放中 Lottie 在右上角（`bbw.xml:5-6`）。
      expect(
        find.descendant(of: _episode(3), matching: find.byType(Lottie)),
        findsOneWidget,
      );
      // 已看集灰字 #66000000（`r0.java:224-235`）。
      expect(tileText(1).style?.color, const Color(0x66000000));
      // 未看普通集：官方 skin_color_catalog_unselect_item_text_normal_dark
      // = @color/skin_color_black_dark = #CCFFFFFF（此前这里写的是纯黑
      // #FF000000，属于本地取值，本轮按 APK colors.xml 更正）。
      expect(tileText(10).style?.color, const Color(0xCCFFFFFF));
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(1080, 1920),
    const Size(1920, 1080),
    const Size(1080, 1080),
  ]) {
    testWidgets(
      'panel preserves aspect and playback for ${size.width} x ${size.height}',
      (tester) async {
        final fixture = await _mount(tester, videoSize: size);
        final before = tester.getRect(
          find.byKey(const ValueKey('video-frame')),
        );
        final callsBefore = List<String>.of(fixture.player.calls);
        final positionBefore = fixture.player.position;
        await openEpisodes(tester);
        final panel = tester.getRect(find.byKey(const ValueKey('story-panel')));
        final video = tester.getRect(find.byKey(const ValueKey('video-frame')));
        expect(
          panel.height,
          closeTo((904 - 39) * (size.height > size.width ? .55 : .64), 1),
        );
        expect(
          video.width / video.height,
          closeTo(size.width / size.height, .001),
        );
        expect(video.bottom, lessThanOrEqualTo(panel.top + .1));
        expect(video.top, greaterThanOrEqualTo(39));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('story-panel')), findsNothing);
        expect(
          tester.getRect(find.byKey(const ValueKey('video-frame'))),
          before,
        );
        expect(fixture.player.calls, callsBefore);
        expect(fixture.player.position, positionBefore);
        expect(fixture.player.isPlaying, true);
        expect(fixture.player.rate, 1.5);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('tapping the dim scrim closes the panel without pausing', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final callsBefore = List<String>.of(fixture.player.calls);
    final videoBefore = tester.getRect(
      find.byKey(const ValueKey('video-frame')),
    );
    await openEpisodes(tester);
    // 官方遮罩 dim 0.5（`AnimationBottomDialog.java:129-140`）。
    final scrim = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('story-panel-scrim')),
    );
    expect(scrim.color, isNot(const Color(0x00000000)));
    expect(scrim.color.a, closeTo(.5, .05));
    final panel = find.byKey(const ValueKey('story-panel'));
    final panelTop = tester.getTopLeft(panel).dy;
    await tester.tapAt(Offset(200, (panelTop - 60).clamp(45.0, 800.0)));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('video-frame'))),
      videoBefore,
    );
    expect(fixture.player.calls, callsBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a downward header drag closes the panel', (tester) async {
    final fixture = await _mount(tester);
    await openEpisodes(tester);
    final handle = tester.getRect(
      find.byKey(const ValueKey('story-panel-drag')),
    );
    await tester.dragFrom(
      Offset(handle.center.dx, handle.top + 6),
      const Offset(0, 370),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('story-panel')), findsNothing);
    expect(fixture.selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('half panel scrolls episodes without moving the sheet', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await openEpisodes(tester);
    final body = find.byKey(const ValueKey('story-episodes'));
    final panel = find.byKey(const ValueKey('story-panel'));
    final before = tester.getRect(panel);
    final videoBefore = tester.getRect(
      find.byKey(const ValueKey('video-frame')),
    );
    final playerCalls = List<String>.of(fixture.player.calls);
    final scroll = _scrollPosition(tester, body);
    final heights = <double>[];
    final gesture = await tester.startGesture(tester.getCenter(body));
    for (var frame = 0; frame < 6; frame++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 32));
      heights.add(tester.getSize(panel).height);
    }
    // 停顿一拍再抬手，杀掉惯性（ballistic 的落点不确定）。
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();

    expect(heights, everyElement(closeTo(before.height, 1)));
    final scrolled = scroll.pixels;
    expect(scrolled, closeTo(180, 1));
    // 滚动联动分页条：可视区滚进第 31-60 集后选中页变化（用户滚动才联动）。
    scroll.jumpTo(360);
    await tester.pump();
    final linkedPage = tester.widget<Text>(find.text('31-60'));
    expect(linkedPage.style?.fontWeight, FontWeight.bold);
    // 向回拖一截，sheet 不动、播放不受影响。
    final gesture2 = await tester.startGesture(tester.getCenter(body));
    await gesture2.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture2.up();
    await tester.pump();
    // 拖动让列表像素从 jumpTo(360) 回落（下拖 40px 后应在 320 附近）。
    expect(_scrollPosition(tester, body).pixels, lessThan(360));
    expect(tester.getRect(panel), before);
    expect(
      tester.getRect(find.byKey(const ValueKey('video-frame'))),
      videoBefore,
    );
    expect(fixture.selected, isEmpty);
    expect(fixture.player.calls, playerCalls);
    expect(tester.takeException(), isNull);
  });

  testWidgets('content drag does not snap back before the finger is released', (
    tester,
  ) async {
    await _mount(tester);
    await openEpisodes(tester);
    final panel = find.byKey(const ValueKey('story-panel'));
    final body = find.byKey(const ValueKey('story-episodes'));
    final before = tester.getSize(panel).height;
    final gesture = await tester.startGesture(tester.getCenter(body));
    await gesture.moveBy(const Offset(0, 70));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 16));
    final during = tester.getSize(panel).height;
    await tester.pump(const Duration(milliseconds: 350));
    final held = tester.getSize(panel).height;
    await gesture.moveBy(const Offset(0, 35));
    await tester.pump(const Duration(milliseconds: 16));
    final moved = tester.getSize(panel).height;
    await gesture.up();
    // 手抬后面板仍开着，当前集的循环声波 Lottie 让 pumpAndSettle 永不结束，
    // 只能用固定时长 pump（§2.1 时钟坑）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(during, lessThan(before - 20));
    expect(held, closeTo(during, 1));
    expect(moved, lessThan(held - 20));
    expect(tester.takeException(), isNull);
  });
}

ScrollPosition _scrollPosition(WidgetTester tester, Finder body) => tester
    .state<ScrollableState>(
      find.descendant(of: body, matching: find.byType(Scrollable)).first,
    )
    .position;

Finder _episode(int index) => find.byKey(ValueKey('story-episode-$index'));

class _Fixture {
  final FakeNativePlayer player;
  final List<int> selected;
  _Fixture(this.player, this.selected);
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  Size window = const Size(407, 904),
  Size videoSize = const Size(1080, 1920),
  TextScaler scale = TextScaler.noScaling,
  int currentIndex = 0,
  Set<int>? watched,
  List<Chapter>? episodes,
}) async {
  await tester.binding.setSurfaceSize(window);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final player = FakeNativePlayer(
    width: videoSize.width.toInt(),
    height: videoSize.height.toInt(),
  )..isPlaying = true;
  final selected = <int>[];
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: scale,
          padding: const EdgeInsets.only(top: 39, bottom: 16),
        ),
        child: child!,
      ),
      home: VideoPlayerChrome(
        player: player,
        title: '测试短剧',
        episodes:
            episodes ??
            List.generate(
              71,
              (index) => Chapter(
                itemId: '${index + 1}',
                title: '第${index + 1}集',
                volumeName: '',
              ),
            ),
        currentIndex: currentIndex,
        playingIndex: currentIndex,
        playing: true,
        duration: player.duration,
        watchedEpisodes:
            watched ?? {for (var i = 0; i < currentIndex; i++) i},
        onSelectEpisode: (index) async => selected.add(index),
        onError: (error) => throw error,
        child: const ColoredBox(color: Colors.black),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(player, selected);
}
