import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
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
    'paging waits for the finger to settle before creating a player',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -650));
      await _flush(tester);
      expect(_chrome(tester).currentIndex, 1);
      expect(session.players, hasLength(1));
      await gesture.moveBy(const Offset(0, -800));
      await _flush(tester);
      expect(_chrome(tester).currentIndex, 2);
      expect(session.players, hasLength(1));
      await gesture.up();
      await tester.pumpAndSettle();
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(
        session.players.last.calls.first,
        'create:https://example.invalid/3.mp4',
      );
      expect(session.players.last.isPlaying, true);
      expect(session.store.entry?['episodeId'], '3');
    },
  );

  testWidgets('immediate reentry waits for the previous page history save', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    session.players.single.emitPosition(const Duration(seconds: 73));
    final write = session.store.writeGate = Completer<void>();
    addTearDown(() {
      if (!write.isCompleted) write.complete();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.pumpWidget(session.app());
    await _flush(tester);
    expect(session.players, hasLength(1));
    write.complete();
    await _flush(tester);
    expect(session.players, hasLength(2));
    expect(session.players.last.position, const Duration(seconds: 73));
    expect(session.players.last.isPlaying, true);
    expect(session.store.entry?['position'], 73);
  });

  testWidgets('a source that finishes in the background starts on foreground', (
    tester,
  ) async {
    final source = Completer<Map<String, dynamic>>();
    final session = _Session(loader: (_) => source.future);
    await _mount(tester, session);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    source.complete(_source('1'));
    await _flush(tester);
    expect(session.players.single.calls, isNot(contains('play')));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flush(tester);
    expect(session.players.single.isPlaying, true);
    await tester.tap(find.byTooltip('暂停'));
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flush(tester);
    expect(session.players.single.isPlaying, false);
  });

  testWidgets(
    'backgrounding saves the latest position without waiting for a timer',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 37));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      expect(session.store.entry?['position'], 37);
      expect(session.players.single.isPlaying, false);
    },
  );

  for (final order in [
    ['2', '3', '4'],
    ['4', '2', '3'],
    ['3', 'error:2', '4'],
  ]) {
    testWidgets('only the last selection plays when sources finish $order', (
      tester,
    ) async {
      final sources = {
        for (final id in ['2', '3', '4']) id: Completer<Map<String, dynamic>>(),
      };
      final session = _Session(
        loader: (chapter) =>
            sources[chapter.itemId]?.future ??
            Future.value(_source(chapter.itemId)),
      );
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 41));
      for (final index in [1, 2, 3]) {
        await _choose(tester, index);
      }
      expect(session.requests, ['1', '2', '3', '4']);
      for (final result in order) {
        if (result.startsWith('error:')) {
          sources[result.split(':').last]!.completeError(
            StateError('old request failed'),
          );
        } else {
          sources[result]!.complete(_source(result));
        }
        await _flush(tester);
      }
      expect(session.players, hasLength(2));
      expect(session.players.first.disposed, true);
      expect(
        session.players.last.calls.first,
        'create:https://example.invalid/4.mp4',
      );
      expect(session.players.last.isPlaying, true);
      expect(session.players.last.rate, 1.25);
      expect(_chrome(tester).playingIndex, 3);
      expect(session.store.entry?['episodeId'], '4');
      expect(session.store.entry?['position'], 0);
      expect(
        session.store.writes
            .where((entry) => entry['episodeId'] == '1')
            .last['position'],
        41,
      );
      expect(find.textContaining('old request failed'), findsNothing);
    });
  }

  testWidgets(
    'reversing a pending selection resumes the actual previous episode',
    (tester) async {
      final second = Completer<Map<String, dynamic>>();
      final session = _Session(
        loader: (chapter) => chapter.itemId == '2'
            ? second.future
            : Future.value(_source(chapter.itemId)),
      );
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 54));
      await _choose(tester, 1);
      await _choose(tester, 0);
      expect(session.players, hasLength(2));
      expect(session.players.last.position, const Duration(seconds: 54));
      expect(session.players.last.isPlaying, true);
      second.completeError(StateError('stale source failed'));
      await _flush(tester);
      expect(_chrome(tester).playingIndex, 0);
      expect(find.textContaining('stale source failed'), findsNothing);
    },
  );

  testWidgets(
    'new selections all wait for a detached player to finish releasing',
    (tester) async {
      final release = Completer<void>();
      final first = ControlledNativePlayer(releaseGate: release);
      var created = 0;
      final session = _Session(
        factory: () => created++ == 0 ? first : ControlledNativePlayer(),
      );
      await _mount(tester, session);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await _choose(tester, 1);
      await _choose(tester, 2);
      expect(session.players, hasLength(1));
      expect(first.disposed, true);
      expect(first.calls, isNot(contains('released')));
      release.complete();
      await _flush(tester);
      expect(first.calls, contains('released'));
      expect(session.players, hasLength(2));
      expect(
        session.players.last.calls.first,
        'create:https://example.invalid/3.mp4',
      );
      expect(session.players.last.isPlaying, true);
    },
  );

  for (final operation in ['create', 'rate', 'seek', 'play']) {
    testWidgets(
      'switching during $operation never activates the stale player',
      (tester) async {
        final gate = Completer<void>();
        final first = ControlledNativePlayer(
          createGate: operation == 'create' ? gate : null,
          rateGate: operation == 'rate' ? gate : null,
          seekGate: operation == 'seek' ? gate : null,
          playGate: operation == 'play' ? gate : null,
        );
        var created = 0;
        final session = _Session(
          store: ControlledReaderStore(entry: {'episode': 0, 'position': 42}),
          factory: () => created++ == 0 ? first : ControlledNativePlayer(),
        );
        await _mount(tester, session);
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        await _choose(tester, 2);
        expect(first.disposed, true);
        expect(session.players.last.isPlaying, true);
        gate.complete();
        await _flush(tester);
        expect(first.isPlaying, false);
        if (operation != 'play') expect(first.calls, isNot(contains('play')));
        expect(first.calls.where((call) => call == 'dispose'), hasLength(1));
        expect(_chrome(tester).playingIndex, 2);
        expect(session.store.entry?['episodeId'], '3');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'leaving during creation releases the candidate and ignores its result',
    (tester) async {
      final gate = Completer<void>();
      final session = _Session(
        factory: () => ControlledNativePlayer(createGate: gate),
      );
      await _mount(tester, session);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(session.players.single.disposed, true);
      gate.complete();
      await _flush(tester);
      expect(session.players.single.calls, isNot(contains('play')));
      expect(session.store.entry, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a native playback error retries the same episode at its saved position',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 62));
      session.players.single.errors.add(StateError('decode failed'));
      await _flush(tester);
      expect(find.textContaining('decode failed'), findsOneWidget);
      expect(session.players.single.disposed, true);
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pump(const Duration(milliseconds: 350));
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(session.players.last.position, const Duration(seconds: 62));
      expect(session.players.last.isPlaying, true);
      expect(find.textContaining('decode failed'), findsNothing);
    },
  );

  testWidgets(
    'a retry superseded by a new selection cannot replace its player',
    (tester) async {
      var attempts = 0;
      final retry = Completer<Map<String, dynamic>>();
      final session = _Session(
        loader: (chapter) {
          if (chapter.itemId != '1') {
            return Future.value(_source(chapter.itemId));
          }
          return attempts++ == 0
              ? Future.error(StateError('source unavailable'))
              : retry.future;
        },
      );
      await _mount(tester, session);
      expect(find.textContaining('source unavailable'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pump(const Duration(milliseconds: 350));
      await _flush(tester);
      expect(session.requests, ['1', '1']);
      await _choose(tester, 3);
      retry.completeError(StateError('stale retry failed'));
      await _flush(tester);
      expect(session.players, hasLength(1));
      expect(
        session.players.single.calls.first,
        'create:https://example.invalid/4.mp4',
      );
      expect(session.players.single.isPlaying, true);
      expect(find.textContaining('stale retry failed'), findsNothing);
    },
  );

  testWidgets(
    'manual selection wins over automatic advance and duplicate completion',
    (tester) async {
      final second = Completer<Map<String, dynamic>>();
      final session = _Session(
        loader: (chapter) => chapter.itemId == '2'
            ? second.future
            : Future.value(_source(chapter.itemId)),
      );
      await _mount(tester, session);
      final first = session.players.single;
      first.emitCompleted();
      first.emitCompleted();
      await _choose(tester, 3);
      second.complete(_source('2'));
      await _flush(tester);
      expect(session.requests, ['1', '2', '4']);
      expect(session.players, hasLength(2));
      expect(_chrome(tester).playingIndex, 3);
      expect(session.store.entry?['episodeId'], '4');
    },
  );

  testWidgets(
    'completion during a cancelled page drag advances after settling',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -70));
      await _flush(tester);
      session.players.single.emitCompleted();
      expect(session.requests, ['1']);
      await gesture.cancel();
      // Let the page spring settle, then flush native stream cancellation when
      // automatic advance starts. Loading can keep pumpAndSettle animating.
      for (
        var step = 0;
        step < 6 && _chrome(tester).playingIndex != 1;
        step++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
        await _flush(tester);
      }
      expect(session.requests, ['1', '2']);
      expect(_chrome(tester).playingIndex, 1);
      expect(session.players.last.isPlaying, true);
    },
  );

  testWidgets(
    'current selection and first or last episode boundaries do not reload',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      for (final index in [-1, 0, 5]) {
        await _choose(tester, index);
      }
      expect(session.requests, ['1']);
      await _choose(tester, 4);
      session.players.last.emitCompleted();
      session.players.last.emitCompleted();
      await _flush(tester);
      expect(session.requests, ['1', '5']);
      expect(_chrome(tester).playingIndex, 4);
      expect(session.players, hasLength(2));
    },
  );

  for (final scenario
      in <({String name, Map<String, dynamic> saved, int milliseconds})>[
        (
          name: 'legacy index',
          saved: {'episode': 0, 'position': 37.5},
          milliseconds: 37500,
        ),
        (
          name: 'matching id after reorder',
          saved: {'episodeId': '1', 'episode': 2, 'position': 37.5},
          milliseconds: 37500,
        ),
        (
          name: 'mismatching id',
          saved: {'episodeId': '2', 'episode': 0, 'position': 37.5},
          milliseconds: 0,
        ),
        (
          name: 'wrong type',
          saved: {'episode': 'broken', 'position': 'broken'},
          milliseconds: 0,
        ),
        (
          name: 'negative position',
          saved: {'episode': 0, 'position': -5},
          milliseconds: 0,
        ),
        (
          name: 'nonfinite position',
          saved: {'episode': 0, 'position': double.nan},
          milliseconds: 0,
        ),
        (
          name: 'completed episode',
          saved: {'episode': 0, 'position': 120},
          milliseconds: 0,
        ),
        (
          name: 'oversized position',
          saved: {'episode': 0, 'position': 1e308},
          milliseconds: 0,
        ),
      ]) {
    testWidgets('resume handles ${scenario.name}', (tester) async {
      final session = _Session(
        store: ControlledReaderStore(entry: scenario.saved),
      );
      await _mount(tester, session);
      expect(session.players.single.isPlaying, true);
      expect(
        session.players.single.position.inMilliseconds,
        scenario.milliseconds,
      );
      expect(session.store.entry?['position'], scenario.milliseconds / 1000);
      expect(find.text('重试'), findsNothing);
    });
  }

  testWidgets(
    'resume position is preserved while native duration is still unknown',
    (tester) async {
      final session = _Session(
        store: ControlledReaderStore(
          entry: {'episode': 0, 'position': 37.5, 'duration': 120},
        ),
        factory: () => ControlledNativePlayer()..totalDuration = Duration.zero,
      );
      await _mount(tester, session);
      expect(session.players.single.position.inMilliseconds, 37500);
      expect(session.store.entry?['position'], 37.5);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(session.store.entry?['position'], 37.5);
    },
  );

  testWidgets('a failed history write does not stop playback or later saves', (
    tester,
  ) async {
    final store = ControlledReaderStore()..failNextWrite = true;
    final session = _Session(store: store);
    await _mount(tester, session);
    expect(session.players.single.isPlaying, true);
    session.players.single.emitPosition(const Duration(seconds: 44));
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);
    expect(store.entry?['position'], 44);
    expect(store.entry?['episodeId'], '1');
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
  // Stream cancellation can complete on the real event loop. Keep virtual
  // time bounded while a network/native gate or loading indicator is pending.
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
  final players = <ControlledNativePlayer>[];
  final requests = <String>[];

  _Session({ControlledReaderStore? store, this.loader, this.factory})
    : store = store ?? ControlledReaderStore();

  Widget app({int startIndex = 0}) => MaterialApp(
    home: PlayerPage(
      bookId: 'stability-book',
      title: '连续播放测试',
      description: '测试简介',
      eps: [
        for (var index = 1; index <= 5; index++)
          Chapter(itemId: '$index', title: '第 $index 集', volumeName: ''),
      ],
      startIndex: startIndex,
      historyStore: store,
      contentLoader: (chapter) {
        requests.add(chapter.itemId);
        return loader?.call(chapter) ?? Future.value(_source(chapter.itemId));
      },
      playerFactory: () {
        final player = factory?.call() ?? ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
