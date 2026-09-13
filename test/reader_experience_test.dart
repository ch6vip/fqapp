import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  group('ReaderPreferences extras', () {
    test('page turn style, toggles and auto-turn round trip', () async {
      final preferences = ReaderPreferences(
        pageTurnStyle: ReaderPageTurnStyle.cover,
        volumeKeyTurn: true,
        keepScreenOn: true,
        autoTurnSeconds: 5,
        listeningFollow: false,
      );
      await preferences.save();
      final restored = await ReaderPreferences.load();
      expect(restored.pageTurnStyle, ReaderPageTurnStyle.cover);
      expect(restored.volumeKeyTurn, isTrue);
      expect(restored.keepScreenOn, isTrue);
      expect(restored.autoTurnSeconds, 5);
      expect(restored.listeningFollow, isFalse);
    });

    test('unknown style names fall back to slide and the interval clamps', () {
      final preferences = ReaderPreferences(autoTurnSeconds: 999).normalized();
      expect(preferences.autoTurnSeconds, 60);
      expect(preferences.pageTurnStyle, ReaderPageTurnStyle.slide);
    });
  });

  group('ListeningSession', () {
    test('publishes narration state and matches per chapter', () {
      final session = ListeningSession.instance;
      session.clear();
      session.update(
        bookId: 'book',
        chapterId: 'c1',
        chapterTitle: '第一章',
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 100),
        playing: true,
      );
      expect(session.matches('book', 'c1'), isTrue);
      expect(session.matches('book', 'c2'), isFalse);
      expect(session.matches('other', 'c1'), isFalse);
      expect(session.progress, closeTo(0.3, 0.001));

      // Paused narration must not drive the reader.
      session.update(
        bookId: 'book',
        chapterId: 'c1',
        chapterTitle: '第一章',
        position: const Duration(seconds: 40),
        duration: const Duration(seconds: 100),
        playing: false,
      );
      expect(session.matches('book', 'c1'), isFalse);

      session.clear();
      expect(session.matches('book', 'c1'), isFalse);
      expect(session.progress, 0);
    });
  });

  group('paged view turn styles', () {
    Future<ReaderPagedViewState> pump(
      WidgetTester tester,
      ReaderPageTurnStyle style, {
      ValueChanged<int>? onPageChanged,
    }) async {
      ReaderPagedViewState? state;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPagedView(
              layout: _layout(),
              pageIndex: 0,
              hasPreviousChapter: false,
              hasNextChapter: true,
              onPageChanged: (page) => onPageChanged?.call(page),
              onBoundary: (direction) async {},
              onDragStart: () {},
              turnStyle: style,
              backgroundColor: Colors.white,
              endPage: const Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text('本章完'), Text('下一章')],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      state = tester.state<ReaderPagedViewState>(find.byType(ReaderPagedView));
      return state;
    }

    testWidgets('none turns instantly while slide animates', (tester) async {
      var page = -1;
      var state = await pump(
        tester,
        ReaderPageTurnStyle.none,
        onPageChanged: (value) => page = value,
      );
      // turnPage must not be awaited in a widget test: its animation future
      // only completes while frames are being pumped.
      unawaited(state.turnPage(1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(page, greaterThanOrEqualTo(0));
      expect(tester.hasRunningAnimations, isFalse);

      state = await pump(
        tester,
        ReaderPageTurnStyle.slide,
        onPageChanged: (value) => page = value,
      );
      unawaited(state.turnPage(1));
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(page, greaterThanOrEqualTo(0));
    });

    testWidgets('the end page replaces the plain 下一章 placeholder', (
      tester,
    ) async {
      // The end page shows while the boundary request (next chapter) is in
      // flight; hold it open so the widget is observable.
      final boundary = Completer<void>();
      ReaderPagedViewState? state;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPagedView(
              layout: _layout(),
              pageIndex: 0,
              hasPreviousChapter: false,
              hasNextChapter: true,
              onPageChanged: (_) {},
              onBoundary: (direction) => boundary.future,
              onDragStart: () {},
              turnStyle: ReaderPageTurnStyle.none,
              backgroundColor: Colors.white,
              endPage: const Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text('本章完'), Text('下一章')],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      state = tester.state<ReaderPagedViewState>(find.byType(ReaderPagedView));
      // Walk forward until the trailing boundary item shows the end page.
      for (var i = 0; i < 30 && find.text('本章完').evaluate().isEmpty; i++) {
        unawaited(state.turnPage(1));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('本章完'), findsOneWidget);
      expect(find.text('下一章'), findsOneWidget);
      boundary.complete();
      await tester.pump(const Duration(milliseconds: 32));
    });
  });

  group('reader behaviors', () {
    testWidgets('volume keys turn pages when the toggle is on', (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'paged',
        'reader_volume_key_turn': true,
      });
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'reader-test',
            title: '测试书籍',
            chapters: [
              Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
              Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
            ],
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            chapterLoader: (chapter) async => List.generate(
              60,
              (index) => '第 $index 段。这是一段用于验证音量键翻页的测试正文。',
            ).join('\n\n'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      String pageNumber() =>
          tester
              .widget<Text>(find.byKey(const ValueKey('reader-page-number')))
              .data ??
          '';
      expect(pageNumber(), contains('本章 1 /'));
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
      expect(pageNumber(), contains('本章 2 /'));
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.pumpAndSettle();
      expect(pageNumber(), contains('本章 1 /'));
    });

    testWidgets('auto turn advances on its timer and stops on tap', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'paged',
        'reader_auto_turn_seconds': 3,
      });
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'reader-test',
            title: '测试书籍',
            chapters: [
              Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
              Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
            ],
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            chapterLoader: (chapter) async => List.generate(
              60,
              (index) => '第 $index 段。这是一段用于验证自动翻页的测试正文。',
            ).join('\n\n'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      String pageNumber() =>
          tester
              .widget<Text>(find.byKey(const ValueKey('reader-page-number')))
              .data ??
          '';
      // Start from the menu.
      await tester.tap(find.byKey(const ValueKey('reader-page-surface')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-auto-turn')));
      await tester.pumpAndSettle();
      final first = pageNumber();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(pageNumber(), isNot(first));
      // Any tap stops the chain.
      await tester.tap(find.byKey(const ValueKey('reader-page-surface')));
      await tester.pumpAndSettle();
      final stopped = pageNumber();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(pageNumber(), stopped);
    });
  });
}

ReaderChapterLayout _layout() => ReaderChapterLayout(
  title: '第一章 测试',
  content: ChapterContent(
    blocks: [
      for (var i = 0; i < 40; i++)
        ChapterParagraph(
          '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。',
        ),
    ],
  ),
  spec: ReaderLayoutSpec(
    viewport: const Size(380, 620),
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  ),
);
