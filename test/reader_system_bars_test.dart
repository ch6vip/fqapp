import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fqapp/reader');
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  List<bool> immersiveRequests() => calls
      .where((call) => call.method == 'setImmersive')
      .map((call) => call.arguments['enabled'] as bool)
      .toList();

  testWidgets('status bar switch applies and persists both choices', (
    tester,
  ) async {
    // 默认显示状态栏：先关再开。
    for (final visible in [false, true]) {
      await tester.pumpWidget(MaterialApp(home: _reader()));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getRect(_surface).center);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('reader-more-appearance')),
      );
      await tester.tap(find.byKey(const ValueKey('reader-more-appearance')));
      await tester.pumpAndSettle();
      final row = find
          .ancestor(of: find.text('系统状态栏'), matching: find.byType(Row))
          .first;
      final toggle = find.descendant(of: row, matching: find.byType(Switch));
      await tester.ensureVisible(toggle);
      expect(tester.widget<Switch>(toggle).value, !visible);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, visible);
      await tester.tap(find.byTooltip('关闭更多设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭排版设置'));
      await tester.pumpAndSettle();
      final request = calls.lastWhere((call) => call.method == 'setImmersive');
      expect(request.arguments['enabled'], isTrue);
      expect(request.arguments['showStatusBar'], visible);
      expect((await ReaderPreferences.load()).showSystemStatusBar, visible);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'saved system status bar stays visible after resume and navigation',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_show_system_status_bar': true,
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: _reader()),
      );
      await tester.pumpAndSettle();

      void expectStatusBarVisible() {
        final request = calls.lastWhere(
          (call) => call.method == 'setImmersive',
        );
        expect(request.arguments['enabled'], isTrue);
        expect(request.arguments['showStatusBar'], isTrue);
      }

      expectStatusBarVisible();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expectStatusBarVisible();
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(immersiveRequests().last, isFalse);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expectStatusBarVisible();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('system bars follow reader route and foreground ownership', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _reader()),
    );
    await tester.pumpAndSettle();
    expect(immersiveRequests(), [true]);
    final viewport = tester.getRect(_surface);
    final layout = tester
        .widget<ReaderPagedView>(find.byType(ReaderPagedView))
        .layout;
    for (var i = 0; i < 2; i++) {
      await tester.tapAt(viewport.center);
      await tester.pumpAndSettle();
      expect(tester.getRect(_surface), viewport);
      expect(
        tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).layout,
        same(layout),
      );
    }
    expect(immersiveRequests(), [true]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(calls.any((call) => call.method == 'suspend'), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(immersiveRequests().last, isTrue);

    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(immersiveRequests().last, isFalse);
    calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(immersiveRequests(), isNot(contains(true)));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(immersiveRequests().last, isTrue);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'stop'), isTrue);
    final count = immersiveRequests().length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(immersiveRequests(), hasLength(count));
  });

  for (final showStatusBar in [false, true]) {
    testWidgets(
      'paragraph-ideas sheet preserves status bar choice $showStatusBar (#57)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_show_system_status_bar': showStatusBar,
        });
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: const Scaffold()),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => _readerWithIdeas()),
        );
        await tester.pumpAndSettle();
        expect(immersiveRequests(), isNot(contains(false)));
        expect(immersiveRequests().last, isTrue);

        // Open the ideas sheet via the paragraph bubble.
        await tester.tap(find.text('42'));
        await tester.pumpAndSettle();
        expect(find.text('这段太真实了'), findsOneWidget);
        // The sheet pushes a route; immersive must NOT be released.
        expect(immersiveRequests(), isNot(contains(false)));
        expect(immersiveRequests().last, isTrue);

        // Close the sheet; immersive stays on with no transient release:
        // the close used to flash the status bar for a frame (#57).
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('这段太真实了'), findsNothing);
        expect(immersiveRequests(), isNot(contains(false)));
        expect(immersiveRequests().last, isTrue);
        expect(tester.takeException(), isNull);
        expect(
          calls
              .where((call) => call.method == 'setImmersive')
              .map((call) => call.arguments['showStatusBar']),
          everyElement(showStatusBar),
        );
      },
    );
  }

  testWidgets('e-ink ideas sheet uses a transparent barrier (#57)', (
    tester,
  ) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await tester.pumpWidget(MaterialApp(home: _readerWithIdeas()));
    await tester.pumpAndSettle();

    // A fully transparent barrierColor makes the bottom-sheet route build
    // a plain (colorless) ModalBarrier for hit-testing; any visible dim
    // goes through an AnimatedModalBarrier whose animation ends at the
    // barrier color.
    Color? animatedBarrierColor() {
      final animated = tester.widgetList<AnimatedModalBarrier>(
        find.byType(AnimatedModalBarrier),
      );
      if (animated.isEmpty) return null;
      return animated.single.color.value;
    }

    bool hasDismissibleBarrier() {
      final barriers = tester.widgetList<ModalBarrier>(
        find.byType(ModalBarrier),
      );
      return barriers.any((barrier) => barrier.dismissible);
    }

    await tester.tap(find.text('42'));
    await tester.pumpAndSettle();
    expect(find.text('这段太真实了'), findsOneWidget);
    // Transparent: no animated dim barrier, but the dismissible
    // (tap-outside-to-close) barrier is still there.
    expect(animatedBarrierColor(), isNull);
    expect(hasDismissibleBarrier(), isTrue);

    // Dismiss via the barrier, then reopen without e-ink: the dimmed
    // scrim returns.
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(find.text('这段太真实了'), findsNothing);
    einkModeNotifier.value = false;
    await tester.pumpAndSettle();
    await tester.tap(find.text('42'));
    await tester.pumpAndSettle();
    expect(animatedBarrierColor(), Colors.black.withValues(alpha: 0.4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty reader does not hide system navigation', (tester) async {
    await tester.pumpWidget(MaterialApp(home: _reader(empty: true)));
    await tester.pumpAndSettle();
    expect(find.text('暂无可阅读章节'), findsOneWidget);
    expect(immersiveRequests(), isNot(contains(true)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in ['paged', 'scroll']) {
    testWidgets(
      '$mode paints full background but keeps content below a cutout',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': mode,
          'reader_show_reading_info': false,
          'reader_show_system_status_bar': true,
        });
        await tester.binding.setSurfaceSize(const Size(390, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: EdgeInsets.zero,
                viewPadding: EdgeInsets.zero,
                displayFeatures: const [
                  ui.DisplayFeature(
                    bounds: Rect.fromLTWH(170, 8, 50, 32),
                    type: ui.DisplayFeatureType.cutout,
                    state: ui.DisplayFeatureState.unknown,
                  ),
                ],
              ),
              child: child!,
            ),
            home: _reader(),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byType(Scaffold)),
          const Rect.fromLTWH(0, 0, 390, 800),
        );
        final viewport = tester.getRect(_surface);
        expect(viewport.top, greaterThanOrEqualTo(40));
        await tester.tapAt(viewport.center);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byTooltip('返回书籍')).top,
          greaterThanOrEqualTo(40),
        );
        expect(tester.getRect(_surface), viewport);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final bottom in [24.0, 48.0]) {
    for (final mode in ['paged', 'scroll']) {
      testWidgets('$mode keeps content and controls above a $bottom inset', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': mode,
          'reader_show_reading_info': false,
        });
        await tester.binding.setSurfaceSize(const Size(390, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final padding = EdgeInsets.only(top: 32, bottom: bottom);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: padding, viewPadding: padding),
              child: child!,
            ),
            home: _reader(),
          ),
        );
        await tester.pumpAndSettle();
        final viewport = tester.getRect(_surface);
        expect(viewport.top, greaterThanOrEqualTo(32));
        expect(viewport.bottom, lessThanOrEqualTo(800 - bottom));
        await tester.tapAt(viewport.center);
        await tester.pumpAndSettle();
        final settings = tester.getRect(
          find.byKey(const ValueKey('reader-settings')),
        );
        expect(settings.bottom, lessThanOrEqualTo(800 - bottom));
        expect(tester.getRect(_surface), viewport);
        await tester.tap(find.byTooltip('收起阅读菜单'));
        await tester.pumpAndSettle();
        expect(tester.getRect(_surface), viewport);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

final _surface = find.byKey(const ValueKey('reader-page-surface'));

const _ideasHtml =
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">第一段话。</p><p></p>'
    '<p idx="1">第二段话。</p>'
    '</article>';

ChapterIdeas _ideasWithBubble() => ChapterIdeas.fromPayload(const {
  'code': 0,
  'data': {
    'data': {
      '0': {
        'count': 42,
        'bubble_data': {
          '0': {'channel': 43, 'count': 0},
          '1': {'channel': 0, 'count': 42},
          '3': {'channel': 0, 'count': 42},
        },
        'infos': [],
      },
    },
  },
});

ReaderPage _readerWithIdeas() => ReaderPage(
  bookId: 'system-bars-ideas',
  title: '段评测试',
  chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '正文')],
  startIndex: 0,
  readerStore: MemoryReaderStore(),
  chapterCache: MemoryChapterCache(),
  chapterLoader: (_) async => parseChapterContent(_ideasHtml).toCacheText(),
  ideasLoader: (_) async => _ideasWithBubble(),
  commentResolver: (_, paragraph, _) async => const BookCommentPage(
    comments: [BookComment(id: 'x', text: '这段太真实了')],
  ),
);

ReaderPage _reader({bool empty = false}) => ReaderPage(
  bookId: 'system-bars-test',
  title: '安全区测试',
  chapters: empty ? [] : [Chapter(itemId: 'c1', title: '第一章', volumeName: '')],
  startIndex: 0,
  readerStore: MemoryReaderStore(),
  chapterCache: MemoryChapterCache(),
  chapterLoader: (_) async =>
      List.generate(45, (index) => '第 $index 段阅读正文。').join('\n\n'),
);
