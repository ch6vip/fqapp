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

  testWidgets('clear screen survives pause, resume and the auto-hide timeout', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    final selected = <int>[];
    await _mount(tester, player, selected: selected, shortSeries: true);
    expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    _expectClearScreen();
    // 手势仍操作播放器，清屏状态独立于暂停反馈和自动收起计时器。
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 350));
    expect(player.isPlaying, isFalse);
    _expectClearScreen();
    await tester.tapAt(const Offset(200, 400));
    await tester.pump();
    expect(player.isPlaying, isTrue);
    await tester.pump(const Duration(seconds: 4));
    _expectClearScreen();
    expect(selected, isEmpty);
    await tester.tap(find.text('恢复'));
    await tester.pump();
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
    expect(find.text('恢复'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear screen keeps long press and speed selection working', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await _mount(tester, player, shortSeries: true);
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 600));
    expect(player.rate, 2);
    await gesture.up();
    await tester.pump();
    expect(player.rate, 1.5);
    await tester.pump(const Duration(seconds: 4));
    _expectClearScreen();

    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-rate-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-clear-screen')), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '1.25x'));
    await tester.pumpAndSettle();
    expect(player.rate, 1.25);
    expect(find.text('1.25x'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    _expectClearScreen();
  });

  testWidgets('clear screen survives paging, loading and player replacement', (
    tester,
  ) async {
    final first = FakeNativePlayer()..isPlaying = true;
    final second = FakeNativePlayer()..isPlaying = true;
    final selected = <int>[];
    await _mount(tester, first, shortSeries: true, selected: selected);
    addTearDown(second.dispose);
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    await tester.dragFrom(const Offset(160, 400), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(selected, contains(1));
    await tester.pump(const Duration(seconds: 4));
    _expectClearScreen();

    await tester.pumpWidget(
      _app(first, index: 1, enabled: false, shortSeries: true),
    );
    await tester.pump();
    _expectClearScreen();
    await tester.pumpWidget(_app(second, index: 1, shortSeries: true));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    _expectClearScreen();
    await tester.tap(find.text('恢复'));
    await tester.pump();
    expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
  });

  testWidgets('clear screen can pause and restore after window rotation', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await _mount(tester, player, shortSeries: true);
    // 先进入全屏，再模拟系统送来的窗口尺寸变化，保留同一个 chrome 状态。
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(800, 450));
    await tester.pump();
    _expectClearScreen();
    await tester.tapAt(const Offset(400, 200));
    await tester.pump(const Duration(milliseconds: 350));
    expect(player.isPlaying, isFalse);
    _expectClearScreen();
    await tester.tapAt(const Offset(400, 200));
    await tester.pump(const Duration(milliseconds: 350));
    expect(player.isPlaying, isTrue);

    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pump();
    _expectClearScreen();
    await tester.binding.setSurfaceSize(const Size(800, 450));
    await tester.pump();
    await tester.tap(find.text('恢复'));
    await tester.pump();
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('landscape-seek')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-clear-screen')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'text actions stay reachable on a narrow screen with large text',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await _mount(tester, player, textScale: 2.5, shortSeries: true);
      await tester.binding.setSurfaceSize(const Size(280, 600));
      await tester.pump(const Duration(seconds: 4));
      final clearAction = find.byKey(const ValueKey('player-clear-screen'));
      final rateAction = find.byKey(const ValueKey('player-rate-text'));
      expect(clearAction.hitTestable(), findsOneWidget);
      expect(rateAction.hitTestable(), findsOneWidget);
      for (final action in [clearAction, rateAction]) {
        final rect = tester.getRect(action);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(280));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      await tester.tap(clearAction);
      await tester.pump();
      _expectClearScreen();
      await tester.tap(find.text('恢复'));
      await tester.pump();
      expect(find.text('清屏'), findsOneWidget);
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

void _expectClearScreen() {
  expect(find.byTooltip('返回'), findsNothing);
  expect(find.byKey(const ValueKey('video-controls')), findsNothing);
  expect(find.byKey(const ValueKey('player-catalog-bar')), findsNothing);
  expect(find.byKey(const ValueKey('player-follow-button')), findsNothing);
  expect(find.byKey(const ValueKey('player-fullscreen-pill')), findsNothing);
  expect(find.byKey(const ValueKey('video-seek')), findsNothing);
  expect(find.byKey(const ValueKey('landscape-seek')), findsNothing);
  expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  expect(
    find.byKey(const ValueKey('player-rate-text')).hitTestable(),
    findsOneWidget,
  );
  expect(find.text('恢复').hitTestable(), findsOneWidget);
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
  bool enabled = true,
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
      enabled: enabled,
      onSelectEpisode: (value) async {
        selected?.add(value);
      },
      onError: (error) => throw error,
      child: const ColoredBox(color: Colors.black),
    ),
  ),
);
