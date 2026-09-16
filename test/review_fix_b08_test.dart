import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

/// 1x1 transparent PNG, so illustration pages decode without touching the
/// network in widget tests.
const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==';

const _ttsChannel = MethodChannel('flutter_tts');

Widget _app({
  required String text,
  String title = '测试书籍',
  String chapterTitle = '第一章',
  int chapterCount = 2,
  ChapterTextLoader? loader,
  ChapterIdeasLoader? ideasLoader,
  ParagraphCommentResolver? commentResolver,
}) => MaterialApp(
  home: ReaderPage(
    bookId: 'reader-test',
    title: title,
    chapters: [
      for (var i = 0; i < chapterCount; i++)
        Chapter(
          itemId: 'c${i + 1}',
          title: i == 0 ? chapterTitle : '第 ${i + 1} 章',
          volumeName: '正文',
        ),
    ],
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: loader ?? (chapter) async => text,
    ideasLoader: ideasLoader,
    commentResolver: commentResolver,
    imageProviderFactory: (image) => MemoryImage(base64Decode(_pixelPng)),
  ),
);

String _longText() => List.generate(
  40,
  (index) => '第 $index 段。这是一段用于验证阅读器朗读生命周期的测试正文。',
).join('\n\n');

Future<void> _openControls(WidgetTester tester) async {
  // Tap the page margin rather than its center: an illustration page claims
  // center taps for its fullscreen viewer, while the margin still reaches the
  // reader's controls gesture handler.
  final rect = tester.getRect(
    find.byKey(const ValueKey('reader-page-surface')),
  );
  await tester.tapAt(Offset(rect.center.dx, rect.bottom - 4));
  await tester.pumpAndSettle();
}

Future<void> _startTts(WidgetTester tester) async {
  await _openControls(tester);
  await tester.tap(find.byKey(const ValueKey('reader-tts-read')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
  });

  tearDown(() {
    ListeningSession.instance.clear();
  });

  testWidgets('disposing during TTS startup never sets state after dispose', (
    tester,
  ) async {
    final languageGate = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _ttsChannel,
      (call) async =>
          call.method == 'setLanguage' ? await languageGate.future : 1,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _ttsChannel,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(text: _longText()));
    await tester.pumpAndSettle();

    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-tts-read')));
    await tester.pump();
    // setLanguage is gated, so the startup is parked mid-await.
    expect(languageGate.isCompleted, isFalse);

    // Leave the reader while the platform futures are still pending.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    languageGate.complete(1);
    await tester.pumpAndSettle();

    // The stale startup must bail out instead of calling setState/speak.
    expect(tester.takeException(), isNull);
  });

  testWidgets('volume-key turns stop an active TTS narration', (tester) async {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_volume_key_turn': true,
    });
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _ttsChannel,
      (call) async {
        calls.add(call.method);
        return 1;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _ttsChannel,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(text: _longText()));
    await tester.pumpAndSettle();
    await _startTts(tester);
    expect(calls, contains('speak'));

    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pumpAndSettle();

    // The manual turn must tear TTS down through the same path as a tap.
    expect(calls, contains('stop'));
  });

  testWidgets('listening follow cannot yank pages while TTS narrates', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _ttsChannel,
      (call) async => 1,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _ttsChannel,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(text: _longText()));
    await tester.pumpAndSettle();
    await _startTts(tester);

    final before = tester
        .widget<ReaderPagedView>(find.byType(ReaderPagedView))
        .pageIndex;
    ListeningSession.instance.update(
      bookId: 'reader-test',
      chapterId: 'c1',
      chapterTitle: '第一章',
      position: const Duration(seconds: 540),
      duration: const Duration(seconds: 600),
      playing: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final after = tester
        .widget<ReaderPagedView>(find.byType(ReaderPagedView))
        .pageIndex;
    expect(after, before);
  });

  testWidgets('chapter-end entry opens the ideas end bucket', (tester) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requested = <int>[];
    await tester.pumpWidget(
      _app(
        text: '第一段。\n\n第二段。',
        ideasLoader: (itemId) async => ChapterIdeas.fromPayload(const {
          'code': 0,
          'data': {
            'data': {
              '1': {'count': 5},
              '2': {'count': 100},
              '10000': {'count': 20},
            },
          },
        }),
        commentResolver: (itemId, paragraph, cursor) async {
          requested.add(paragraph.paraIndex);
          return const BookCommentPage();
        },
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('reader-scroll-chapter-comments'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    // The 章末 entry must open the greatest paragraph key (the end bucket),
    // not the bucket with the most comments.
    expect(requested, [10000]);
  });

  testWidgets('TTS skips the illustration placeholder on an image page', (
    tester,
  ) async {
    final spoken = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _ttsChannel,
      (call) async {
        if (call.method == 'speak') {
          final arguments = call.arguments;
          spoken.add(arguments is Map ? '${arguments['text']}' : '$arguments');
        }
        return 1;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _ttsChannel,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final content = ChapterContent(
      blocks: [
        const ChapterImage(
          url: 'https://images.test/tall',
          width: 700,
          height: 2100,
        ),
        const ChapterParagraph('图后的正文。'),
      ],
    );
    await tester.pumpWidget(
      _app(
        text: content.toCacheText(),
        title: '',
        chapterTitle: '',
        chapterCount: 1,
      ),
    );
    await tester.pumpAndSettle();

    // The tall illustration occupies the first page on its own.
    final pages = tester
        .widget<ReaderPagedView>(find.byType(ReaderPagedView))
        .layout
        .pages;
    expect(pages.first.fragments.every((f) => f.block.isImage), isTrue);

    await _startTts(tester);

    expect(spoken, isNotEmpty);
    expect(spoken.any((text) => text.contains('\uFFFC')), isFalse);
    expect(spoken.any((text) => text.contains('图后的正文')), isTrue);
  });
}
