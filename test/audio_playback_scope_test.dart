import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
  });

  testWidgets(
    'reader capsule controls the retained audio session and yields to menus',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      final player = app.players.single;
      app.navigator.currentState!.pop();
      await _flush(tester);
      app.openReader();
      await _flush(tester);
      final pill = find.byKey(const ValueKey('reader_player_pill'));
      expect(pill, findsOneWidget);
      await tester.tap(pill);
      await _flush(tester);
      expect(player.isPlaying, isFalse);
      expect(find.text('继续播放'), findsOneWidget);
      await tester.tap(pill);
      await _flush(tester);
      expect(player.isPlaying, isTrue);
      final surface = find.byKey(const ValueKey('reader-page-surface'));
      await tester.tapAt(tester.getCenter(surface));
      await _flush(tester);
      expect(pill, findsNothing);
    },
  );

  testWidgets(
    'popping the audio page preserves playback and reopening reuses it',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      final player = app.players.single;
      player.emitPosition(const Duration(seconds: 37));
      await _flush(tester);

      app.navigator.currentState!.pop();
      await _flush(tester);
      expect(player.disposed, isFalse);
      expect(player.isPlaying, isTrue);
      expect(ListeningSession.instance.playing, isTrue);
      // 官方没有迷你播放条：离开听书页后只保活，不另挂控制条。
      expect(find.byKey(const ValueKey('audio-mini-open')), findsNothing);

      app.open();
      await _flush(tester);
      expect(app.players, hasLength(1));
      expect(player.position, const Duration(seconds: 37));
    },
  );

  testWidgets(
    'switching books waits for old native release before creating another',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      final player = app.players.single;
      final release = Completer<void>();
      player.releaseGate = release;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      app.navigator.currentState!.pop();
      await _flush(tester);
      app.open(bookId: 'second');
      await _flush(tester);
      expect(app.players, hasLength(1));
      expect(player.disposed, isTrue);

      release.complete();
      await _flush(tester);
      expect(app.players, hasLength(2));
      expect(app.players.last.isPlaying, isTrue);
      expect(ListeningSession.instance.bookId, 'second');
    },
  );

  testWidgets(
    'paragraph requests seek the live work and route changes keep playing',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      final previous = app.players.single;
      app.navigator.currentState!.pop();
      await _flush(tester);
      app.open(startIndex: 1, startPosition: const Duration(seconds: 42));
      await _flush(tester);
      expect(previous.disposed, isTrue);
      expect(app.players.last.position, const Duration(seconds: 42));
      expect(ListeningSession.instance.chapterId, 'book-2');

      unawaited(
        app.navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('正文阅读页')),
          ),
        ),
      );
      await _flush(tester);
      // 换路由不影响播放；迷你栏已移除，这里只验证播放状态本身。
      expect(app.players.last.isPlaying, isTrue);
    },
  );

  testWidgets(
    'another media request cancels narration still waiting for its source',
    (tester) async {
      final app = await _mount(tester);
      final source = Completer<AudioSource>();
      app.sourceGate = source;
      app.open();
      await _flush(tester);
      expect(app.players, isEmpty);
      final video = ControlledNativePlayer();
      await NativePlayer.beforePlay!(video);
      source.complete(
        AudioSource(itemId: 'book-1', url: 'https://example.invalid/audio.mp3'),
      );
      await _flush(tester);
      expect(app.players.single.isPlaying, isFalse);
      await video.dispose();
    },
  );
}

Future<_Harness> _mount(WidgetTester tester) async {
  final app = _Harness();
  await tester.binding.setSurfaceSize(const Size(430, 932));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: app.navigator,
      builder: (_, child) =>
          AudioPlaybackScope(navigatorKey: app.navigator, child: child!),
      home: const Scaffold(body: Text('书架')),
    ),
  );
  return app;
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  // Route pop transitions advance per frame, not per elapsed time: a
  // single long pump does not finish them. Pump several more frames so
  // the popped page disposes and the scope rebuilds its mini bar.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

class _Harness {
  final navigator = GlobalKey<NavigatorState>();
  final store = ControlledReaderStore();
  final players = <ControlledNativePlayer>[];
  Completer<AudioSource>? sourceGate;

  /// 打开同一本书的阅读页：迷你栏留在原地，阅读页在 initState 里注册
  /// 「跳到播放位置」。
  void openReader({String bookId = 'book'}) {
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            bookId: bookId,
            title: bookId,
            chapters: [
              for (var i = 1; i <= 2; i++)
                Chapter(itemId: '$bookId-$i', title: '第 $i 章', volumeName: ''),
            ],
            startIndex: 0,
            localOnly: true,
            readerStore: store,
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async => '第一段。\n第二段。',
            readerDevice: _NullDevice(),
          ),
        ),
      ),
    );
  }

  void open({
    String bookId = 'book',
    int startIndex = 0,
    Duration? startPosition,
  }) {
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => AudioPage(
            bookId: bookId,
            title: bookId,
            chapters: [
              for (var i = 1; i <= 2; i++)
                Chapter(itemId: '$bookId-$i', title: '第 $i 章', volumeName: ''),
            ],
            startIndex: startIndex,
            startPosition: startPosition,
            historyStore: store,
            sourceLoader: (id, {toneId}) async => sourceGate != null
                ? await sourceGate!.future
                : AudioSource(
                    itemId: id,
                    url: 'https://example.invalid/audio.mp3',
                    toneId: toneId ?? '0',
                  ),
            voicesLoader: () async => const [],
            // The reader only shows the play/pause capsule while the spoken
            // sentence is on screen; give this session a cue that exists in
            // the reader's text.
            subtitleLoader: (id, toneId) async =>
                SubtitleTrack([SubtitleCue(startMs: 0, text: '第一段。')]),
            playerFactory: () {
              final player = ControlledNativePlayer();
              players.add(player);
              return player;
            },
          ),
        ),
      ),
    );
  }
}

class _NullDevice extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 9, 10, 21, 16),
    battery: 64,
    systemBrightness: .45,
  );
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
}
