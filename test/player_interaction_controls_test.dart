import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  late List<MethodCall> nativeCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5});
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fqapp/native_player'), (
          call,
        ) async {
          nativeCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  testWidgets(
    'clear screen hides every overlay and only the 恢复 text brings them back',
    (tester) async {
      // 官方清屏（`SingleVideoHolder.java:1140-1210` → `o.java:1860-1884`）：
      // 浮层全隐、遮罩不可用，出口是右下角文字行的「恢复」。
      final player = FakeNativePlayer()..isPlaying = true;
      final selected = <int>[];
      await _mount(tester, player, selected: selected, shortSeries: true);
      expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
      await tester.pump();
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.byKey(const ValueKey('video-controls')), findsNothing);
      expect(find.byKey(const ValueKey('player-catalog-bar')), findsNothing);
      expect(find.byKey(const ValueKey('player-follow-button')), findsNothing);
      expect(find.byKey(const ValueKey('video-seek')), findsNothing);
      expect(find.text('恢复'), findsOneWidget);
      // 清屏态下点画面不再唤回浮层（官方 `setVisibility(4)`）；短剧竖屏的
      // 单击=暂停（第十八轮的有意偏差）仍然生效，但不唤回浮层。
      await tester.tapAt(const Offset(200, 400));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.text('恢复'), findsOneWidget);
      expect(selected, isEmpty);
      await tester.tap(find.text('恢复'));
      await tester.pump();
      expect(find.byTooltip('返回'), findsOneWidget);
      expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
      expect(find.text('恢复'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('portrait swipes keep paging and never adjust the device', (
    tester,
  ) async {
    final selected = <int>[];
    await _mount(
      tester,
      FakeNativePlayer()..isPlaying = true,
      selected: selected,
    );
    await tester.dragFrom(const Offset(160, 400), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(selected, contains(1));
    expect(nativeCalls, isEmpty);
  });

  testWidgets(
    'landscape vertical swipes leave device settings, episode and playback untouched',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      final selected = <int>[];
      await _mount(tester, player, landscape: true, selected: selected);
      final video = tester.element(find.byKey(const ValueKey('video-frame')));
      player.calls.clear();
      await _slide(tester, const Offset(200, 200), const Offset(0, -50));
      await _slide(tester, const Offset(600, 200), const Offset(0, 60));
      expect(nativeCalls, isEmpty);
      expect(find.textContaining('亮度'), findsNothing);
      expect(find.textContaining('音量'), findsNothing);
      expect(
        tester.element(find.byKey(const ValueKey('video-frame'))),
        same(video),
      );
      expect(player.calls, isEmpty);
      expect(player.isPlaying, isTrue);
      expect(selected, isEmpty);
    },
  );

  testWidgets('playback controls fit large text in a short landscape window', (
    tester,
  ) async {
    await _mount(
      tester,
      FakeNativePlayer()..isPlaying = true,
      landscape: true,
      textScale: 2.5,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _slide(WidgetTester tester, Offset start, Offset delta) async {
  final gesture = await tester.startGesture(start);
  await gesture.moveBy(Offset(0, delta.dy.sign * 25));
  await tester.pump();
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _mount(
  WidgetTester tester,
  FakeNativePlayer player, {
  bool landscape = false,
  List<int>? selected,
  double textScale = 1,
  bool shortSeries = false,
}) async {
  await tester.binding.setSurfaceSize(
    landscape ? const Size(800, 450) : const Size(400, 800),
  );
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Double-tap recognizers leave a short minimum-tap timer after a drag.
    await tester.pump(const Duration(milliseconds: 350));
    await player.dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    _app(
      player,
      selected: selected,
      textScale: textScale,
      shortSeries: shortSeries,
    ),
  );
  await tester.pumpAndSettle();
  if (landscape) {
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
  }
}

Widget _app(
  FakeNativePlayer player, {
  List<int>? selected,
  int index = 0,
  double textScale = 1,
  bool shortSeries = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: StreamBuilder<bool>(
    stream: player.playingStream,
    initialData: player.playing,
    builder: (context, playing) => VideoPlayerChrome(
      player: player,
      title: '交互测试短剧',
      episodes: List.generate(
        3,
        (i) => Chapter(itemId: '$i', title: '第 ${i + 1} 集', volumeName: ''),
      ),
      currentIndex: index,
      duration: player.duration,
      playing: playing.data!,
      shortSeries: shortSeries,
      onSelectEpisode: (value) async {
        selected?.add(value);
      },
      onError: (error) => throw error,
      child: const ColoredBox(color: Colors.black),
    ),
  ),
);
