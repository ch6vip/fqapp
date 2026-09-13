import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/native_player.dart';

const _methods = MethodChannel('fqapp/native_player');
const _eventMethods = MethodChannel('fqapp/native_player/events');
const _codec = StandardMethodCodec();

final List<Completer<void>> _heldGates = [];

void main() {
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    _heldGates.clear();
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_eventMethods, (_) async => null);
  });

  void nativeTest(
    String name,
    Future<void> Function(WidgetTester, NativePlayer) body,
  ) {
    testWidgets(name, (tester) async {
      final player = NativePlayer();
      try {
        await body(tester, player);
      } finally {
        await _cleanUp(tester, player, messenger);
      }
    });
  }

  Completer<void> hold() {
    final gate = Completer<void>();
    _heldGates.add(gate);
    return gate;
  }

  nativeTest(
    'a seek that fails after an accepted overlapping seek keeps the accepted position',
    (tester, player) async {
      final accepted = hold();
      var seekCalls = 0;
      messenger.setMockMethodCallHandler(_methods, (call) async {
        if (call.method == 'create') return {'playerId': 71};
        if (call.method == 'seek') {
          seekCalls++;
          if (seekCalls == 1) {
            await accepted.future;
            return null;
          }
          throw PlatformException(code: 'boom', message: 'seek failed');
        }
        return null;
      });
      await _createdPlayer(tester, player, 'overlap late ack');

      final first = player.seek(const Duration(seconds: 30));
      await tester.pump();
      final second = player.seek(const Duration(seconds: 60));
      final secondResult = second.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await tester.pump();

      // The newer seek failed first; the older one is acknowledged afterwards.
      accepted.complete();
      await first;
      expect(await secondResult, isA<PlatformException>());
      expect(seekCalls, 2);
      expect(player.position, const Duration(seconds: 30));
    },
  );

  nativeTest('an accepted seek survives a newer overlapping seek that fails', (
    tester,
    player,
  ) async {
    final accepted = hold();
    final failing = hold();
    var seekCalls = 0;
    messenger.setMockMethodCallHandler(_methods, (call) async {
      if (call.method == 'create') return {'playerId': 71};
      if (call.method == 'seek') {
        seekCalls++;
        if (seekCalls == 1) {
          await accepted.future;
          return null;
        }
        await failing.future;
        throw PlatformException(code: 'boom', message: 'seek failed');
      }
      return null;
    });
    await _createdPlayer(tester, player, 'overlap early ack');

    final first = player.seek(const Duration(seconds: 30));
    await tester.pump();
    final second = player.seek(const Duration(seconds: 60));
    final secondResult = second.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await tester.pump();

    // The older seek is acknowledged while the newer one is still in flight.
    accepted.complete();
    await first;
    expect(player.position, const Duration(seconds: 30));

    // The newer seek then fails at the channel; the accepted position stays.
    failing.complete();
    expect(await secondResult, isA<PlatformException>());
    expect(seekCalls, 2);
    expect(player.position, const Duration(seconds: 30));
  });

  nativeTest(
    'the newest successful seek still wins over an older acknowledged seek',
    (tester, player) async {
      final olderGate = hold();
      var seekCalls = 0;
      messenger.setMockMethodCallHandler(_methods, (call) async {
        if (call.method == 'create') return {'playerId': 71};
        if (call.method == 'seek') {
          seekCalls++;
          if (seekCalls == 1) {
            await olderGate.future;
            return null;
          }
          return null;
        }
        return null;
      });
      await _createdPlayer(tester, player, 'newest');

      final first = player.seek(const Duration(seconds: 30));
      await tester.pump();
      final second = player.seek(const Duration(seconds: 60));
      await tester.pump();
      await second;
      expect(player.position, const Duration(seconds: 60));

      olderGate.complete();
      await first;
      expect(seekCalls, 2);
      expect(player.position, const Duration(seconds: 60));
    },
  );
}

Future<NativePlayer> _createdPlayer(
  WidgetTester tester,
  NativePlayer player,
  String name,
) async {
  final creation = player.create('https://example.invalid/$name.mp4', '');
  await tester.pump();
  await _sendEvent({'playerId': 71, 'type': 'created', 'value': 9});
  await tester.pump();
  await creation;
  return player;
}

Future<void> _cleanUp(
  WidgetTester tester,
  NativePlayer player,
  TestDefaultBinaryMessenger messenger,
) async {
  for (final gate in _heldGates) {
    if (!gate.isCompleted) gate.complete();
  }
  _heldGates.clear();
  await tester.pump();
  await player.dispose();
  await messenger.handlePlatformMessage(_eventMethods.name, null, (_) {});
  await tester.pump();
  await tester.pump(const Duration(seconds: 31));
  messenger.setMockMethodCallHandler(_methods, null);
  messenger.setMockMethodCallHandler(_eventMethods, null);
}

Future<void> _sendEvent(Map<String, dynamic> event) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _eventMethods.name,
          _codec.encodeSuccessEnvelope(event),
          (_) {},
        );
