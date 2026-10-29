import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/narration_sentence.dart';
import 'package:fqapp/services/system_tts.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _methods = MethodChannel('fqapp/system_tts');
const _eventMethods = MethodChannel('fqapp/system_tts_events');
const _playerMethods = MethodChannel('fqapp/native_player');
const _codec = StandardMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Completer<int>? initialization;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    calls = [];
    initialization = null;
    messenger.setMockMethodCallHandler(_eventMethods, (_) async => null);
    messenger.setMockMethodCallHandler(_playerMethods, (_) async => null);
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return initialization?.future ?? 4000;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_eventMethods, null);
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_playerMethods, null);
  });

  List<MethodCall> spoken() => calls.where((c) => c.method == 'speak').toList();
  Future<void> event(Map<String, Object?> data) =>
      messenger.handlePlatformMessage(
        _eventMethods.name,
        _codec.encodeSuccessEnvelope(data),
        (_) {},
      );

  SystemTtsPlayback session({
    String text = '正文。',
    Future<String> Function(Chapter)? loader,
    TextReplacementStore? replacements,
  }) => SystemTtsPlayback(
    SystemTtsBook(
      bookId: 'local:book',
      title: '本地书',
      chapters: [
        Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
        Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
      ],
      startIndex: 0,
      localOnly: true,
      initialContent: ChapterContent.fromPlainText(text),
      textLoader: loader,
      replacementStore: replacements,
    ),
    beforePlay: () async {},
    onStop: () {},
  );

  testWidgets(
    'saving rules closes a running system session and clears highlight',
    (tester) async {
      final replacements = TextReplacementStore();
      await replacements.load();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final playback = session(replacements: replacements);
      playback.start();
      await tester.pump();
      expect(spoken(), isNotEmpty);
      await replacements.save(
        enabled: true,
        rules: [
          const TextReplacementRule(id: 'r', pattern: '正文', replacement: '新正文'),
        ],
      );
      await tester.pump();
      expect(playback.closed, isTrue);
      expect(ListeningSession.instance.sentenceRange, isNull);
      await playback.close();
      await tester.pump();
    },
  );

  testWidgets('rules changed before queued TTS start prevent stale speech', (
    tester,
  ) async {
    final replacements = TextReplacementStore();
    await replacements.load();
    final playback = session(replacements: replacements);
    await replacements.save(
      enabled: true,
      rules: [
        const TextReplacementRule(id: 'r', pattern: '正文', replacement: '新正文'),
      ],
    );
    playback.start();
    await tester.pump();
    expect(spoken(), isEmpty);
    expect(playback.closed, isTrue);
    await playback.close();
    await tester.pump();
  });

  testWidgets('pause invalidates a pending engine initialization', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    initialization = Completer<int>();
    final playback = session();
    try {
      playback.start();
      await tester.pump();
      expect(calls.any((c) => c.method == 'initialize'), isTrue);
      await playback.pause();
      initialization!.complete(4000);
      await tester.pump();
      expect(spoken(), isEmpty);
      expect(playback.wantPlay, isFalse);
    } finally {
      if (!initialization!.isCompleted) initialization!.complete(4000);
      await playback.close();
      await tester.pump();
    }
  });

  testWidgets(
    'closing during next local chapter load rejects its late result',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final chapter = Completer<String>();
      final requested = <String>[];
      final playback = session(
        loader: (c) {
          requested.add(c.itemId);
          return chapter.future;
        },
      );
      try {
        playback.start();
        await tester.pump();
        final id = (spoken().single.arguments as Map)['id'];
        await event({'type': 'done', 'id': id});
        await tester.pump();
        expect(requested, ['c2']);
        await playback.close();
        chapter.complete('迟到的第二章');
        await tester.pump();
        expect(spoken(), hasLength(1));
        expect(ListeningSession.instance.bookId, isNull);
      } finally {
        if (!chapter.isCompleted) chapter.complete('第二章');
        await playback.close();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'resume uses the reported range and ignores an old done callback',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final playback = session(text: '甲乙丙丁。');
      try {
        playback.start();
        await tester.pump();
        final oldId = (spoken().single.arguments as Map)['id'];
        await event({'type': 'range', 'id': oldId, 'start': 2});
        await playback.pause();
        await playback.resume();
        expect((spoken().last.arguments as Map)['text'], '丙丁。');
        await event({'type': 'done', 'id': oldId});
        await tester.pump();
        expect(playback.index, 0);
        expect(spoken(), hasLength(2));
        expect(ListeningSession.instance.duration, Duration.zero);
        expect(ListeningSession.instance.textProgress, closeTo(0.4, 0.001));
      } finally {
        await playback.close();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'chunk boundaries preserve an astral character and chapter text',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final text = '${List.filled(299, '甲').join()}😀乙';
      final playback = session(text: text);
      try {
      playback.start();
      await tester.pump();
      // The next sentence is queued straight away, so the first utterance is
      // the one at the head of the list.
      final first = spoken().first.arguments as Map;
      expect((first['text'] as String).length, 299);
      await event({'type': 'done', 'id': first['id']});
      await tester.pump();
      final second = spoken().last.arguments as Map;
      expect(second['text'], '😀乙');
      expect('${first['text']}${second['text']}', text);
      } finally {
        await playback.close();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'background disabled and engine interruptions cancel pending play',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final playback = session();
      try {
        playback.start();
        await tester.pump();
        await AudioPreferences.instance.setBackgroundPlayback(false);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(playback.wantPlay, isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await playback.resume();
        await event({'type': 'interrupted', 'id': null});
        await tester.pump();
        expect(playback.wantPlay, isFalse);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await playback.close();
        await tester.pump();
      }
    },
  );

  testWidgets('a temporary focus loss resumes once the focus comes back', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final playback = session(text: '第一句。第二句。第三句。');
    try {
      playback.start();
      await tester.pump();
      final before = spoken().length;
      expect(before, greaterThan(0));
      // 来电：焦点被临时抢走，只能停朗读，不能交还焦点——交还了就再没有
      // GAIN，挂断后永远停在暂停态。
      await event({'type': 'interrupted', 'id': null});
      await tester.pump();
      expect(playback.wantPlay, isFalse);
      await event({'type': 'focus_resume'});
      await tester.pump();
      expect(playback.wantPlay, isTrue);
      expect(spoken().length, greaterThan(before));
    } finally {
      await playback.close();
      await tester.pump();
    }
  });

  testWidgets('a focus gain does not undo a pause pressed inside the call', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final playback = session(text: '第一句。第二句。');
    try {
      playback.start();
      await tester.pump();
      await event({'type': 'interrupted', 'id': null});
      await tester.pump();
      // 用户在通话里主动按停：挂断不该替他开播。
      await playback.pause();
      await tester.pump();
      await event({'type': 'focus_resume'});
      await tester.pump();
      expect(playback.wantPlay, isFalse);
    } finally {
      await playback.close();
      await tester.pump();
    }
  });

  testWidgets('a focus gain in the background waits for the app', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await AudioPreferences.instance.setBackgroundPlayback(false);
    final playback = session(text: '第一句。第二句。');
    try {
      playback.start();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await event({'type': 'interrupted', 'id': null});
      await tester.pump();
      // 挂断那一下人还在通话界面：此刻不许出声，回到前台再补。
      await event({'type': 'focus_resume'});
      await tester.pump();
      expect(playback.wantPlay, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(playback.wantPlay, isTrue);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await AudioPreferences.instance.setBackgroundPlayback(true);
      await playback.close();
      await tester.pump();
    }
  });

  test(
    'local books without a loader fail instead of falling back to an API',
    () async {
      final playback = session();
      await expectLater(playback.book.load(1), throwsStateError);
      playback.dispose();
    },
  );

  group('sentenceRangeAt', () {
    test('narrows to the sentence under the offset', () {
      const text = '第一句。第二句！第三句？';
      expect(
        sentenceRangeAt(text, 5, lower: 0, upper: text.length),
        (start: 4, end: 8),
      );
    });

    test('closing marks stay with the sentence they end', () {
      const text = '他说：「走。」然后就走了。';
      // Offsets: 0他 1说 2： 3「 4走 5。 6」 7然 …
      expect(
        sentenceRangeAt(text, 8, lower: 0, upper: text.length),
        (start: 7, end: 13),
      );
    });

    test('a paragraph break also ends a sentence', () {
      const text = '第一段\n第二段';
      expect(
        sentenceRangeAt(text, 5, lower: 0, upper: text.length),
        (start: 4, end: 7),
      );
    });

    test('the result never leaves the piece being spoken', () {
      const text = '第一句。第二句。第三句。';
      // Piece [4, 8) is exactly '第二句。'.
      expect(sentenceRangeAt(text, 99, lower: 4, upper: 8), (start: 4, end: 8));
    });

    test('an empty range yields nothing', () {
      expect(sentenceRangeAt('abc', 0, lower: 0, upper: 0), isNull);
    });
  });

  group('nextSentenceRange', () {
    test('walks a chapter one sentence at a time', () {
      const text = '第一句。第二句！还有第三句？';
      var cursor = 0;
      final slices = <String>[];
      for (
        var range = nextSentenceRange(text, cursor, maxLength: 300);
        range != null;
        range = nextSentenceRange(text, cursor, maxLength: 300)
      ) {
        slices.add(text.substring(range.start, range.end));
        cursor = range.end;
      }
      expect(slices, ['第一句。', '第二句！', '还有第三句？']);
    });

    test('a paragraph break closes the utterance and is skipped after it', () {
      const text = '第一段\n\n第二段';
      final first = nextSentenceRange(text, 0, maxLength: 300)!;
      expect(text.substring(first.start, first.end), '第一段\n');
      final second = nextSentenceRange(text, first.end, maxLength: 300)!;
      expect(text.substring(second.start, second.end), '第二段');
    });

    test('a sentence past the engine limit is cut and continued', () {
      final text = '${'甲' * 10}。乙';
      final first = nextSentenceRange(text, 0, maxLength: 4)!;
      expect(first, (start: 0, end: 4));
      expect(text.substring(first.start, first.end), '甲甲甲甲');
    });

    test('nothing left to read yields no utterance', () {
      expect(nextSentenceRange('甲。\n ', 2, maxLength: 300), isNull);
    });
  });

  testWidgets('one utterance per sentence drives the highlight', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final playback = session(text: '第一句。第二句。第三句。');
    try {
      playback.start();
      await tester.pump();
      // A sentence per utterance is what lets a voice without `onRangeStart`
      // wash one sentence: the engine can only report the slice it was given.
      expect(
        spoken().map((c) => (c.arguments as Map)['text']),
        ['第一句。', '第二句。'],
      );
      expect((spoken().first.arguments as Map)['queue'], isFalse);
      expect((spoken().last.arguments as Map)['queue'], isTrue);
      final first = spoken().first.arguments as Map;
      final second = spoken().last.arguments as Map;
      await event({'type': 'start', 'id': first['id']});
      await tester.pump();
      expect(ListeningSession.instance.sentenceRange, (start: 0, end: 4));
      // The second sentence is already in the engine's queue while the first
      // plays; its callbacks must not move the reader.
      await event({'type': 'range', 'id': second['id'], 'start': 0});
      await tester.pump();
      expect(ListeningSession.instance.sentenceRange, (start: 0, end: 4));
      // `done` alone advances: engines without `onRangeStart` never fire more
      // than this, and the next sentence is already playing when it lands.
      await event({'type': 'done', 'id': first['id']});
      await tester.pump();
      expect(ListeningSession.instance.sentenceRange, (start: 4, end: 8));
      expect(spoken().map((c) => (c.arguments as Map)['text']), [
        '第一句。',
        '第二句。',
        '第三句。',
      ]);
    } finally {
      await playback.close();
      await tester.pump();
    }
  });
}
