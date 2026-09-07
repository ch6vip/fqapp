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
    'lock blocks episode, seek, double tap and speed gestures without stopping video',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      final selected = <int>[];
      await _mount(tester, player, selected: selected);
      final video = tester.element(find.byKey(const ValueKey('video-frame')));
      await tester.tap(find.byTooltip('锁定播放'));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-unlock')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-seek')), findsNothing);
      expect(find.byTooltip('播放设置'), findsNothing);
      player.calls.clear();
      await tester.dragFrom(const Offset(200, 420), const Offset(0, -280));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(100, 650), const Offset(180, 0));
      await tester.tapAt(const Offset(200, 350));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(200, 350));
      final hold = await tester.startGesture(const Offset(200, 350));
      await tester.pump(const Duration(milliseconds: 700));
      await hold.up();
      await tester.pump();
      expect(selected, isEmpty);
      expect(player.calls, isEmpty);
      expect(player.isPlaying, isTrue);
      expect(nativeCalls, isEmpty);
      expect(
        tester.element(find.byKey(const ValueKey('video-frame'))),
        same(video),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
      await tester.dragFrom(const Offset(200, 420), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(selected, contains(1));
    },
  );

  testWidgets(
    'locked fullscreen hides unlock then a tap reveals it; back unlocks before leaving fullscreen',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await _mount(tester, player, landscape: true);
      await tester.tap(find.byTooltip('锁定播放'));
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('player-unlock')), findsNothing);
      await tester.tapAt(const Offset(400, 180));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-unlock')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byTooltip('全屏'), findsOneWidget);
      expect(player.isPlaying, isTrue);
    },
  );

  testWidgets('lock survives an automatic episode and player replacement', (
    tester,
  ) async {
    final first = FakeNativePlayer()..isPlaying = true;
    final second = FakeNativePlayer()..isPlaying = true;
    await _mount(tester, first);
    addTearDown(second.dispose);
    await tester.tap(find.byTooltip('锁定播放'));
    await tester.pump();
    await tester.pumpWidget(_app(second, index: 1));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('player-lock-shield')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-seek')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-unlock')));
    await tester.pump();
    expect(find.text('第 2 集 · 共 3 集'), findsOneWidget);
    expect(second.rate, 1.5);
  });

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
    await tester.tap(find.byTooltip('播放设置'));
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
    _app(player, selected: selected, textScale: textScale),
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
      description: '剧情介绍',
      onSelectEpisode: (value) async {
        selected?.add(value);
      },
      onError: (error) => throw error,
      child: const ColoredBox(color: Colors.black),
    ),
  ),
);
