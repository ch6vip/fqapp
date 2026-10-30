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

    testWidgets(
      'a chapter boundary requests once without showing an end page',
      (tester) async {
        final boundary = Completer<void>();
        final layout = _layout();
        var requests = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderPagedView(
                layout: layout,
                pageIndex: layout.pages.length - 1,
                hasPreviousChapter: false,
                hasNextChapter: true,
                onPageChanged: (_) {},
                onBoundary: (direction) {
                  expect(direction, 1);
                  requests++;
                  return boundary.future;
                },
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
        final state = tester.state<ReaderPagedViewState>(
          find.byType(ReaderPagedView),
        );
        unawaited(state.turnPage(1));
        // No animation/timer is needed to request the chapter.
        expect(requests, 1);
        unawaited(state.turnPage(1));
        await tester.pump(const Duration(seconds: 2));
        expect(requests, 1);
        expect(find.text('本章完'), findsNothing);
        expect(find.text('下一章'), findsNothing);
        boundary.complete();
        await tester.pump(const Duration(milliseconds: 32));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('the final chapter still has a stable completion page', (
      tester,
    ) async {
      final layout = _layout();
      var requests = 0;
      var completions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPagedView(
              layout: layout,
              pageIndex: layout.pages.length - 1,
              hasPreviousChapter: true,
              hasNextChapter: false,
              onPageChanged: (_) {},
              onBoundary: (_) async {
                requests++;
              },
              onDragStart: () {},
              turnStyle: ReaderPageTurnStyle.none,
              backgroundColor: Colors.white,
              endPage: const Center(child: Text('本章完')),
              onBookEnd: () => completions++,
            ),
          ),
        ),
      );
      final state = tester.state<ReaderPagedViewState>(
        find.byType(ReaderPagedView),
      );
      unawaited(state.turnPage(1));
      await tester.pumpAndSettle();
      expect(find.text('本章完'), findsOneWidget);
      expect(state.isAtEndPage, isTrue);
      expect(completions, 1);
      await state.turnPage(1);
      await tester.pump(const Duration(seconds: 2));
      expect(requests, 0);
      expect(state.isAtEndPage, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('reader behaviors', () {
    for (final style in [ReaderPageTurnStyle.slide, ReaderPageTurnStyle.curl]) {
      testWidgets('volume keys turn pages with ${style.name}', (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': 'paged',
          'reader_volume_key_turn': true,
          'reader_page_turn_style': style.name,
          'reader_info_mode': 'detailed',
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
        // 音量键已由 HardwareKeyboard 改为原生 MethodChannel 回调
        // （fqapp/volume-key），测试里没有原生端，改用平台通道模拟原生回调。
        Future<void> sendVolumeKey(int direction) async {
          await TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .handlePlatformMessage(
                'fqapp/volume-key',
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall('volumeKey', direction),
                ),
                (_) {},
              );
        }

        for (final (direction, page) in [(1, 2), (1, 3), (-1, 2), (-1, 1)]) {
          await sendVolumeKey(direction);
          await tester.pumpAndSettle();
          expect(pageNumber(), contains('本章 $page /'));
        }
      });
    }

    testWidgets('auto turn advances on its timer and stops on tap', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'paged',
        'reader_auto_turn_seconds': 3,
        'reader_info_mode': 'detailed',
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
      await _openSettings(tester);
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
        ChapterParagraph('清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。'),
    ],
  ),
  spec: ReaderLayoutSpec(
    viewport: const Size(380, 620),
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  ),
);

/// 从阅读菜单的「设置」直接打开阅读设置面板。
Future<void> _openSettings(WidgetTester tester) async {
  if (find.text('阅读设置').evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const ValueKey('reader-settings')));
  await tester.pumpAndSettle();
}
