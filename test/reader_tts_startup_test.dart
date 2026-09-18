import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

const _ttsChannel = MethodChannel('flutter_tts');
const _bookId = 'tts-startup-book';
const _chapterId = 'tts-startup-chapter';

Widget _app() => MaterialApp(
  home: ReaderPage(
    bookId: _bookId,
    title: '朗读初始化测试',
    chapters: [Chapter(itemId: _chapterId, title: '第一章', volumeName: '正文')],
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: (_) async => List.generate(
      60,
      (index) => '第 $index 段。这是一段用于检查语音初始化和手动操作边界的正文。',
    ).join('\n\n'),
    ideasLoader: (_) async => ChapterIdeas.empty,
  ),
);

Future<void> _startReading(WidgetTester tester) async {
  final surface = tester.getRect(
    find.byKey(const ValueKey('reader-page-surface')),
  );
  await tester.tapAt(Offset(surface.center.dx, surface.bottom - 4));
  await tester.pumpAndSettle();
  await _openSettings(tester);
  await tester.tap(find.byKey(const ValueKey('reader-tts-read')));
  await tester.pump();
}

int _pageIndex(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_volume_key_turn': true,
      'reader_listening_follow': true,
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    ListeningSession.instance.clear();
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_ttsChannel, null);
    ListeningSession.instance.clear();
  });

  testWidgets('an unavailable Chinese voice reports failure without speaking', (
    tester,
  ) async {
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_ttsChannel, (
      call,
    ) async {
      calls.add(call.method);
      // flutter_tts on Android reports an unavailable language as 0, not as
      // a PlatformException (FlutterTtsPlugin.setLanguage).
      return call.method == 'setLanguage' ? 0 : 1;
    });
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _startReading(tester);
    await tester.pumpAndSettle();

    expect(calls, isNot(contains('speak')));
    expect(find.text('当前设备没有可用的中文语音引擎'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('listening follow is suspended while TTS is starting', (
    tester,
  ) async {
    final language = Completer<Object?>();
    addTearDown(() {
      if (!language.isCompleted) language.complete(1);
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _ttsChannel,
      (call) async => call.method == 'setLanguage' ? await language.future : 1,
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final before = _pageIndex(tester);
    await _startReading(tester);
    expect(language.isCompleted, isFalse);

    ListeningSession.instance.update(
      bookId: _bookId,
      chapterId: _chapterId,
      chapterTitle: '第一章',
      position: const Duration(seconds: 9),
      duration: const Duration(seconds: 10),
      playing: true,
    );
    await tester.pumpAndSettle();
    expect(_pageIndex(tester), before);

    language.complete(1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('a covered reader leaves volume keys to the foreground route', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final before = _pageIndex(tester);
    final readerContext = tester.element(find.byType(ReaderPage));
    unawaited(
      showDialog<void>(
        context: readerContext,
        builder: (_) => const AlertDialog(content: Text('前台内容')),
      ),
    );
    await tester.pumpAndSettle();

    final handled = await tester.sendKeyEvent(
      LogicalKeyboardKey.audioVolumeDown,
    );
    await tester.pumpAndSettle();
    expect(handled, isFalse);
    expect(_pageIndex(tester), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final pendingMethod in [
    'setLanguage',
    'setSpeechRate',
    'awaitSpeakCompletion',
  ]) {
    testWidgets('a tap cancels TTS while $pendingMethod is pending', (
      tester,
    ) async {
      final pending = Completer<Object?>();
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_ttsChannel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == pendingMethod ? await pending.future : 1;
      });
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      final before = _pageIndex(tester);
      await _startReading(tester);
      await tester.pumpAndSettle();
      expect(calls, contains(pendingMethod));

      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-page-surface')),
      );
      await tester.tapAt(Offset(surface.right - 4, surface.center.dy));
      await tester.pumpAndSettle();
      expect(_pageIndex(tester), before);
      pending.complete(1);
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('speak')));
      if (pendingMethod == 'setLanguage') {
        expect(calls, isNot(contains('setSpeechRate')));
      }
      if (pendingMethod != 'awaitSpeakCompletion') {
        expect(calls, isNot(contains('awaitSpeakCompletion')));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'an unavailable voice can be retried after the engine becomes ready',
    (tester) async {
      var languageAttempts = 0;
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_ttsChannel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'setLanguage') {
          return ++languageAttempts == 1 ? 0 : 1;
        }
        return 1;
      });
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _startReading(tester);
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('speak')));
      await _startReading(tester);
      await tester.pumpAndSettle();
      expect(languageAttempts, 2);
      expect(calls.where((method) => method == 'speak'), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

/// Expands the 设置 section of the reading menu. The section keeps its state
/// across chapter changes, so this is a no-op while it is already open.
Future<void> _openSettings(WidgetTester tester) async {
  if (find.byTooltip('上一章').evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const ValueKey('reader-settings')));
  await tester.pumpAndSettle();
}
