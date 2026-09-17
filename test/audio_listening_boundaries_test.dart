import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/listening_session.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
  });

  for (final autoAdvance in [false, true]) {
    testWidgets(
      'completion leaves the listening session paused with autoAdvance=$autoAdvance',
      (tester) async {
        final player = _NativeEndingPlayer();
        await _mount(
          tester,
          player: player,
          startIndex: autoAdvance ? 1 : 0,
          autoAdvance: autoAdvance,
        );
        expect(ListeningSession.instance.playing, isTrue);
        player.endPlayback();
        await _flush(tester);
        expect(player.isPlaying, isFalse);
        expect(ListeningSession.instance.playing, isFalse);
        expect(find.text('本章已播完'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'automatic next does not publish playback while its source waits',
    (tester) async {
      final player = _NativeEndingPlayer();
      final next = Completer<AudioSource>();
      addTearDown(() {
        if (!next.isCompleted) next.complete(_source('2'));
      });
      await _mount(tester, player: player, nextSource: next.future);
      expect(
        ListeningSession.instance.matches('boundary-book', '1'),
        isTrue,
        reason:
            '${player.calls}; '
            '${ListeningSession.instance.bookId}/'
            '${ListeningSession.instance.chapterId}/'
            '${ListeningSession.instance.playing}',
      );
      player.endPlayback();
      await _flush(tester);
      expect(player.disposed, isTrue);
      expect(ListeningSession.instance.playing, isFalse);
      next.complete(_source('2'));
      await _flush(tester);
      expect(ListeningSession.instance.matches('boundary-book', '2'), isTrue);
    },
  );
}

Future<void> _mount(
  WidgetTester tester, {
  required ControlledNativePlayer player,
  int startIndex = 0,
  bool autoAdvance = true,
  Future<AudioSource>? nextSource,
}) async {
  var created = 0;
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: AudioPage(
        bookId: 'boundary-book',
        title: '播放边界',
        chapters: [
          Chapter(itemId: '1', title: '第一章', volumeName: ''),
          Chapter(itemId: '2', title: '第二章', volumeName: ''),
        ],
        startIndex: startIndex,
        historyStore: ControlledReaderStore(
          entry: {
            'id': 'boundary-book',
            'kind': 'audio',
            'chapterId': '${startIndex + 1}',
            'autoAdvance': autoAdvance,
          },
        ),
        playerFactory: () => created++ == 0 ? player : ControlledNativePlayer(),
        voicesLoader: () async => const [AudioVoice(id: '0', label: '默认音色')],
        sourceLoader: (itemId, {toneId}) => itemId == '2' && nextSource != null
            ? nextSource
            : Future.value(_source(itemId)),
      ),
    ),
  );
  await _flush(tester);
}

AudioSource _source(String itemId) => AudioSource(
  itemId: itemId,
  url: 'https://cdn.example/$itemId.m4a',
  toneId: '0',
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

class _NativeEndingPlayer extends ControlledNativePlayer {
  void endPlayback() {
    // Media3 can report isPlaying=false before STATE_ENDED. Its subsequent
    // pause acknowledgement does not produce another onIsPlayingChanged.
    isPlaying = false;
    playingEvents.add(false);
    emitCompleted();
  }

  @override
  Future<void> pause() async {
    if (disposed) return;
    calls.add('pause');
    playbackRequested = false;
    playWhenReadyEvents.add(false);
    if (isPlaying) {
      isPlaying = false;
      playingEvents.add(false);
    }
  }
}
