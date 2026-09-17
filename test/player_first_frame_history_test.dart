import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  for (final fail in [false, true]) {
    testWidgets(
      'a prepared video without a frame preserves resume on ${fail ? 'failure' : 'exit'}',
      (tester) async {
        final store = _store();
        final player = ControlledNativePlayer(hasFirstFrame: false);
        await _mount(tester, store, player);
        expect(player.isPlaying, isTrue);
        expect(store.entry?['episodeId'], '1');
        expect(store.entry?['position'], 73);
        if (fail) {
          player.errors.add(StateError('CDN open failed after create'));
          await _flush(tester);
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
          await _flush(tester);
        }
        expect(store.entry?['episodeId'], '1');
        expect(store.entry?['position'], 73);
        expect(store.seconds, 0);
      },
    );
  }

  testWidgets(
    'first frame commits the episode and later failures save progress',
    (tester) async {
      final store = _store();
      final player = ControlledNativePlayer(hasFirstFrame: false);
      await _mount(tester, store, player);
      expect(store.entry?['episodeId'], '1');
      player.emitFirstFrame();
      await _flush(tester);
      expect(store.entry?['episodeId'], '2');
      player.emitPosition(const Duration(seconds: 47));
      player.errors.add(StateError('interrupted after a visible frame'));
      await _flush(tester);
      expect(store.entry?['episodeId'], '2');
      expect(store.entry?['position'], 47);
    },
  );

  testWidgets(
    'a frame arriving during initialization waits for the ready state',
    (tester) async {
      final store = _store();
      final rate = Completer<void>();
      final player = ControlledNativePlayer(
        hasFirstFrame: false,
        rateGate: rate,
      );
      addTearDown(() {
        if (!rate.isCompleted) rate.complete();
      });
      await _mount(tester, store, player);
      player.emitFirstFrame();
      await _flush(tester);
      expect(store.entry?['episodeId'], '1');
      rate.complete();
      await _flush(tester);
      expect(store.entry?['episodeId'], '2');
      expect(player.isPlaying, isTrue);
    },
  );
}

ControlledReaderStore _store() => ControlledReaderStore(
  entry: {
    'id': 'series',
    'bookId': 'series',
    'kind': 'video',
    'episodeId': '1',
    'chapterId': '1',
    'episode': 0,
    'position': 73,
    'duration': 120,
  },
);

Future<void> _mount(
  WidgetTester tester,
  ControlledReaderStore store,
  ControlledNativePlayer player,
) async {
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        bookId: 'series',
        title: '短剧',
        eps: [
          Chapter(itemId: '1', title: '第一集', volumeName: ''),
          Chapter(itemId: '2', title: '第二集', volumeName: ''),
        ],
        startIndex: 1,
        contentLoader: (chapter) async => {
          'data': {'video_url': 'https://cdn.example/${chapter.itemId}.mp4'},
        },
        playerFactory: () => player,
        historyStore: store,
      ),
    ),
  );
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}
