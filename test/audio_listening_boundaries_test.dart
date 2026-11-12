import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/widgets/audio/audio_control_rows.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
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
        // autoAdvance=true 时从末章起播：官方 `v7` 对末章给的是书末提示，
        // 其余情况才是「本章已播完」。
        expect(
          find.text(autoAdvance ? '已播完最新章节，去听听其它内容吧' : '本章已播完'),
          findsOneWidget,
        );
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
      // 连播倒计时窗口内仍是本章：会话不发布、播放器也还没释放。
      expect(ListeningSession.instance.playing, isFalse);
      await tester.pump(const Duration(seconds: 3));
      await _flush(tester);
      expect(player.disposed, isTrue);
      expect(ListeningSession.instance.playing, isFalse);
      next.complete(_source('2'));
      await _flush(tester);
      expect(ListeningSession.instance.matches('boundary-book', '2'), isTrue);
    },
  );

  testWidgets('stopping near the end does not synthesize completion', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    await _mount(tester, player: player);
    player.emitDuration(const Duration(seconds: 554));
    player.emitPosition(const Duration(seconds: 553));
    player.isPlaying = false;
    player.playingEvents.add(false);
    await _flush(tester);
    await tester.pump(const Duration(seconds: 5));
    await _flush(tester);
    expect(player.disposed, isFalse);
    expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    expect(find.text('播放出错，请稍后重试'), findsNothing);
    expect(ListeningSession.instance.chapterId, '1');
    expect(ListeningSession.instance.playing, isFalse);
    expect(ListeningSession.instance.completed, isFalse);
  });

  for (final completed in [false, true]) {
    testWidgets(
      'native error at chapter end stays visible (completed=$completed)',
      (tester) async {
        final player = _NativeEndingPlayer();
        final requests = <String>[];
        await _mount(tester, player: player, sourceRequests: requests);
        player.emitDuration(const Duration(seconds: 554));
        player.emitPosition(const Duration(seconds: 553));
        if (completed) player.endPlayback();
        await _flush(tester);
        player.errors.add(
          const NativePlaybackException('Playback failed', errorCode: 2001),
        );
        await _flush(tester);
        expect(find.text('播放出错，请稍后重试'), findsOneWidget);
        expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
        await tester.pump(const Duration(seconds: 5));
        await _flush(tester);
        expect(find.text('播放出错，请稍后重试'), findsOneWidget);
        expect(ListeningSession.instance.playing, isFalse);
        expect(player.disposed, isTrue);
        expect(requests, ['1']);
      },
    );
  }

  for (final action in ['pause', 'noisy', 'replay']) {
    testWidgets('$action cancels a pending chapter advance', (tester) async {
      final player = _NativeEndingPlayer();
      await _mount(tester, player: player);
      player.endPlayback();
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsOneWidget);
      switch (action) {
        case 'pause':
          await PlatformChannels.notify(
            'fqapp/native_player',
            'onNotificationAction',
            'pause',
          );
        case 'noisy':
          await PlatformChannels.notify(
            'fqapp/native_player',
            'onAudioBecomingNoisy',
          );
        case 'replay':
          await tester.tap(find.byTooltip('播放'));
      }
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(player.disposed, isFalse);
      expect(player.isPlaying, action == 'replay');
      expect(ListeningSession.instance.bookId, 'boundary-book');
      expect(ListeningSession.instance.chapterId, '1');
      expect(ListeningSession.instance.playing, action == 'replay');
    });
  }

  for (final action in ['seek', 'back15', 'forward15']) {
    testWidgets('$action cancels a pending chapter advance', (tester) async {
      final player = _NativeEndingPlayer();
      final requests = <String>[];
      await _mount(tester, player: player, sourceRequests: requests);
      player.emitDuration(const Duration(minutes: 1));
      player.endPlayback();
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsOneWidget);
      final row = tester.widget<AudioTimeSeekRow>(
        find.byType(AudioTimeSeekRow),
      );
      switch (action) {
        case 'seek':
          row.onChangeEnd!(30000);
        case 'back15':
          row.onBack15!();
        case 'forward15':
          row.onForward15!();
      }
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(player.disposed, isFalse);
      expect(requests, ['1']);
      expect(ListeningSession.instance.chapterId, '1');
    });
  }

  testWidgets('seek preview cancels chapter advance before release', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    final requests = <String>[];
    await _mount(tester, player: player, sourceRequests: requests);
    player.emitDuration(const Duration(minutes: 1));
    player.endPlayback();
    await _flush(tester);
    final row = tester.widget<AudioTimeSeekRow>(find.byType(AudioTimeSeekRow));
    row.onChanged!(30000);
    await _flush(tester);
    expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await _flush(tester);
    row.onChangeEnd!(30000);
    await _flush(tester);
    expect(player.disposed, isFalse);
    expect(requests, ['1']);
    expect(ListeningSession.instance.chapterId, '1');
  });

  for (final background in [false, true]) {
    testWidgets('chapter countdown respects background playback=$background', (
      tester,
    ) async {
      await AudioPreferences.instance.setBackgroundPlayback(background);
      final player = _NativeEndingPlayer();
      final requests = <String>[];
      await _mount(tester, player: player, sourceRequests: requests);
      player.endPlayback();
      await _flush(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(requests, background ? ['1', '2'] : ['1']);
      expect(ListeningSession.instance.chapterId, background ? '2' : '1');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    });
  }

  testWidgets('Linux lock and suspend preserve the pending playback resume', (
    tester,
  ) async {
    final session = DesktopSystemSession.instance;
    addTearDown(() {
      session.accept({'type': 'locked', 'value': false});
      session.accept({'type': 'suspend', 'value': false});
    });
    final player = _NativeEndingPlayer();
    final requests = <String>[];
    await _mount(
      tester,
      player: player,
      sourceRequests: requests,
      surfaceSize: const Size(1000, 800),
    );
    await AudioPreferences.instance.setBackgroundPlayback(false);
    expect(player.isPlaying, isTrue);
    session.accept({'type': 'locked', 'value': true});
    await _flush(tester);
    expect(player.isPlaying, isFalse);
    session.accept({'type': 'suspend', 'value': true});
    await _flush(tester);
    expect(player.isPlaying, isFalse);
    session.accept({'type': 'suspend', 'value': false});
    await _flush(tester);
    expect(player.isPlaying, isFalse);
    session.accept({'type': 'locked', 'value': false});
    await _flush(tester);
    expect(player.isPlaying, isTrue);
    expect(player.disposed, isFalse);
    expect(requests, ['1']);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('closing during chapter countdown cancels its timer', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    await _mount(tester, player: player);
    player.endPlayback();
    await _flush(tester);
    expect(find.byKey(const Key('audio_advance_banner')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    expect(player.disposed, isTrue);
  });

  testWidgets('next source failure stays on the failed next chapter', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    final next = Completer<AudioSource>();
    final requests = <String>[];
    await _mount(
      tester,
      player: player,
      nextSource: next.future,
      sourceRequests: requests,
    );
    player.endPlayback();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 3));
    await _flush(tester);
    next.completeError(StateError('next chapter source unavailable'));
    await _flush(tester);
    expect(find.text('播放出错，请稍后重试'), findsOneWidget);
    expect(player.disposed, isTrue);
    await tester.pump(const Duration(seconds: 5));
    await _flush(tester);
    expect(find.text('播放出错，请稍后重试'), findsOneWidget);
    expect(ListeningSession.instance.playing, isFalse);
    expect(requests, ['1', '2']);
  });

  for (final choice in ['听完本章', '15 分钟后']) {
    testWidgets('$choice prevents automatic next at the sleep boundary', (
      tester,
    ) async {
      final player = _NativeEndingPlayer();
      await _mount(tester, player: player);
      await tester.tap(find.byKey(const Key('audio_sleep')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      if (choice == '15 分钟后') {
        await tester.pump(const Duration(minutes: 14, seconds: 59));
      }
      player.endPlayback();
      await _flush(tester);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(player.disposed, isFalse);
      expect(player.isPlaying, isFalse);
      expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
      expect(ListeningSession.instance.bookId, 'boundary-book');
      expect(ListeningSession.instance.chapterId, '1');
      expect(ListeningSession.instance.playing, isFalse);
    });
  }
}

Future<void> _mount(
  WidgetTester tester, {
  required ControlledNativePlayer player,
  int startIndex = 0,
  bool autoAdvance = true,
  Future<AudioSource>? nextSource,
  List<String>? sourceRequests,
  Size surfaceSize = const Size(430, 932),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  var created = 0;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
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
        sourceLoader: (itemId, {toneId}) {
          sourceRequests?.add(itemId);
          return itemId == '2' && nextSource != null
              ? nextSource
              : Future.value(_source(itemId));
        },
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
