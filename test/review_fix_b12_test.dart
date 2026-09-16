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
      voices: () async => const [
        AudioVoice(id: '2', label: '温柔女声'),
        AudioVoice(id: '0', label: '默认音色'),
      ],
    );
    await _mount(tester, session);
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

    final tile = find.byKey(const ValueKey('voice_option_96'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  testWidgets("a 真人讲书 row opens that narrator's own audio book", (
    tester,
  ) async {
    // A narrator row carries an abook_id, i.e. another book: playinfo rejects
    // it when used as a tone_id, so the row loads that book's directory
    // instead of asking for another voice.
    final opened = <String>[];
    final session = _Session(
      extras: (_) async => const AudioExtras(
        tones: AudioToneSet(
          narratorTones: [AudioTone(id: '7239243941252598845', title: '主播：测试')],
        ),
      ),
      directory: (bookId) async {
        opened.add(bookId);
        return [
          Chapter(itemId: 'ab-1', title: '001 第一章', volumeName: ''),
        ];
      },
    );
    await _mount(tester, session);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-voice')));
    await tester.tap(find.byKey(const ValueKey('audio-voice')));
    await tester.pumpAndSettle();
    expect(find.text('主播：测试'), findsOneWidget);

    await tester.tap(find.text('主播：测试'));
    await tester.pumpAndSettle();
    expect(opened, ['7239243941252598845']);
    expect(
      session.requests.where((r) => r.endsWith(':7239243941252598845')),
      isEmpty,
    );
    // The page title stays the same when a narrator version is opened.
    expect(find.text('听书'), findsOneWidget);
  });

  testWidgets('a narrator version numbered only by episode stays aligned', (
    tester,
  ) async {
    // 《麻衣风水师》的「闲人阿七」版本把章节命名成 `麻衣风水师01`（没有章节标题），
    // 且前面多一条 `麻衣风水师00片花`：标题主干对不上，按位置兜底会落到片花上，
    // 必须退回按序号对齐。
    final session = _Session(
      chapters: [
        Chapter(itemId: 'n1', title: '第1章 八鬼抬轿', volumeName: ''),
        Chapter(itemId: 'n2', title: '第2章 仙女下凡', volumeName: ''),
        Chapter(itemId: 'n3', title: '第3章 当面悔婚', volumeName: ''),
      ],
      extras: (_) async => const AudioExtras(
        tones: AudioToneSet(
          narratorTones: [
            AudioTone(id: '7521688131263794201', title: '主播：闲人阿七'),
          ],
        ),
      ),
      directory: (bookId) async => [
        Chapter(itemId: 'ab-teaser', title: '麻衣风水师00片花', volumeName: ''),
        Chapter(itemId: 'ab-1', title: '麻衣风水师01', volumeName: ''),
        Chapter(itemId: 'ab-2', title: '麻衣风水师02', volumeName: ''),
        Chapter(itemId: 'ab-3', title: '麻衣风水师03', volumeName: ''),
      ],
    );
    await _mount(tester, session);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-voice')));
    await tester.tap(find.byKey(const ValueKey('audio-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主播：闲人阿七'));
    await _flush(tester);
    await tester.pumpAndSettle();

    expect(session.requests.any((r) => r.startsWith('ab-1:')), isTrue);
    expect(session.requests.any((r) => r.startsWith('ab-teaser:')), isFalse);
    expect(session.requests.any((r) => r.startsWith('ab-2:')), isFalse);
  });

  testWidgets('voices that share an upstream name stay distinguishable', (
    tester,
  ) async {
    final session = _Session(
      extras: (_) async => const AudioExtras(
        tones: AudioToneSet(
          ttsTones: [
            AudioTone(id: '10', title: '智能朗读', description: '自然流畅'),
            AudioTone(id: '11', title: '智能朗读', description: '声临其境'),
          ],
        ),
      ),
    );
    await _mount(tester, session);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-voice')));
    await tester.tap(find.byKey(const ValueKey('audio-voice')));
    await tester.pumpAndSettle();

    // The panel mirrors the upstream list: both cards keep the same title and
    // are distinguished by their descriptions, as the official panel does.
    expect(find.text('自然流畅'), findsAtLeastNWidgets(1));
    expect(find.text('声临其境'), findsAtLeastNWidgets(1));
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
    final tile = find.byKey(const ValueKey('voice_option_96'));
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
  final Future<List<Chapter>> Function(String bookId)? directory;
  final List<Chapter> chapters;
  final players = <ControlledNativePlayer>[];
  final requests = <String>[];

  _Session({
    ControlledReaderStore? store,
    this.voices,
    this.extras,
    this.directory,
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
      directoryLoader: directory,
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
