import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/widgets/player/story_seek_bar.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  testWidgets(
    'U01 last episode completion persists a seek beyond the last checkpoint',
    (tester) async {
      final player = ControlledNativePlayer();
      final store = MemoryReaderStore();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester);
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            bookId: 'last-episode-checkpoint',
            title: '末集完成检查',
            eps: [
              for (var index = 0; index < 3; index++)
                Chapter(
                  itemId: 'episode-$index',
                  title: '第 ${index + 1} 集',
                  volumeName: '',
                ),
            ],
            startIndex: 2,
            description: '测试剧情',
            historyStore: store,
            playerFactory: () => player,
            contentLoader: (_) async => {
              'video_url': 'https://example.invalid/final-episode.mp4',
            },
          ),
        ),
      );
      await _flush(tester);
      final chrome = tester.widget<VideoPlayerChrome>(
        find.byType(VideoPlayerChrome),
      );
      expect(chrome.autoAdvance, isTrue);
      expect(chrome.currentIndex, 2);
      expect(store.entry?['position'], 0);

      // Seek using the same callbacks as the visible timeline, then finish
      // before the periodic checkpoint. Native STATE_ENDED reports a final
      // position/completed event and isPlaying=false while playWhenReady can
      // remain true. Staying on this page must still commit the final position.
      final timeline = tester.widget<StorySeekBar>(find.byType(StorySeekBar));
      timeline.onStart(0);
      timeline.onChanged(0.99);
      timeline.onEnd(0.99);
      await _flush(tester);
      expect(player.position.inMilliseconds, 118800);
      player.emitCompleted();
      player.isPlaying = false;
      player.playingEvents.add(false);
      await _flush(tester);
      await tester.pump(const Duration(seconds: 3));
      await _flush(tester);

      expect(store.entry?['episode'], 2);
      expect(store.entry?['chapterId'], 'episode-2');
      expect(store.entry?['position'], 120);
      expect(store.entry?['progress'], 1);
      expect(player.disposed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _flush(WidgetTester tester) async {
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}
