import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/player_load_diagnostics.dart';
import 'package:fqapp/widgets/player/player_cover.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';

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
    'cover stays above the mounted texture until first frame; timings split phases',
    (tester) async {
      final source = Completer<Map<String, dynamic>>();
      final create = Completer<void>();
      final session = _Session(
        loader: (_) => source.future,
        factory: () =>
            ControlledNativePlayer(createGate: create, hasFirstFrame: false),
      );
      await _mount(tester, session);
      expect(find.byKey(const ValueKey('player-cover')), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
      session.elapsed = const Duration(milliseconds: 120);
      source.complete(_source('1'));
      await _flush(tester);
      session.elapsed = const Duration(milliseconds: 200);
      create.complete();
      await _flush(tester);
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byKey(const ValueKey('player-cover')), findsOneWidget);
      expect(session.samples, isEmpty);
      final textureElement = find.byType(Texture).evaluate().single;
      session.elapsed = const Duration(milliseconds: 300);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      expect(find.byKey(const ValueKey('player-cover')), findsNothing);
      expect(find.byType(Texture).evaluate().single, same(textureElement));
      final sample = session.samples.single;
      expect(sample.stagesMs['address'], 120);
      expect(sample.stagesMs['create'], 80);
      expect(sample.playToFirstFrameMs, 100);
      expect(sample.totalMs, 300);
      expect(sample.outcome, 'firstFrame');
      // Later buffering keeps the last video frame; no poster flash or new sample.
      session.players.single.emitBuffering(true);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      expect(find.byKey(const ValueKey('player-cover')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(session.samples, hasLength(1));
    },
  );

  testWidgets(
    'a frame arriving during resume initialization waits behind the cover',
    (tester) async {
      final seek = Completer<void>();
      final session = _Session(
        store: ControlledReaderStore(entry: {'episodeId': '1', 'position': 45}),
        factory: () =>
            ControlledNativePlayer(seekGate: seek, hasFirstFrame: false),
      );
      await _mount(tester, session);
      expect(find.byType(Texture), findsOneWidget);
      session.elapsed = const Duration(milliseconds: 50);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      expect(find.byKey(const ValueKey('player-cover')), findsOneWidget);
      expect(session.samples, isEmpty);
      session.elapsed = const Duration(milliseconds: 200);
      seek.complete();
      await _flush(tester);
      expect(find.byKey(const ValueKey('player-cover')), findsNothing);
      expect(session.players.single.position, const Duration(seconds: 45));
      expect(session.samples.single.firstFrameMs, 50);
      expect(session.samples.single.totalMs, 200);
      expect(session.samples.single.playToFirstFrameMs, isNull);
    },
  );

  testWidgets(
    'prefetch waits for first frame and fetches just one address without a player',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      await tester.pump(const Duration(seconds: 2));
      await _flush(tester);
      expect(session.requests, ['1']);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(session.requests, ['1']);
      await tester.pump(const Duration(milliseconds: 200));
      await _flush(tester);
      expect(session.requests, ['1', '2']);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(session.requests, ['1', '2']);
      expect(session.players, hasLength(1));
      expect(session.players.single.isPlaying, true);
      expect(session.store.entry?['episodeId'], '1');
    },
  );

  testWidgets(
    'a completed prefetch removes address wait from the next selection',
    (tester) async {
      final sources = [
        Completer<Map<String, dynamic>>(),
        Completer<Map<String, dynamic>>(),
      ];
      final session = _Session(
        loader: (chapter) => sources[int.parse(chapter.itemId) - 1].future,
      );
      await _mount(tester, session);
      session.elapsed = const Duration(milliseconds: 350);
      sources[0].complete(_source('1'));
      await _flush(tester);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      expect(session.samples.single.stagesMs['address'], 350);
      session.elapsed += const Duration(seconds: 1);
      await tester.pump(const Duration(seconds: 1));
      expect(session.requests, ['1', '2']);
      session.elapsed += const Duration(milliseconds: 350);
      sources[1].complete(_source('2'));
      await _flush(tester);
      expect(session.players, hasLength(1));
      await _choose(tester, 1);
      session.elapsed += const Duration(milliseconds: 80);
      session.players.last.emitFirstFrame();
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(session.requests, ['1', '2']);
      final sample = session.samples.last;
      expect(sample.episode, 2);
      expect(sample.source, 'prefetchHit');
      expect(sample.stagesMs['address'], 0);
      expect(sample.playToFirstFrameMs, 80);
      expect(sample.totalMs, 80);
    },
  );

  testWidgets(
    'selecting during prefetch shares the request and waits for its first frame',
    (tester) async {
      final second = Completer<Map<String, dynamic>>();
      final session = _Session(
        loader: (chapter) => chapter.itemId == '2'
            ? second.future
            : Future.value(_source(chapter.itemId)),
      );
      await _mount(tester, session);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      await _choose(tester, 1);
      expect(session.requests, ['1', '2']);
      expect(session.players, hasLength(1));
      expect(find.text('正在加载第 2 集'), findsOneWidget);
      second.complete(_source('2'));
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(find.byKey(const ValueKey('player-cover')), findsOneWidget);
      session.players.last.emitFirstFrame();
      await _flush(tester);
      expect(session.samples.last.source, 'prefetchPending');
      expect(session.players.last.isPlaying, true);
      expect(session.store.entry?['episodeId'], '2');
    },
  );

  testWidgets(
    'failed prefetch leaves playback intact and demand fetches a fresh address',
    (tester) async {
      var attempts = 0;
      final session = _Session(
        loader: (chapter) {
          if (chapter.itemId == '2' && attempts++ == 0) {
            return Future.error(StateError('speculative source failed'));
          }
          return Future.value(_source(chapter.itemId));
        },
      );
      await _mount(tester, session);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      await _flush(tester);
      expect(session.players.single.isPlaying, true);
      expect(find.textContaining('speculative source failed'), findsNothing);
      await _choose(tester, 1);
      session.players.last.emitFirstFrame();
      await _flush(tester);
      expect(session.requests, ['1', '2', '2']);
      expect(session.samples.last.source, 'network');
      expect(session.players.last.isPlaying, true);
    },
  );

  for (final displayed in [false, true]) {
    testWidgets(
      'a cached source failure ${displayed ? 'after' : 'before'} the first frame retries fresh with only displayed progress',
      (tester) async {
        final session = _Session();
        await _mount(tester, session);
        session.players.single.emitFirstFrame();
        await _flush(tester);
        await tester.pump(const Duration(seconds: 1));
        await _flush(tester);
        await _choose(tester, 1);
        if (displayed) {
          session.players.last.emitFirstFrame();
          await _flush(tester);
        }
        session.players.last.emitPosition(const Duration(seconds: 13));
        session.players.last.errors.add(StateError('expired stream'));
        await _flush(tester);
        expect(session.samples.last.source, 'prefetchHit');
        expect(
          session.samples.last.outcome,
          displayed ? 'firstFrame' : 'error',
        );
        expect(session.store.entry?['episodeId'], displayed ? '2' : '1');
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
        await tester.pump(const Duration(milliseconds: 350));
        await _flush(tester);
        expect(session.requests, ['1', '2', '2']);
        expect(
          session.players.last.position,
          displayed ? const Duration(seconds: 13) : Duration.zero,
        );
        session.players.last.emitFirstFrame();
        await _flush(tester);
        expect(session.samples.last.source, 'network');
        expect(session.samples.last.trigger, 'retry');
        expect(session.players.last.isPlaying, true);
      },
    );
  }

  for (final interruption in ['background', 'pause', 'buffering', 'paging']) {
    testWidgets(
      '$interruption cancels delayed prefetch until playback is eligible again',
      (tester) async {
        final session = _Session();
        await _mount(tester, session);
        final player = session.players.single;
        player.emitFirstFrame();
        await _flush(tester);
        await tester.pump(const Duration(milliseconds: 300));
        switch (interruption) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          case 'pause':
            await player.pause();
          case 'buffering':
            player.emitBuffering(true);
          case 'paging':
            _chrome(tester).onPagingChanged!(true);
        }
        await _flush(tester);
        await tester.pump(const Duration(seconds: 2));
        await _flush(tester);
        expect(session.requests, ['1']);
        switch (interruption) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          case 'pause':
            await player.play();
          case 'buffering':
            player.emitBuffering(false);
          case 'paging':
            _chrome(tester).onPagingChanged!(false);
        }
        await _flush(tester);
        await tester.pump(const Duration(seconds: 1));
        await _flush(tester);
        expect(session.requests, ['1', '2']);
        expect(session.players, hasLength(1));
      },
    );
  }

  testWidgets(
    'queued lookahead rechecks background and resumes without stale prefetch',
    (tester) async {
      final second = Completer<Map<String, dynamic>>();
      final session = _Session(
        loader: (chapter) => chapter.itemId == '2'
            ? second.future
            : Future.value(_source(chapter.itemId)),
      );
      await _mount(tester, session);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      await _choose(tester, 2);
      session.players.last.emitFirstFrame();
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(session.requests, ['1', '2', '3']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      second.complete(_source('2'));
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(session.requests, ['1', '2', '3']);
      expect(session.players, hasLength(2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      await _flush(tester);
      expect(session.requests, ['1', '2', '3', '4']);
      expect(_chrome(tester).playingIndex, 2);
      expect(session.players.last.isPlaying, true);
    },
  );

  testWidgets('quick switching cannot activate a late prefetched episode', (
    tester,
  ) async {
    final second = Completer<Map<String, dynamic>>();
    final session = _Session(
      loader: (chapter) => chapter.itemId == '2'
          ? second.future
          : Future.value(_source(chapter.itemId)),
    );
    await _mount(tester, session);
    session.players.single.emitFirstFrame();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await _choose(tester, 1);
    await _choose(tester, 3);
    second.complete(_source('2'));
    await _flush(tester);
    session.players.last.emitFirstFrame();
    await _flush(tester);
    expect(session.requests, ['1', '2', '4']);
    expect(session.players, hasLength(2));
    expect(
      session.players.last.calls.first,
      'create:https://example.invalid/4.mp4',
    );
    expect(session.store.entry?['episodeId'], '4');
    expect(
      session.samples.where((sample) => sample.episode == 2).single.outcome,
      'superseded',
    );
  });

  testWidgets(
    'leaving drops speculative results and reentry gets a new page cache',
    (tester) async {
      final second = Completer<Map<String, dynamic>>();
      final session = _Session(
        loader: (chapter) => chapter.itemId == '2'
            ? second.future
            : Future.value(_source(chapter.itemId)),
      );
      await _mount(tester, session);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      second.completeError(StateError('late prefetch'));
      await _flush(tester);
      expect(tester.takeException(), isNull);
      expect(session.players.single.disposed, true);
      await tester.pumpWidget(session.app());
      await _flush(tester);
      expect(session.requests, ['1', '2', '1']);
      expect(session.players, hasLength(2));
    },
  );

  testWidgets('adjacent pages show the same cover placeholder during a drag', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    session.players.single.emitFirstFrame();
    await _flush(tester);
    final gesture = await tester.startGesture(const Offset(200, 380));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -130));
    await _flush(tester);
    final adjacent = find.descendant(
      of: find.byKey(const ValueKey('episode-page-1')),
      matching: find.byType(PlayerCover),
    );
    expect(adjacent, findsOneWidget);
    expect(tester.widget<PlayerCover>(adjacent).loading, false);
    expect(tester.widget<PlayerCover>(adjacent).label, '第 2 集');
    expect(session.players, hasLength(1));
    await gesture.cancel();
    await tester.pump(const Duration(seconds: 1));
    await _flush(tester);
  });

  testWidgets('last episode never starts lookahead', (tester) async {
    final session = _Session(startIndex: 4);
    await _mount(tester, session);
    session.players.single.emitFirstFrame();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 3));
    await _flush(tester);
    expect(session.requests, ['5']);
    expect(session.players, hasLength(1));
  });
}

Map<String, dynamic> _source(String id) => {
  'video_url': 'https://example.invalid/$id.mp4',
};

VideoPlayerChrome _chrome(WidgetTester tester) =>
    tester.widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome));

Future<void> _choose(WidgetTester tester, int index) async {
  unawaited(_chrome(tester).onSelectEpisode(index));
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

class _Session {
  final ControlledReaderStore store;
  final Future<Map<String, dynamic>> Function(Chapter)? loader;
  final ControlledNativePlayer Function()? factory;
  final int startIndex;
  final players = <ControlledNativePlayer>[];
  final requests = <String>[];
  final samples = <PlayerLoadSample>[];
  Duration elapsed = Duration.zero;

  _Session({
    ControlledReaderStore? store,
    this.loader,
    this.factory,
    this.startIndex = 0,
  }) : store = store ?? ControlledReaderStore();

  Widget app() => MaterialApp(
    home: PlayerPage(
      bookId: 'loading-book',
      title: '加载体验测试',
      eps: [
        for (var index = 1; index <= 5; index++)
          Chapter(itemId: '$index', title: '第 $index 集', volumeName: ''),
      ],
      startIndex: startIndex,
      historyStore: store,
      loadDiagnostics: PlayerLoadDiagnostics(
        now: () => elapsed,
        report: samples.add,
      ),
      contentLoader: (chapter) {
        requests.add(chapter.itemId);
        return loader?.call(chapter) ?? Future.value(_source(chapter.itemId));
      },
      playerFactory: () {
        final player =
            factory?.call() ?? ControlledNativePlayer(hasFirstFrame: false);
        players.add(player);
        return player;
      },
    ),
  );
}
