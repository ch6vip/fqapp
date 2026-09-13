import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';

import 'support/controlled_player.dart';

/// Regression coverage for build/review/fixes/B12.json.
///
///  * p09-audio-completed-flag-lost-on-tone-switch: a finished chapter stays
///    finished after switching voice and still replays from zero.
///  * p09-audio-sleep-timer-dismiss-cancels: dismissing the timer sheet must
///    not silently cancel an active timer.
void main() {
  testWidgets('a completed chapter survives a voice change and replays', (
    tester,
  ) async {
    final session = _Session(
      voices: () async => const [AudioVoice(id: '2', label: '温柔女声')],
    );
    await _mount(tester, session);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-auto-next')));
    await tester.tap(find.byKey(const ValueKey('audio-auto-next')));
    await _flush(tester);
    session.players.single.emitCompleted();
    await _flush(tester);
    expect(session.players, hasLength(1));
    expect(session.players.single.isPlaying, isFalse);
    expect(find.text('本章已播完'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('audio-voice')));
    await tester.tap(find.byKey(const ValueKey('audio-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('温柔女声'));
    await _flush(tester);
    await tester.pumpAndSettle();

    expect(session.players, hasLength(2));
    final replacement = session.players.last;
    expect(replacement.position, const Duration(minutes: 2));
    expect(replacement.isPlaying, isFalse);
    expect(find.text('本章已播完'), findsOneWidget);
    expect(session.store.entry?['completed'], isTrue);

    await tester.ensureVisible(find.byTooltip('播放'));
    await tester.tap(find.byTooltip('播放'));
    await _flush(tester);
    expect(replacement.position, Duration.zero);
    expect(replacement.isPlaying, isTrue);
  });

  testWidgets('dismissing the sleep-timer sheet keeps the active timer', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    final player = session.players.single;
    expect(player.isPlaying, isTrue);

    await tester.tap(find.byTooltip('定时'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 分钟后'));
    await tester.pumpAndSettle();

    // Reopen the sheet and dismiss it without picking an option.
    await tester.tap(find.byTooltip('定时'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // The timer must still fire; dismissal must not cancel it.
    await tester.pump(const Duration(minutes: 15, seconds: 1));
    await _flush(tester);
    expect(player.isPlaying, isFalse);
  });

  testWidgets('a slow decorations response never delays the first playback', (
    tester,
  ) async {
    final extras = Completer<AudioExtras>();
    final session = _Session(extras: (_) => extras.future);
    await _mount(tester, session);
    expect(extras.isCompleted, isFalse);
    expect(session.players, hasLength(1));
    expect(session.players.single.isPlaying, isTrue);
    expect(session.requests, ['1:0']);

    extras.complete(
      const AudioExtras(
        related: [RelatedWork(kind: 'book', id: 'r1', title: '伴生作品')],
      ),
    );
    await _flush(tester);
    expect(find.text('伴生作品'), findsOneWidget);
  });

  testWidgets('a saved tone that only the extras endpoint knows is restored', (
    tester,
  ) async {
    final store = ControlledReaderStore(
      entry: {
        'id': 'book',
        'kind': 'audio',
        'toneId': '96',
        'episode': 0,
        'position': 0,
        'time': 1,
      },
    );
    final session = _Session(
      store: store,
      voices: () async => const [AudioVoice(id: '1', label: '默认音色')],
      extras: (_) async => const AudioExtras(
        tones: AudioToneSet(
          ttsTones: [AudioTone(id: '96', title: '沉稳大叔音')],
        ),
      ),
    );
    await _mount(tester, session);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-voice')));
    await tester.tap(find.byKey(const ValueKey('audio-voice')));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('沉稳大叔音'),
      matching: find.byType(ListTile),
    );
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  testWidgets('a saved extras-only tone cannot block playback forever', (
    tester,
  ) async {
    final extras = Completer<AudioExtras>();
    final store = ControlledReaderStore(
      entry: {
        'id': 'book',
        'kind': 'audio',
        'toneId': '96',
        'episode': 0,
        'position': 0,
        'time': 1,
      },
    );
    final session = _Session(store: store, extras: (_) => extras.future);
    await _mount(tester, session);
    // The bounded wait keeps playback off until its window closes.
    expect(session.players, isEmpty);
    await tester.pump(const Duration(seconds: 4));
    await _flush(tester);
    expect(session.players, hasLength(1));
    expect(session.players.single.isPlaying, isTrue);
    expect(session.requests, ['1:0']);

    // A late decorations response must not pretend the missing tone played.
    extras.complete(
      const AudioExtras(
        tones: AudioToneSet(
          ttsTones: [AudioTone(id: '96', title: '沉稳大叔音')],
        ),
      ),
    );
    await _flush(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-voice')));
    await tester.tap(find.byKey(const ValueKey('audio-voice')));
    await tester.pumpAndSettle();
    final tile = find.ancestor(
      of: find.text('沉稳大叔音'),
      matching: find.byType(ListTile),
    );
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
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

class _Session {
  final ControlledReaderStore store;
  final Future<List<AudioVoice>> Function()? voices;
  final AudioExtrasLoader? extras;
  final List<Chapter> chapters;
  final players = <ControlledNativePlayer>[];
  final requests = <String>[];

  _Session({
    ControlledReaderStore? store,
    this.voices,
    this.extras,
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
        return Future.value(_source(id, toneId));
      },
      voicesLoader: voices ?? () async => const [],
      extrasLoader: extras,
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
