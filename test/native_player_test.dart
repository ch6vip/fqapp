import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/native_player.dart';

const _methods = MethodChannel('fqapp/native_player');
const _eventMethods = MethodChannel('fqapp/native_player/events');
const _codec = StandardMethodCodec();

void main() {
  late List<MethodCall> calls;
  Completer<Map<String, dynamic>>? createGate;
  Completer<void>? disposeGate;

  setUp(() {
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
}

Future<void> _sendEvent(Map<String, dynamic> event) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _eventMethods.name,
          _codec.encodeSuccessEnvelope(event),
          (_) {},
        );
