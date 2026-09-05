import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.25});
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

  testWidgets(
    'episode switches restore speed and keep fullscreen while loading',
    (tester) async {
      final players = <FakeNativePlayer>[];
      final secondSource = Completer<Map<String, dynamic>>();
      final store = MemoryReaderStore();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            bookId: 'video-book',
            title: '测试短剧',
            eps: [
              Chapter(itemId: '1', title: '第一集', volumeName: ''),
              Chapter(itemId: '2', title: '第二集', volumeName: ''),
            ],
            startIndex: 0,
            historyStore: store,
            contentLoader: (chapter) async => chapter.itemId == '1'
                ? {'video_url': 'https://example.invalid/1.mp4'}
                : secondSource.future,
            playerFactory: () {
              final player = FakeNativePlayer();
              players.add(player);
              return player;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(players.single.isPlaying, true);
      expect(players.single.rate, 1.25);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一集'));
      await tester.pump();
      // Broadcast-stream cancellation may complete on the real event loop.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(
        players.first.disposed,
        true,
        reason:
            'history: ${store.entry}; calls: ${players.first.calls}; current: ${tester.widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome)).currentIndex}; enabled: ${tester.widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome)).enabled}',
      );
      expect(find.byType(VideoPlayerChrome), findsOneWidget);
      expect(find.byKey(const ValueKey('video-controls')), findsNothing);
      secondSource.complete({'video_url': 'https://example.invalid/2.mp4'});
      await tester.pumpAndSettle();
      expect(players, hasLength(2));
      expect(players.last.isPlaying, true);
      expect(players.last.rate, 1.25);
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(store.entry?['episode'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(players.last.disposed, true);
    },
  );

  testWidgets(
    'late source result after leaving never creates a native player',
    (tester) async {
      final source = Completer<Map<String, dynamic>>();
      var created = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            bookId: 'late',
            title: '迟到短剧',
            eps: [Chapter(itemId: '1', title: '第一集', volumeName: '')],
            startIndex: 0,
            historyStore: MemoryReaderStore(),
            contentLoader: (_) => source.future,
            playerFactory: () {
              created++;
              return FakeNativePlayer();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      source.complete({'video_url': 'https://example.invalid/late.mp4'});
      await tester.pumpAndSettle();
      expect(created, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
