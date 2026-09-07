import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  late _DeviceHost host;

  setUp(() {
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5});
    host = _DeviceHost();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          host.handle,
        );
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
      expect(host.calls, isEmpty);
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
    expect(host.calls, isEmpty);
  });

  testWidgets(
    'landscape left and right gestures adjust brightness and media volume while retaining video',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      final selected = <int>[];
      await _mount(tester, player, landscape: true, selected: selected);
      final video = tester.element(find.byKey(const ValueKey('video-frame')));
      player.calls.clear();
      await _slide(tester, const Offset(200, 200), const Offset(0, -50));
      expect(host.brightness, greaterThan(.5));
      expect(
        host.calls.any((call) => call.method == 'setMediaVolume'),
        isFalse,
      );
      expect(find.textContaining('亮度 '), findsOneWidget);
      final brightness = host.brightness;
      await _slide(tester, const Offset(600, 200), const Offset(0, 60));
      expect(host.volume, lessThan(.4));
      expect(host.brightness, brightness);
      expect(find.textContaining('音量 '), findsOneWidget);
      expect(
        tester.element(find.byKey(const ValueKey('video-frame'))),
        same(video),
      );
      expect(player.calls, isEmpty);
      expect(selected, isEmpty);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(
        find.byKey(const ValueKey('player-device-feedback')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'volume is refreshed from hardware and gestures clamp to the valid range',
    (tester) async {
      await _mount(
        tester,
        FakeNativePlayer()..isPlaying = true,
        landscape: true,
      );
      await _slide(tester, const Offset(600, 190), const Offset(0, -40));
      host.volume = .1; // A physical volume-key change between gestures.
      await _slide(tester, const Offset(600, 180), const Offset(0, 90));
      expect(host.volume, 0);
      await _slide(tester, const Offset(200, 180), const Offset(0, 500));
      expect(host.brightness, .05);
      await _slide(tester, const Offset(200, 180), const Offset(0, -700));
      expect(host.brightness, 1);
    },
  );

  testWidgets(
    'fullscreen exit restores brightness and leaves chosen media volume intact',
    (tester) async {
      await _mount(
        tester,
        FakeNativePlayer()..isPlaying = true,
        landscape: true,
      );
      await _slide(tester, const Offset(200, 200), const Offset(0, -50));
      await _slide(tester, const Offset(600, 200), const Offset(0, -30));
      final volume = host.volume;
      await tester.tap(find.byTooltip('退出全屏'));
      await tester.pump();
      await tester.pump();
      expect(host.brightness, .5);
      expect(host.volume, volume);
      expect(
        host.calls.where((call) => call.method == 'endDeviceControls'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'an initial read finishing after fullscreen exit cannot apply a stale gesture',
    (tester) async {
      final gate = host.beginGate = Completer<void>();
      await _mount(
        tester,
        FakeNativePlayer()..isPlaying = true,
        landscape: true,
      );
      final gesture = await tester.startGesture(const Offset(200, 200));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -50));
      await tester.pump();
      expect(
        host.calls.where((call) => call.method == 'beginDeviceControls'),
        hasLength(1),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      gate.complete();
      await tester.pump();
      await tester.pump();
      await gesture.cancel();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        host.calls.any((call) => call.method == 'setScreenBrightness'),
        isFalse,
      );
      expect(
        host.calls.where((call) => call.method == 'endDeviceControls'),
        hasLength(1),
      );
      expect(
        find.byKey(const ValueKey('player-device-feedback')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'backgrounding cancels adjustment and restores window brightness',
    (tester) async {
      await _mount(
        tester,
        FakeNativePlayer()..isPlaying = true,
        landscape: true,
      );
      final gesture = await tester.startGesture(const Offset(200, 200));
      await gesture.moveBy(const Offset(0, -25));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(host.brightness, greaterThan(.5));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump();
      expect(host.brightness, .5);
      await gesture.cancel();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-device-feedback')),
        findsNothing,
      );
      await _slide(tester, const Offset(200, 200), const Offset(0, -35));
      expect(
        host.calls.where((call) => call.method == 'beginDeviceControls'),
        hasLength(2),
      );
    },
  );

  testWidgets(
    'a pending brightness write finishes before exit restores the original value',
    (tester) async {
      final gate = host.writeGate = Completer<void>();
      await _mount(
        tester,
        FakeNativePlayer()..isPlaying = true,
        landscape: true,
      );
      final gesture = await tester.startGesture(const Offset(200, 200));
      await gesture.moveBy(const Offset(0, -25));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(
        host.calls.where((call) => call.method == 'setScreenBrightness'),
        hasLength(1),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      await gesture.cancel();
      gate.complete();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(host.brightness, .5);
      expect(host.calls.last.method, 'endDeviceControls');
      expect(
        find.byKey(const ValueKey('player-device-feedback')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'settings, panel and lock prevent brightness and volume gestures',
    (tester) async {
      await _mount(
        tester,
        FakeNativePlayer()..isPlaying = true,
        landscape: true,
      );
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 100), const Offset(0, 50));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 300), const Offset(0, -50));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('锁定播放'));
      await tester.pump();
      await _slide(tester, const Offset(200, 150), const Offset(0, -45));
      await _slide(tester, const Offset(600, 150), const Offset(0, -45));
      expect(host.calls, isEmpty);
    },
  );

  testWidgets(
    'unavailable device adjustment shows a local hint and playback continues',
    (tester) async {
      host.failWrites = true;
      final player = FakeNativePlayer()..isPlaying = true;
      await _mount(tester, player, landscape: true);
      player.calls.clear();
      await _slide(tester, const Offset(600, 200), const Offset(0, -40));
      expect(find.text('暂时无法调节音量'), findsOneWidget);
      expect(player.isPlaying, isTrue);
      expect(player.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fast moves coalesce while a device write is pending', (
    tester,
  ) async {
    final gate = host.writeGate = Completer<void>();
    await _mount(tester, FakeNativePlayer()..isPlaying = true, landscape: true);
    final gesture = await tester.startGesture(const Offset(600, 220));
    await gesture.moveBy(const Offset(0, -25));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, -8));
      await tester.pump();
    }
    expect(
      host.calls.where((call) => call.method == 'setMediaVolume'),
      hasLength(1),
    );
    await gesture.up();
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      host.calls.where((call) => call.method == 'setMediaVolume'),
      hasLength(2),
    );
    expect(host.volume, greaterThan(.55));
  });

  testWidgets(
    'new controls and feedback fit large text in a short landscape window',
    (tester) async {
      await _mount(
        tester,
        FakeNativePlayer()..isPlaying = true,
        landscape: true,
        textScale: 2.5,
      );
      await _slide(tester, const Offset(200, 180), const Offset(0, -30));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
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

class _DeviceHost {
  final calls = <MethodCall>[];
  double brightness = .5;
  double volume = .4;
  int? session;
  Completer<void>? beginGate;
  Completer<void>? writeGate;
  bool failWrites = false;

  Future<Object?> handle(MethodCall call) async {
    if (!const [
      'beginDeviceControls',
      'readDeviceControls',
      'setScreenBrightness',
      'setMediaVolume',
      'endDeviceControls',
    ].contains(call.method)) {
      return null;
    }
    calls.add(call);
    final args = call.arguments as Map;
    final requestedSession = args['session'] as int;
    if (call.method == 'beginDeviceControls') {
      await beginGate?.future;
      session = requestedSession;
    }
    if (call.method == 'endDeviceControls') {
      if (session == requestedSession) {
        brightness = .5;
        session = null;
      }
      return null;
    }
    if (session != requestedSession) {
      throw PlatformException(code: 'stale_session');
    }
    if (call.method == 'beginDeviceControls' ||
        call.method == 'readDeviceControls') {
      return {'brightness': brightness, 'volume': volume};
    }
    await writeGate?.future;
    if (failWrites) {
      throw PlatformException(code: 'device_controls_unavailable');
    }
    final value = (args['value'] as num).toDouble();
    if (call.method == 'setScreenBrightness') return brightness = value;
    return volume = value;
  }
}
