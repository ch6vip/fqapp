import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

const _playerSystemUi = MethodChannel('fqapp/player_system_ui');

/// Records the system bar requests the fullscreen player makes. The native
/// channel is the fix for #176; [modes] catches a regression back to the
/// legacy `SystemUiMode.immersiveSticky` call, which Android 15+ ignores.
class _SystemUiLog {
  final List<String> calls = [];
  final List<String> modes = [];

  String? get last => calls.isEmpty ? null : calls.last;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _playerSystemUi,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          modes.add('${call.arguments}');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _playerSystemUi,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.0}),
  );

  testWidgets('entering fullscreen hides bars through the native controller', (
    tester,
  ) async {
    final log = _SystemUiLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();

    expect(log.calls, contains('hide'));
    expect(
      log.modes,
      isNot(contains('SystemUiMode.immersiveSticky')),
      reason: 'target SDK 36 ignores the legacy immersive mode',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('leaving fullscreen gives the bars back', (tester) async {
    final log = _SystemUiLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    log.calls.clear();

    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    expect(log.last, 'show');
    expect(log.modes, contains('SystemUiMode.edgeToEdge'));

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('unmounting a fullscreen player restores the bars', (
    tester,
  ) async {
    final log = _SystemUiLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    log.calls.clear();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump();
    expect(log.calls, contains('show'));

    await player.dispose();
  });

  testWidgets('the feed landscape entry hides the bars on the first frame', (
    tester,
  ) async {
    final log = _SystemUiLog()..install(tester);
    final player = FakeNativePlayer(width: 1080, height: 1920);

    await tester.pumpWidget(_app(player, openFullScreen: true));
    await tester.pumpAndSettle();
    expect(log.calls, contains('hide'));

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('a route over fullscreen shows bars, returning hides them', (
    tester,
  ) async {
    final log = _SystemUiLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();

    final navigator = Navigator.of(
      tester.element(find.byType(VideoPlayerChrome)),
    );
    log.calls.clear();
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('详情')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsOneWidget);
    expect(log.calls, contains('show'));

    log.calls.clear();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(log.calls, contains('hide'));

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}

Widget _app(FakeNativePlayer player, {bool openFullScreen = false}) =>
    MaterialApp(
      home: VideoPlayerChrome(
        player: player,
        episodes: [
          Chapter(itemId: '1', title: '第一集', volumeName: ''),
          Chapter(itemId: '2', title: '第二集', volumeName: ''),
        ],
        currentIndex: 0,
        duration: player.duration,
        playing: true,
        openFullScreen: openFullScreen,
        onSelectEpisode: (index) async {},
        onError: (error) => throw error,
        child: const ColoredBox(color: Colors.black),
      ),
    );
