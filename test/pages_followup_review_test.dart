import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/search_history_store.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
  });

  testWidgets('new draft rejects a response before the next debounce fires', (
    tester,
  ) async {
    final first = Completer<List<SearchSuggestion>>();
    final calls = <String>[];
    await _mountSearch(tester, (query) {
      calls.add(query);
      return query == '修仙'
          ? first.future
          : Future.value(const [SearchSuggestion(text: '都市新建议')]);
    });
    await tester.enterText(find.byType(TextField), '修仙');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(find.byType(TextField), '都市');
    first.complete(const [SearchSuggestion(text: '修仙旧建议')]);
    await tester.pump();
    expect(calls, ['修仙']);
    expect(find.text('修仙旧建议'), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('都市新建议'), findsOneWidget);
  });

  testWidgets(
    'editing the draft immediately clears already displayed suggestions',
    (tester) async {
      await _mountSearch(
        tester,
        (_) async => const [SearchSuggestion(text: '修仙旧建议')],
      );
      await tester.enterText(find.byType(TextField), '修仙');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('修仙旧建议'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '都市');
      await tester.pump();
      expect(find.text('修仙旧建议'), findsNothing);
    },
  );

  testWidgets('executing a query cancels its pending suggestion request', (
    tester,
  ) async {
    final calls = <String>[];
    await _mountSearch(tester, (query) async {
      calls.add(query);
      return const [];
    });
    await tester.enterText(find.byType(TextField), '修仙');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, isEmpty);
  });

  testWidgets(
    'a late pause failure cannot clear another page listening state',
    (tester) async {
      final first = _DelayedPausePlayer();
      final second = ControlledNativePlayer();
      var created = 0;
      await _mountAudio(tester, () => created++ == 0 ? first : second);
      final pause = first.nextPause = Completer<void>();
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '暂停',
            ),
          )
          .onPressed!();
      await tester.pump();
      expect(first.nextPause, isNull);
      await _mountAudio(tester, () => second, bookId: 'other');
      const bookId = 'other';
      const chapterId = '1';
      expect(
        ListeningSession.instance.matches(bookId, chapterId),
        isTrue,
        reason:
            'before old failure: $created creations, '
            '${second.isPlaying}, ${second.calls}, old=${first.calls}, '
            '${ListeningSession.instance.bookId}/'
            '${ListeningSession.instance.chapterId}/'
            '${ListeningSession.instance.playing}',
      );
      pause.completeError(StateError('late platform pause failure'));
      await _flush(tester);
      expect(ListeningSession.instance.matches(bookId, chapterId), isTrue);
      expect(second.isPlaying, isTrue);
    },
  );
  testWidgets('reader directory stays above the keyboard while searching', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'directory',
          title: '目录测试',
          chapters: [
            for (var i = 0; i < 30; i++)
              Chapter(itemId: '$i', title: '第 $i 章', volumeName: ''),
          ],
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (_) async => '用于核查软键盘遮挡的正文。',
        ),
      ),
    );
    await _flush(tester);
    await tester.tap(find.byKey(const ValueKey('reader-page-surface')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(ListView),
    );
    expect(list, findsOneWidget);
    expect(tester.getRect(list).bottom, lessThanOrEqualTo(500));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mountSearch(
  WidgetTester tester,
  SearchSuggestLoader suggest,
) async {
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: SearchPage(
        historyStore: _MemorySearchHistory(),
        searchLoader: (_, {required tabType, required offset}) async => [],
        suggestLoader: suggest,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _mountAudio(
  WidgetTester tester,
  ControlledNativePlayer Function() player, {
  String bookId = 'book',
}) async {
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: AudioPage(
        key: ValueKey(bookId),
        bookId: bookId,
        title: '有声书',
        chapters: [
          Chapter(itemId: '1', title: '第一章', volumeName: ''),
          Chapter(itemId: '2', title: '第二章', volumeName: ''),
        ],
        historyStore: ControlledReaderStore(),
        playerFactory: player,
        voicesLoader: () async => const [AudioVoice(id: '0', label: '默认音色')],
        sourceLoader: (itemId, {toneId}) async => AudioSource(
          itemId: itemId,
          url: 'https://cdn.example/$itemId.m4a',
          toneId: toneId ?? '0',
        ),
      ),
    ),
  );
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _DelayedPausePlayer extends ControlledNativePlayer {
  Completer<void>? nextPause;

  @override
  Future<void> pause() async {
    final gate = nextPause;
    nextPause = null;
    await gate?.future;
    await super.pause();
  }
}

class _MemorySearchHistory implements SearchHistoryRepository {
  @override
  Future<List<String>> load() async => [];

  @override
  Future<List<String>> add(String query) async => [query];

  @override
  Future<List<String>> remove(String query) async => [];

  @override
  Future<void> clear() async {}
}
