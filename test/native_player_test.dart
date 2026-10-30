import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _methods = MethodChannel('fqapp/native_player');
const _eventMethods = MethodChannel('fqapp/native_player/events');
const _codec = StandardMethodCodec();

void main() {
  late List<MethodCall> calls;
  Completer<Map<String, dynamic>>? createGate;
  Completer<void>? disposeGate;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    createGate = null;
    disposeGate = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_eventMethods, (_) async => null);
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      if (call.method == 'create') {
        return createGate?.future ?? Future.value({'playerId': 71});
      }
      if (call.method == 'dispose') await disposeGate?.future;
      return null;
    });
  });

  Future<void> cleanUp(WidgetTester tester, NativePlayer player) async {
    if (find.byType(VideoPlayerChrome).evaluate().isNotEmpty) {
      await tester.pumpWidget(const SizedBox.shrink());
    }
    if (createGate != null && !createGate!.isCompleted) {
      createGate!.complete({'playerId': 71});
    }
    if (disposeGate != null && !disposeGate!.isCompleted) {
      disposeGate!.complete();
    }
    await player.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(_eventMethods.name, null, (_) {});
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_eventMethods, null);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  void nativeTest(
    String name,
    Future<void> Function(WidgetTester, NativePlayer) body,
  ) {
    testWidgets(name, (tester) async {
      final player = NativePlayer();
      try {
        await body(tester, player);
      } finally {
        // Drain expiry timers inside the test's fake clock, before Flutter's
        // pending-timer check (ordinary addTearDown runs after that check).
        await cleanUp(tester, player);
      }
    });
  }

  nativeTest(
    'disposing before the create reply safely releases its late native id once',
    (tester, player) async {
      createGate = Completer<Map<String, dynamic>>();
      final creation = player
          .create('https://example.invalid/late.mp4', '')
          .then<Object>((value) => value, onError: (Object error) => error);
      await tester.pump();
      await player.dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
      createGate!.complete({'playerId': 71});
      await tester.pump();
      expect(await creation, isStateError);
      expect(player.isCreated, false);
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      await player.play();
      expect(calls.where((call) => call.method == 'play'), isEmpty);
    },
  );

  nativeTest('all dispose callers wait for the same native release', (
    tester,
    player,
  ) async {
    final creation = player.create('https://example.invalid/ready.mp4', '');
    await tester.pump();
    await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
    await tester.pump();
    expect(await creation, 9);
    disposeGate = Completer<void>();
    final first = player.dispose();
    var secondFinished = false;
    final second = player.dispose().then((_) => secondFinished = true);
    await tester.pump();
    expect(secondFinished, false);
    disposeGate!.complete();
    await tester.pump();
    await Future.wait([first, second]);
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
  });

  nativeTest(
    'a create reply arriving after timeout still releases the native player',
    (tester, player) async {
      createGate = Completer<Map<String, dynamic>>();
      final creation = player
          .create('https://example.invalid/timeout.mp4', '')
          .then<Object>((value) => value, onError: (Object error) => error);
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      expect(await creation, isA<TimeoutException>());
      createGate!.complete({'playerId': 71});
      await tester.pump();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      expect(player.isCreated, false);
    },
  );

  nativeTest(
    'disposal while waiting for texture ends creation and ignores late events',
    (tester, player) async {
      final creation = player
          .create('https://example.invalid/texture.mp4', '')
          .then<Object>((value) => value, onError: (Object error) => error);
      await tester.pump();
      expect(player.isCreated, false);
      await player.dispose();
      await tester.pump();
      expect(await creation, isStateError);
      await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
      await _sendEvent({'playerId': 71, 'type': 'playing', 'value': true});
      await tester.pump();
      expect(player.isCreated, false);
      expect(player.playing, false);
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    },
  );

  for (final fails in [false, true]) {
    nativeTest(
      'events arriving before the method reply preserve ${fails ? 'errors' : 'texture and duration'}',
      (tester, player) async {
        createGate = Completer<Map<String, dynamic>>();
        final creation = player
            .create('https://example.invalid/early.mp4', '')
            .then<Object>((value) => value, onError: (Object error) => error);
        await tester.pump();
        await _sendEvent({
          'playerId': 71,
          'type': fails ? 'error' : 'created',
          'value': fails ? 'source failed' : 9,
        });
        await _sendEvent({'playerId': 71, 'type': 'duration', 'value': 120000});
        createGate!.complete({'playerId': 71});
        await tester.pump();
        if (fails) {
          expect(await creation, isA<NativePlaybackException>());
          expect(player.lastError.toString(), contains('source failed'));
          expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
        } else {
          expect(await creation, 9);
          expect(player.duration, const Duration(minutes: 2));
          expect(player.isCreated, true);
        }
      },
    );
  }

  nativeTest(
    'accepted seek exposes the resume position before the next native event',
    (tester, player) async {
      final creation = player.create('https://example.invalid/resume.mp4', '');
      await tester.pump();
      await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
      await tester.pump();
      await creation;
      // ExoPlayer reports created before STATE_READY supplies the duration.
      expect(player.duration, Duration.zero);
      await player.seek(const Duration(milliseconds: 37500));
      expect(player.position, const Duration(milliseconds: 37500));
      await _sendEvent({'playerId': 71, 'type': 'position', 'value': 38000});
      await tester.pump();
      expect(player.position, const Duration(seconds: 38));
    },
  );

  nativeTest('video size events carry rotation without swapping display size', (
    tester,
    player,
  ) async {
    final creation = player.create('https://example.invalid/rotation.mp4', '');
    await tester.pump();
    await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
    await tester.pump();
    await creation;
    for (final rotation in [90, 180, 270, 0, 45, null]) {
      await _sendEvent({
        'playerId': 71,
        'type': 'videoSize',
        'width': 1080,
        'height': 1920,
        'rotationCorrection': ?rotation,
      });
      await tester.pump();
      expect(player.videoWidth, 1080);
      expect(player.videoHeight, 1920);
      expect(
        player.videoRotationCorrection,
        [90, 180, 270].contains(rotation) ? rotation : 0,
      );
    }
  });

  nativeTest('play intent follows commands and native pauses while buffering', (
    tester,
    player,
  ) async {
    await _createPlayer(tester, player);
    await player.play();
    await _sendEvent({'playerId': 71, 'type': 'buffering', 'value': true});
    await _sendEvent({'playerId': 71, 'type': 'playing', 'value': false});
    await tester.pump();
    expect(player.playing, false);
    expect(player.playWhenReady, true);
    await _sendEvent({'playerId': 71, 'type': 'playWhenReady', 'value': false});
    await tester.pump();
    expect(player.playWhenReady, false);
    await player.play();
    await player.pause();
    await tester.pump();
    expect(player.playWhenReady, false);
  });

  for (final paused in [false, true]) {
    nativeTest(
      'buffering survives backgrounding only when playback is requested (paused: $paused)',
      (tester, player) async {
        await _createPlayer(tester, player);
        await player.play();
        await _sendEvent({'playerId': 71, 'type': 'buffering', 'value': true});
        await _sendEvent({'playerId': 71, 'type': 'playing', 'value': false});
        await tester.pumpWidget(_playerApp(player));
        await tester.pumpAndSettle();
        expect(find.byTooltip('暂停'), findsOneWidget);
        if (paused) {
          // A buffering video must still offer pause and honor it on return.
          await tester.tap(find.byTooltip('暂停'));
          await tester.pump();
          expect(player.playWhenReady, false);
          expect(find.byTooltip('播放'), findsOneWidget);
        }
        calls.clear();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(player.playWhenReady, false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(player.playWhenReady, !paused);
        expect(
          calls.where((call) => call.method == 'play'),
          hasLength(paused ? 0 : 1),
        );
      },
    );
  }

  nativeTest('seeking during buffering resumes the requested playback', (
    tester,
    player,
  ) async {
    await _createPlayer(tester, player);
    await player.play();
    await _sendEvent({'playerId': 71, 'type': 'buffering', 'value': true});
    await tester.pumpWidget(_playerApp(player));
    await tester.pumpAndSettle();
    calls.clear();
    final track = tester.getRect(find.byKey(const ValueKey('video-seek')));
    await tester.dragFrom(
      track.centerLeft + const Offset(20, 0),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'seek'), hasLength(1));
    expect(calls.where((call) => call.method == 'play'), hasLength(1));
    expect(player.playWhenReady, true);
  });

  nativeTest('completed playback is not resumed on foreground', (
    tester,
    player,
  ) async {
    await _createPlayer(tester, player);
    await player.play();
    await _sendEvent({'playerId': 71, 'type': 'completed', 'value': true});
    await tester.pumpWidget(_playerApp(player));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放'), findsOneWidget);
    calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls.where((call) => call.method == 'play'), isEmpty);
  });

  for (final beforeCreated in [true, false]) {
    nativeTest(
      'structured native errors retain HTTP details beforeCreated=$beforeCreated',
      (tester, player) async {
        final receivedError = player.errorStream.first;
        final creation = player
            .create('https://example.invalid/video', '')
            .then<Object>((value) => value, onError: (Object error) => error);
        await tester.pump();
        if (!beforeCreated) {
          await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
          await tester.pump();
          expect(await creation, 9);
        }
        await _sendEvent({
          'playerId': 71,
          'type': 'error',
          'value': {
            'message': 'Source error',
            'errorCode': 2004,
            'httpStatusCode': 403,
          },
        });
        await tester.pump();
        final error = player.lastError! as NativePlaybackException;
        expect(error.errorCode, 2004);
        expect(error.httpStatusCode, 403);
        expect(await receivedError, same(error));
        if (beforeCreated) {
          expect(await creation, same(error));
          expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
        }
      },
    );
  }
  nativeTest(
    'textureChanged updates the texture id for soft-decoder fallback',
    (tester, player) async {
      final creation = player.create('https://example.invalid/swap.mp4', '');
      await tester.pump();
      await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
      await tester.pump();
      expect(await creation, 9);
      expect(player.textureId, 9);
      final seen = <int>[];
      final sub = player.textureIdStream.listen(seen.add);
      await _sendEvent({'playerId': 71, 'type': 'textureChanged', 'value': 12});
      await tester.pump();
      expect(player.textureId, 12);
      expect(seen, [12]);
      // No awaited cancel: awaiting a lone broadcast cancel() stalls in the
      // test's fake-async zone. dispose() closes the controller, which drops
      // the subscription; production cancels via the shared Future.wait path.
      unawaited(sub.cancel());
    },
  );

  nativeTest(
    'textureChanged resets a pre-swap rotation correction (#36)',
    (tester, player) async {
      final creation = player.create(
        'https://example.invalid/swap-rotation.mp4',
        '',
      );
      await tester.pump();
      await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
      await tester.pump();
      expect(await creation, 9);
      // The size event landed before the SurfaceTexture swap, so it still
      // carries the pre-swap correction for the rotated source.
      await _sendEvent({
        'playerId': 71,
        'type': 'videoSize',
        'width': 1920,
        'height': 1080,
        'rotationCorrection': 90,
      });
      await tester.pump();
      expect(player.videoRotationCorrection, 90);
      // The swap moves output to a SurfaceTexture, which applies the format
      // rotation itself: the correction must drop to 0, or the texture gets
      // rotated a second time and stretches up to fullscreen. The geometry
      // re-emit is what refreshes the feed's rotation notifier.
      final sizes = <Size>[];
      final sub = player.videoSizeStream.listen(sizes.add);
      await _sendEvent({'playerId': 71, 'type': 'textureChanged', 'value': 12});
      await tester.pump();
      expect(player.textureId, 12);
      expect(player.videoRotationCorrection, 0);
      expect(sizes, [const Size(1920, 1080)]);
      // No awaited cancel: awaiting a lone broadcast cancel() stalls in the
      // test's fake-async zone. dispose() closes the controller, which drops
      // the subscription; production cancels via the shared Future.wait path.
      unawaited(sub.cancel());
    },
  );

  nativeTest(
    'textureChanged arriving before the create reply wins over created',
    (tester, player) async {
      createGate = Completer<Map<String, dynamic>>();
      final creation = player
          .create('https://example.invalid/early-swap.mp4', '')
          .then<Object>((value) => value, onError: (Object error) => error);
      await tester.pump();
      await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
      await _sendEvent({'playerId': 71, 'type': 'textureChanged', 'value': 12});
      createGate!.complete({'playerId': 71});
      await tester.pump();
      expect(await creation, 12);
      expect(player.textureId, 12);
    },
  );

  // issue #129 / #170：变速引擎只对听书（纯音频）播放器下发，否则原生侧会让
  // 视频也走 AudioTrack 变速；默认内建 Sonic（1.0.121 的行为）。
  testWidgets('audio players request the built-in rate engine on create', (
    tester,
  ) async {
    AudioPreferences.instance.resetForTest();
    final player = NativePlayer(audioOnly: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_eventMethods, (_) async => null);
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return call.method == 'create' ? {'playerId': 71} : null;
    });
    try {
      final creation = player.create('https://example.invalid/listen.mp3', '');
      await tester.pump();
      await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
      await tester.pump();
      expect(await creation, 9);
      final arguments = calls
          .firstWhere((call) => call.method == 'create')
          .arguments
          as Map<Object?, Object?>;
      expect(arguments['audioOnly'], true);
      expect(arguments['audioRateEngine'], 'builtIn');
    } finally {
      await player.dispose();
      await tester.pump();
      await messenger.handlePlatformMessage(_eventMethods.name, null, (_) {});
      await tester.pump(const Duration(seconds: 31));
      messenger.setMockMethodCallHandler(_methods, null);
      messenger.setMockMethodCallHandler(_eventMethods, null);
      AudioPreferences.instance.resetForTest();
    }
  });

  // 视频播放器不带这两个键：老客户端的 create 参数与视频变速行为都不变。
  nativeTest('video players never send the audio rate engine', (
    tester,
    player,
  ) async {
    await _createPlayer(tester, player);
    final arguments =
        calls.firstWhere((call) => call.method == 'create').arguments
            as Map<Object?, Object?>;
    expect(arguments.containsKey('audioOnly'), false);
    expect(arguments.containsKey('audioRateEngine'), false);
  });
}

Future<void> _createPlayer(WidgetTester tester, NativePlayer player) async {
  final creation = player.create('https://example.invalid/video.mp4', '');
  await tester.pump();
  await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
  await _sendEvent({'playerId': 71, 'type': 'duration', 'value': 120000});
  await tester.pump();
  await creation;
}

Widget _playerApp(NativePlayer player) => MaterialApp(
  home: VideoPlayerChrome(
    player: player,
    episodes: [Chapter(itemId: '1', title: '第一集', volumeName: '')],
    currentIndex: 0,
    duration: player.duration,
    playing: player.playing,
    onSelectEpisode: (_) async {},
    onError: (error) => throw error,
    child: const ColoredBox(color: Colors.black),
  ),
);

Future<void> _sendEvent(Map<String, dynamic> event) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _eventMethods.name,
          _codec.encodeSuccessEnvelope(event),
          (_) {},
        );
