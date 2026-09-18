import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';

import 'support/controlled_player.dart';

const _audioBook = '7239243941252598845';
const _novelBook = '7180279419959774247';
const _audioChapter = '7250158428088454201';
const _novelChapter = '7181453438667096588';

// Sanitized /tones response for the reported book, captured 2026-09-16.
Map<String, dynamic> _payload() =>
    jsonDecode(File('test/fixtures/linked_audio_tones.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('retains the twelve voices and the exact associated novel', () {
    final tones = AudioToneSet.fromPayload(_payload());
    expect(tones.hasFixedTone, isTrue);
    expect(tones.ttsTones, hasLength(12));
    expect(tones.relatedNovel?.id, _novelBook);
    expect(tones.relatedNovel?.title, '全球冰封：我打造了末日安全屋');
    expect(tones.narratorTones.single.id, _audioBook);
  });

  test('recovers the rounded novel ID from exact ebook metadata', () {
    final payload = _payload();
    (payload['data'] as Map).remove('relate_novel_bookid_str');
    expect(AudioToneSet.fromPayload(payload).relatedNovel?.id, _novelBook);
  });

  test('does not guess a novel ID when the rounded bucket is ambiguous', () {
    final payload = _payload();
    final data = payload['data'] as Map;
    data.remove('relate_novel_bookid_str');
    (data['book_infos'] as List).add({
      'book_id': '7180279419959774248',
      'is_ebook': '1',
      'book_name': '另一部小说',
    });
    expect(AudioToneSet.fromPayload(payload).relatedNovel, isNull);
  });

  test('does not mistake a recording for an associated ebook', () {
    final payload = _payload();
    final data = payload['data'] as Map;
    data.remove('relate_novel_bookid_str');
    for (final book in data['book_infos'] as List) {
      (book as Map)['is_ebook'] = '0';
    }
    expect(AudioToneSet.fromPayload(payload).relatedNovel, isNull);
  });

  test('zero means no associated novel, even with ebook metadata', () {
    final payload = _payload();
    final data = payload['data'] as Map;
    data['relate_novel_bookid_str'] = '0';
    data['relate_novel_bookid'] = 0;
    expect(AudioToneSet.fromPayload(payload).relatedNovel, isNull);
  });

  testWidgets('the reported recording lists all twelve intelligent voices', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    await _showVoices(tester);
    expect(find.text('真人讲书'), findsWidgets);
    expect(find.text('智能朗读'), findsOneWidget);
    for (final tone in AudioToneSet.fromPayload(_payload()).ttsTones) {
      expect(find.byKey(ValueKey('voice_option_${tone.id}')), findsOneWidget);
    }
  });

  testWidgets('choosing TTS opens the novel chapter with the selected voice', (
    tester,
  ) async {
    final session = _Session();
    session.store.entries['audio:$_novelBook'] = {
      'id': 'audio:$_novelBook',
      'kind': 'audio',
      'chapterId': _novelChapter,
      'toneId': '64',
      'rate': 0.75,
      'position': 0,
    };
    await _mount(tester, session);
    session.players.single.emitPosition(const Duration(milliseconds: 37500));
    await _flush(tester);
    await tester.tap(find.byKey(const ValueKey('audio-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await _flush(tester);
    await _chooseVoice(tester, '115');

    expect(session.directories, [_novelBook]);
    expect(session.requests, ['$_audioChapter:0', '$_novelChapter:115']);
    expect(find.byType(AudioPage), findsOneWidget);
    expect(find.byKey(ValueKey('audio_session_$_novelBook')), findsOneWidget);
    expect(find.text('全球冰封：我打造了末日安全屋'), findsOneWidget);
    expect(find.text('听书'), findsOneWidget);
    expect(session.players.first.disposed, isTrue);
    expect(session.players.last.isPlaying, isTrue);
    expect(session.players.last.position, Duration.zero);
    expect(session.players.last.rate, 1.5);
    expect(session.store.entries['audio:$_audioBook']?['position'], 37.5);
    expect(
      session.store.entries['audio:$_audioBook']?['chapterId'],
      _audioChapter,
    );
  });

  testWidgets('a paused recording stays paused when changing to TTS', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    await tester.tap(find.byTooltip('暂停'));
    await _flush(tester);
    await _chooseVoice(tester, '96');
    expect(session.requests.last, '$_novelChapter:96');
    expect(session.players.last.isPlaying, isFalse);
  });

  testWidgets('a new version waits for the original native player release', (
    tester,
  ) async {
    final released = Completer<void>();
    final session = _Session(releaseGate: released);
    addTearDown(() {
      if (!released.isCompleted) released.complete();
    });
    await _mount(tester, session);
    await _showVoices(tester);
    await tester.tap(find.byKey(const ValueKey('voice_option_85')));
    await _flush(tester);
    expect(session.players, hasLength(1));
    expect(session.requests, ['$_audioChapter:0']);
    released.complete();
    await tester.pumpAndSettle();
    await _flush(tester);
    expect(session.players, hasLength(2));
    expect(session.requests.last, '$_novelChapter:85');
  });

  testWidgets('a failed novel directory leaves the recording playable', (
    tester,
  ) async {
    final session = _Session(
      directory: (_) async => throw const FormatException('unavailable'),
    );
    await _mount(tester, session);
    await _chooseVoice(tester, '96');
    expect(session.requests, ['$_audioChapter:0']);
    expect(session.players.single.disposed, isFalse);
    expect(session.players.single.isPlaying, isTrue);
    expect(find.text('暂时无法切换声音，请稍后重试'), findsOneWidget);
  });

  testWidgets(
    'choosing TTS keeps the voice sheet until the novel page is ready',
    (tester) async {
      final ready = Completer<List<Chapter>>();
      final session = _Session(directory: (_) => ready.future);
      await _mount(tester, session);
      await _showVoices(tester);
      await tester.tap(find.byKey(const ValueKey('voice_option_96')));
      await _flush(tester);
      expect(find.text('声音设置'), findsOneWidget);
      expect(find.text('冰河末世，我囤积了百亿物资'), findsWidgets);
      expect(session.players, hasLength(1));
      expect(session.players.single.disposed, isFalse);

      ready.complete([
        Chapter(itemId: 'preview', title: '序章', volumeName: ''),
        Chapter(itemId: _novelChapter, title: '第1章 末世之后，我重生了', volumeName: ''),
      ]);
      await tester.pumpAndSettle();
      await _flush(tester);
      expect(find.text('声音设置'), findsNothing);
      expect(find.byType(AudioPage), findsOneWidget);
      expect(find.byKey(ValueKey('audio_session_$_novelBook')), findsOneWidget);
      expect(find.text('全球冰封：我打造了末日安全屋'), findsOneWidget);
      expect(find.text('听书'), findsOneWidget);
    },
  );
}

Future<void> _showVoices(WidgetTester tester) async {
  final picker = find.byKey(const ValueKey('audio-voice'));
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
}

Future<void> _chooseVoice(WidgetTester tester, String toneId) async {
  await _showVoices(tester);
  final choice = find.byKey(ValueKey('voice_option_$toneId'));
  await tester.ensureVisible(choice);
  await tester.tap(choice);
  await tester.pumpAndSettle();
  await _flush(tester);
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
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
  _Session({this.directory, this.releaseGate});

  final Future<List<Chapter>> Function(String)? directory;
  final Completer<void>? releaseGate;
  final store = _Store();
  final players = <ControlledNativePlayer>[];
  final directories = <String>[];
  final requests = <String>[];

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: _audioBook,
      title: '冰河末世，我囤积了百亿物资',
      chapters: [
        Chapter(itemId: _audioChapter, title: '001 末世之后，我重生了', volumeName: ''),
      ],
      historyStore: store,
      voicesLoader: () async => const [],
      extrasLoader: (bookId) async {
        final payload = _payload();
        if (bookId == _novelBook) {
          (payload['data'] as Map)['req_book_genre_type'] = 0;
        }
        return AudioExtras(tones: AudioToneSet.fromPayload(payload));
      },
      directoryLoader: (bookId) {
        directories.add(bookId);
        return directory?.call(bookId) ??
            Future.value([
              Chapter(itemId: 'preview', title: '序章', volumeName: ''),
              Chapter(
                itemId: _novelChapter,
                title: '第1章 末世之后，我重生了',
                volumeName: '',
              ),
            ]);
      },
      sourceLoader: (itemId, {toneId}) async {
        requests.add('$itemId:$toneId');
        return AudioSource(
          itemId: itemId,
          url: 'https://example.invalid/$itemId-$toneId.mp3',
          toneId: toneId ?? '0',
        );
      },
      playerFactory: () {
        final player = ControlledNativePlayer(
          releaseGate: players.isEmpty ? releaseGate : null,
        );
        players.add(player);
        return player;
      },
    ),
  );
}

class _Store extends ControlledReaderStore {
  final entries = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async => entries[id];

  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    await super.addHistory(value);
    entries[value['id'] as String] = Map<String, dynamic>.from(value);
  }
}
