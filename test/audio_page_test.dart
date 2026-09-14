import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';

import 'support/controlled_player.dart';

void main() {
  testWidgets(
    'plays a plain URL and exposes pause, seek, and 15 second controls',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final player = session.players.single;
      expect(player.isPlaying, true);
      expect(player.keys, ['']);
      expect(find.byType(Texture), findsNothing);
      player.emitPosition(const Duration(seconds: 25));
      await tester.pump();
      await tester.tap(find.byTooltip('后退15秒'));
      await _flush(tester);
      expect(player.position, const Duration(seconds: 10));
      await tester.tap(find.byTooltip('后退15秒'));
      await _flush(tester);
      expect(player.position, Duration.zero);
      await tester.tap(find.byTooltip('前进15秒'));
      await _flush(tester);
      expect(player.position, const Duration(seconds: 15));
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('audio-seek')),
      );
      slider.onChanged!(37500);
      slider.onChangeEnd!(37500);
      await _flush(tester);
      expect(player.position, const Duration(milliseconds: 37500));
      expect(session.store.entry?['position'], 37.5);
      await tester.tap(find.byTooltip('暂停'));
      await _flush(tester);
      expect(player.isPlaying, false);
      expect(session.store.entry?['kind'], 'audio');
      expect(session.store.entry?['id'], 'audio:book');
      await tester.tap(find.byTooltip('播放'));
      await _flush(tester);
      expect(player.isPlaying, true);
    },
  );

  for (final scenario
      in <({String name, Map<String, dynamic> saved, int position})>[
        (
          name: 'stable chapter ID after reorder',
          saved: {
            'kind': 'audio',
            'chapterId': '1',
            'episode': 2,
            'position': 37.5,
          },
          position: 37500,
        ),
        (
          name: 'a different selected chapter',
          saved: {
            'kind': 'audio',
            'chapterId': '2',
            'episode': 0,
            'position': 37.5,
          },
          position: 0,
        ),
        (
          name: 'novel scroll progress',
          saved: {
            'kind': 'book',
            'chapterId': '1',
            'episode': 0,
            'position': 1000,
          },
          position: 0,
        ),
        (
          name: 'an untyped old record',
          saved: {'chapterId': '1', 'episode': 0, 'position': 37.5},
          position: 0,
        ),
        (
          name: 'a negative position',
          saved: {'kind': 'audio', 'episode': 0, 'position': -40},
          position: 0,
        ),
        (
          name: 'a nonfinite position',
          saved: {'kind': 'audio', 'episode': 0, 'position': double.nan},
          position: 0,
        ),
        (
          name: 'an overflowing position',
          saved: {'kind': 'audio', 'episode': 0, 'position': 1e308},
          position: 0,
        ),
      ]) {
    testWidgets('resume handles ${scenario.name}', (tester) async {
      final session = _Session(
        store: ControlledReaderStore(entry: {'id': 'book', ...scenario.saved}),
      );
      await _mount(tester, session);
      expect(session.players.single.position.inMilliseconds, scenario.position);
      expect(session.players.single.isPlaying, true);
      expect(find.byKey(const ValueKey('audio-retry')), findsNothing);
    });
  }

  testWidgets(
    'unknown duration does not erase the remembered listening position',
    (tester) async {
      final session = _Session(
        store: ControlledReaderStore(
          entry: {
            'id': 'book',
            'kind': 'audio',
            'chapterId': '1',
            'position': 37.5,
            'duration': 120,
          },
        ),
        factory: () => _AudioPlayer()..totalDuration = Duration.zero,
      );
      await _mount(tester, session);
      expect(session.players.single.position.inMilliseconds, 37500);
      expect(session.store.entry?['position'], 37.5);
      expect(
        tester.widget<Slider>(find.byKey(const ValueKey('audio-seek'))).max,
        120000,
      );
    },
  );

  testWidgets(
    'directory search selects the chapter and saves the departed one',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 22));
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '3');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('audio-chapter-2')));
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(session.players, hasLength(2));
      expect(session.players.first.disposed, true);
      expect(session.players.last.isPlaying, true);
      expect(session.store.entry?['chapterId'], '3');
      expect(session.store.entry?['position'], 0);
      expect(
        session.store.writes
            .where((entry) => entry['chapterId'] == '1')
            .last['position'],
        22,
      );
    },
  );

  testWidgets('automatically advances once and stops at the final chapter', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    session.players.first.emitCompleted();
    await _flush(tester);
    expect(session.players, hasLength(2));
    expect(session.store.entry?['chapterId'], '2');
    expect(session.players.last.isPlaying, true);
    session.players.last.emitCompleted();
    await _flush(tester);
    expect(session.players, hasLength(3));
    session.players.last.emitCompleted();
    await _flush(tester);
    expect(session.players, hasLength(3));
    expect(session.players.last.isPlaying, false);
    expect(session.store.entry?['completed'], true);
    expect(session.store.entry?['position'], 120);
    expect(find.text('本章已播完'), findsOneWidget);
    await tester.tap(find.byTooltip('播放'));
    await _flush(tester);
    expect(session.players.last.position, Duration.zero);
    expect(session.players.last.isPlaying, true);
  });

  testWidgets(
    'disabling automatic next persists and leaves the completed chapter paused',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      // The official page keeps 自动下一章 in the overflow sheet.
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('audio-auto-next')));
      await tester.tap(find.byKey(const ValueKey('audio-auto-next')));
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byKey(const ValueKey('audio-auto-next'))),
      ).pop();
      await tester.pumpAndSettle();
      await _flush(tester);
      session.players.single.emitCompleted();
      await _flush(tester);
      expect(session.players, hasLength(1));
      expect(session.players.single.isPlaying, false);
      expect(session.store.entry?['autoAdvance'], false);
      expect(session.store.entry?['completed'], true);
    },
  );

  testWidgets(
    'completed history stays paused and replays only when requested',
    (tester) async {
      final session = _Session(
        store: ControlledReaderStore(
          entry: {
            'id': 'book',
            'kind': 'audio',
            'chapterId': '1',
            'position': 120,
            'duration': 120,
            'completed': true,
          },
        ),
      );
      await _mount(tester, session);
      expect(session.players.single.isPlaying, false);
      expect(session.players.single.position, const Duration(seconds: 120));
      await tester.tap(find.byTooltip('播放'));
      await _flush(tester);
      expect(session.players.single.position, Duration.zero);
      expect(session.players.single.isPlaying, true);
    },
  );

  testWidgets(
    'restores voice and speed and preserves a paused position on voice change',
    (tester) async {
      final session = _Session(
        store: ControlledReaderStore(
          entry: {
            'id': 'book',
            'kind': 'audio',
            'chapterId': '1',
            'position': 45,
            'toneId': '2',
            'rate': 1.5,
          },
        ),
        voices: () async => const [AudioVoice(id: '2', label: '温柔女声')],
      );
      await _mount(tester, session);
      expect(session.requests.single, '1:2');
      expect(session.players.single.rate, 1.5);
      await tester.tap(find.byTooltip('暂停'));
      await _flush(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('audio-voice')));
      await tester.tap(find.byKey(const ValueKey('audio-voice')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('默认音色'));
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(session.requests, ['1:2', '1:0']);
      expect(session.players.first.disposed, true);
      expect(session.players.last.position, const Duration(seconds: 45));
      expect(session.players.last.isPlaying, false);
      expect(session.players.last.rate, 1.5);
      // An unplayed replacement voice must not replace a playable saved one.
      expect(session.store.entry?['toneId'], '2');
      expect(session.store.entry?['position'], 45);
      await tester.ensureVisible(find.byTooltip('播放'));
      await tester.tap(find.byTooltip('播放'));
      await _flush(tester);
      expect(session.store.entry?['toneId'], '0');
    },
  );

  testWidgets(
    'voice discovery failure uses the default voice and keeps playback available',
    (tester) async {
      final session = _Session(
        store: ControlledReaderStore(
          entry: {'id': 'book', 'kind': 'audio', 'toneId': '99'},
        ),
        voices: () async => throw StateError('voice service unavailable'),
      );
      await _mount(tester, session);
      expect(session.requests.single, '1:0');
      expect(session.players.single.isPlaying, true);
      expect(find.byKey(const ValueKey('audio-voice')), findsOneWidget);
    },
  );

  testWidgets('a chosen speed is applied to later chapters and saved', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-speed')));
    await tester.tap(find.byKey(const ValueKey('audio-speed')));
    await tester.pumpAndSettle();
    final speed = find.text('1.5×');
    await tester.ensureVisible(speed);
    await tester.tap(speed);
    await _flush(tester);
    await tester.pumpAndSettle();
    expect(session.players.single.rate, 1.5);
    expect(session.store.entry?['rate'], 1.5);
    await tester.ensureVisible(find.byTooltip('下一章'));
    await tester.tap(find.byTooltip('下一章'));
    await _flush(tester);
    expect(session.players.last.rate, 1.5);
  });

  testWidgets(
    'only the newest chapter plays when earlier requests finish late',
    (tester) async {
      final second = Completer<AudioSource>();
      final third = Completer<AudioSource>();
      final session = _Session(
        loader: (id, {toneId}) => switch (id) {
          '2' => second.future,
          '3' => third.future,
          _ => Future.value(_source(id, toneId)),
        },
      );
      await _mount(tester, session);
      await tester.tap(find.byTooltip('下一章'));
      await _flush(tester);
      await tester.tap(find.byTooltip('下一章'));
      await _flush(tester);
      expect(session.requests, ['1:0', '2:0', '3:0']);
      third.complete(_source('3', '0'));
      await _flush(tester);
      second.completeError(StateError('stale failed request'));
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(
        session.players.last.calls.first,
        'create:https://example.invalid/3-0.mp3',
      );
      expect(session.store.entry?['chapterId'], '3');
      expect(session.players.last.isPlaying, true);
      expect(find.byKey(const ValueKey('audio-retry')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the next player waits for native release of the previous player',
    (tester) async {
      final release = Completer<void>();
      var created = 0;
      final session = _Session(
        factory: () =>
            _AudioPlayer(releaseGate: created++ == 0 ? release : null),
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await _mount(tester, session);
      await tester.tap(find.byTooltip('下一章'));
      await _flush(tester);
      expect(session.requests, ['1:0', '2:0']);
      expect(session.players, hasLength(1));
      release.complete();
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(session.players.last.isPlaying, true);
    },
  );

  for (final lifecycle in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    testWidgets('$lifecycle pauses immediately and saves before the timer', (
      tester,
    ) async {
      final session = _Session();
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 37));
      tester.binding.handleAppLifecycleStateChanged(lifecycle);
      await _flush(tester);
      expect(session.players.single.isPlaying, false);
      expect(session.store.entry?['position'], 37);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(session.players.single.isPlaying, false);
    });
  }

  testWidgets(
    'a source finishing in the background waits for an explicit play',
    (tester) async {
      final source = Completer<AudioSource>();
      final session = _Session(loader: (id, {toneId}) => source.future);
      await _mount(tester, session);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      source.complete(_source('1', '0'));
      await _flush(tester);
      expect(session.players.single.isPlaying, false);
      expect(session.players.single.calls, isNot(contains('play')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(session.players.single.isPlaying, false);
      await tester.tap(find.byTooltip('播放'));
      await _flush(tester);
      expect(session.players.single.isPlaying, true);
    },
  );

  testWidgets('a late play acknowledgement cannot resume background playback', (
    tester,
  ) async {
    final play = Completer<void>();
    final session = _Session(factory: () => _AudioPlayer(playGate: play));
    await _mount(tester, session);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    play.complete();
    await _flush(tester);
    expect(session.players.single.isPlaying, false);
    expect(session.players.single.playbackRequested, false);
  });

  testWidgets('backgrounding during a replay seek cancels the pending play', (
    tester,
  ) async {
    final session = _Session(
      store: ControlledReaderStore(
        entry: {
          'id': 'book',
          'kind': 'audio',
          'chapterId': '1',
          'position': 120,
          'completed': true,
        },
      ),
    );
    await _mount(tester, session);
    final seek = session.players.single.seekGate = Completer<void>();
    await tester.tap(find.byTooltip('播放'));
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    seek.complete();
    await _flush(tester);
    expect(session.players.single.position, Duration.zero);
    expect(session.players.single.isPlaying, false);
    expect(session.players.single.calls, isNot(contains('play')));
  });

  testWidgets(
    'a chapter opened during a speed change uses the latest selection',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final rate = session.players.single.rateGate = Completer<void>();
      await tester.ensureVisible(find.byKey(const ValueKey('audio-speed')));
      await tester.tap(find.byKey(const ValueKey('audio-speed')));
      await tester.pumpAndSettle();
      final speed = find.text('1.5×');
      await tester.ensureVisible(speed);
      await tester.tap(speed);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('下一章'));
      await tester.tap(find.byTooltip('下一章'));
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(session.players.last.rate, 1.5);
      rate.complete();
      await _flush(tester);
      expect(session.players.last.rate, 1.5);
      expect(session.store.entry?['rate'], 1.5);
    },
  );

  testWidgets(
    'leaving while a source loads does not allocate a late native player',
    (tester) async {
      final source = Completer<AudioSource>();
      final session = _Session(loader: (id, {toneId}) => source.future);
      await _mount(tester, session);
      await _unmount(tester);
      source.complete(_source('1', '0'));
      await _flush(tester);
      expect(session.players, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving during native creation disposes the pending player', (
    tester,
  ) async {
    final create = Completer<void>();
    final session = _Session(factory: () => _AudioPlayer(createGate: create));
    await _mount(tester, session);
    expect(session.players, hasLength(1));
    await _unmount(tester);
    create.complete();
    await _flush(tester);
    expect(session.players.single.disposed, true);
    expect(session.players.single.calls, isNot(contains('play')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'immediate reentry waits for the exit write before restoring progress',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 73));
      final write = session.store.writeGate = Completer<void>();
      addTearDown(() {
        if (!write.isCompleted) write.complete();
      });
      await _unmount(tester);
      await tester.pumpWidget(session.app());
      await _flush(tester);
      expect(session.players, hasLength(1));
      write.complete();
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(session.players.last.position, const Duration(seconds: 73));
      expect(session.players.last.isPlaying, true);
    },
  );

  testWidgets(
    'player errors hide signed URLs and retry restores the saved position',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      session.players.single.emitPosition(const Duration(seconds: 44));
      session.players.single.errors.add(
        StateError('https://example.invalid/private.mp3?token=secret'),
      );
      await _flush(tester);
      expect(session.players.single.disposed, true);
      expect(find.textContaining('token=secret'), findsNothing);
      expect(find.byKey(const ValueKey('audio-retry')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('audio-retry')));
      await tester.tap(find.byKey(const ValueKey('audio-retry')));
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(session.players.last.position, const Duration(seconds: 44));
      expect(session.players.last.isPlaying, true);
      expect(session.requests, ['1:0', '1:0']);
    },
  );

  for (final failure in ['error', 'exit', 'background']) {
    testWidgets(
      'initial buffering followed by $failure retains the played chapter',
      (tester) async {
        var created = 0;
        final session = _Session(
          factory: () =>
              created++ == 0 ? _AudioPlayer() : _BufferingAudioPlayer(),
          loader: (id, {toneId}) async => AudioSource(
            itemId: id,
            url: 'https://example.invalid/$id.mp3',
            toneId: toneId ?? '0',
            // Known metadata must not be mistaken for Media3 readiness.
            duration: const Duration(seconds: 120),
          ),
        );
        await _mount(tester, session);
        session.players.first.emitPosition(const Duration(seconds: 73));
        await tester.tap(find.byTooltip('下一章'));
        await _flush(tester);
        expect(session.players.last.isCreated, true);
        expect(session.players.last.isPlaying, false);
        expect(
          tester.widget<Slider>(find.byKey(const ValueKey('audio-seek'))).max,
          120000,
        );
        await tester.pump(const Duration(seconds: 6));
        expect(session.store.entry?['chapterId'], '1');
        expect(session.store.entry?['position'], 73);
        switch (failure) {
          case 'error':
            session.players.last.errors.add(
              StateError('CDN responded HTTP 403 after prepare'),
            );
          case 'exit':
            await _unmount(tester);
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
        }
        await _flush(tester);
        expect(session.store.entry?['chapterId'], '1');
        expect(session.store.entry?['position'], 73);
        expect(
          session.store.writes.where((entry) => entry['chapterId'] == '2'),
          isEmpty,
        );
      },
    );
  }

  testWidgets(
    'the first playing event commits a chapter and later buffering preserves progress',
    (tester) async {
      var created = 0;
      final session = _Session(
        factory: () =>
            created++ == 0 ? _AudioPlayer() : _BufferingAudioPlayer(),
      );
      await _mount(tester, session);
      session.players.first.emitPosition(const Duration(seconds: 73));
      await tester.tap(find.byTooltip('下一章'));
      await _flush(tester);
      final next = session.players.last as _BufferingAudioPlayer;
      expect(session.store.entry?['chapterId'], '1');
      next.emitPosition(const Duration(seconds: 5));
      next.beginPlayback();
      await _flush(tester);
      expect(session.store.entry?['chapterId'], '2');
      expect(session.store.entry?['position'], 5);
      next.emitPosition(const Duration(seconds: 37));
      next.emitBuffering(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      expect(session.store.entry?['chapterId'], '2');
      expect(session.store.entry?['position'], 37);
    },
  );

  testWidgets(
    'a mismatched chapter source is rejected before native playback',
    (tester) async {
      final session = _Session(
        loader: (id, {toneId}) async => _source('different', toneId),
      );
      await _mount(tester, session);
      expect(session.players, isEmpty);
      expect(find.byKey(const ValueKey('audio-retry')), findsOneWidget);
    },
  );

  testWidgets('an empty directory shows an empty state without a player', (
    tester,
  ) async {
    final session = _Session(chapters: const []);
    await _mount(tester, session);
    expect(find.text('暂无可播放章节'), findsOneWidget);
    expect(session.players, isEmpty);
    expect(session.requests, isEmpty);
  });

  testWidgets('the 章评 action opens the review sheet', (tester) async {
    // The official page labels this 章评; the sheet behind it shows the work's
    // reviews because the backend exposes no chapter-comment list here.
    final session = _Session();
    await _mount(tester, session);
    expect(find.byKey(const ValueKey('audio_chapter_comment')), findsOneWidget);
    expect(find.text('章评'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('audio_chapter_comment')));
    await tester.pumpAndSettle();
    // Without an injected comment loader the sheet states the outage rather
    // than reaching for the network.
    expect(find.text('暂时无法加载书评'), findsOneWidget);
  });

  testWidgets('the shelf action toggles and persists its state', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    expect(find.text('加入书架'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('audio_shelf')));
    await _flush(tester);
    expect(find.text('已在书架'), findsOneWidget);
    expect(session.store.entry?['inShelf'], true);
    await tester.tap(find.byKey(const ValueKey('audio_shelf')));
    await _flush(tester);
    expect(find.text('加入书架'), findsOneWidget);
    expect(session.store.entry?['inShelf'], false);
  });

  testWidgets('the sleep timer pauses playback when it elapses', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    final player = session.players.single;
    expect(player.isPlaying, true);
    await tester.tap(find.byTooltip('定时'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 分钟后'));
    await tester.pumpAndSettle();
    // The countdown is a real Timer, so drive it explicitly.
    await tester.pump(const Duration(minutes: 15, seconds: 1));
    await _flush(tester);
    expect(player.isPlaying, false);
    expect(session.store.entry?['position'], isNotNull);
  });
}

AudioSource _source(String id, String? toneId) => AudioSource(
  itemId: id,
  url: 'https://example.invalid/$id-${toneId ?? '0'}.mp3',
  toneId: toneId ?? '0',
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester);
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await _unmount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

class _AudioPlayer extends ControlledNativePlayer {
  final keys = <String>[];

  _AudioPlayer({super.createGate, super.releaseGate, super.playGate});

  @override
  Future<int> create(String cdnUrl, String keyHex) {
    keys.add(keyHex);
    return super.create(cdnUrl, keyHex);
  }
}

class _BufferingAudioPlayer extends _AudioPlayer {
  _BufferingAudioPlayer() {
    totalDuration = Duration.zero;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playbackRequested = true;
    playWhenReadyEvents.add(true);
    emitBuffering(true);
  }

  void beginPlayback() {
    emitBuffering(false);
    isPlaying = true;
    playingEvents.add(true);
  }
}

class _Session {
  final ControlledReaderStore store;
  final Future<AudioSource> Function(String, {String? toneId})? loader;
  final Future<List<AudioVoice>> Function()? voices;
  final _AudioPlayer Function()? factory;
  final List<Chapter> chapters;
  final players = <_AudioPlayer>[];
  final requests = <String>[];

  _Session({
    ControlledReaderStore? store,
    this.loader,
    this.voices,
    this.factory,
    List<Chapter>? chapters,
  }) : store = store ?? ControlledReaderStore(),
       chapters =
           chapters ??
           [
             for (var index = 1; index <= 3; index++)
               Chapter(itemId: '$index', title: '第$index章', volumeName: '第一卷'),
           ];

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: 'book',
      title: '测试听书',
      chapters: chapters,
      historyStore: store,
      sourceLoader: (id, {toneId}) {
        requests.add('$id:$toneId');
        return loader?.call(id, toneId: toneId) ??
            Future.value(_source(id, toneId));
      },
      voicesLoader: voices ?? () async => const [],
      playerFactory: () {
        final player = factory?.call() ?? _AudioPlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
