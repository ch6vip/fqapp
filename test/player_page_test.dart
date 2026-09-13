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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  testWidgets('playback statistics reject restore and seek jumps', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.binding.setSurfaceSize(null);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final store = ControlledReaderStore();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 10);
    await tester.pumpWidget(_app(store: store, player: player));
    await _flush(tester);
    expect(player.isPlaying, isTrue);

    // A restore/seek jump must never be counted as newly watched time.
    player.emitPosition(const Duration(seconds: 300));
    await _flush(tester);

    // The production accumulator is a Stopwatch, so only real wall-clock
    // playback advances it; the virtual test clock above does not.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flush(tester);

    expect(store.entry?['position'], 300);
    expect(store.seconds, greaterThan(0));
    expect(store.seconds, lessThan(30));

    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}

Map<String, dynamic> _source(String id) => {
  'video_url': 'https://example.invalid/$id.mp4',
};

Widget _app({
  required ControlledReaderStore store,
  required ControlledNativePlayer player,
}) => MaterialApp(
  home: PlayerPage(
    bookId: 'stats-book',
    title: '统计测试',
    eps: [
      Chapter(itemId: '1', title: '第 1 集', volumeName: ''),
      Chapter(itemId: '2', title: '第 2 集', volumeName: ''),
    ],
    startIndex: 0,
    historyStore: store,
    contentLoader: (chapter) async => _source(chapter.itemId),
    playerFactory: () => player,
  ),
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}
