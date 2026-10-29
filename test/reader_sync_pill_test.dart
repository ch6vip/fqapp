import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_player_pill.dart';
import 'package:fqapp/widgets/reader/reader_player_style.dart';
import 'package:fqapp/widgets/reader/reader_sync_pill.dart';

/// 官方 7.0.9.32 阅读页底部的两种按钮（`d.java:285-320`）：
///
/// * 朗读高亮在屏内 → 播放/暂停胶囊（`ReaderPlayerPill`）；
/// * 高亮不在屏内、当前是正常正文页 → 「原进度 / 从本页听」同步胶囊
///   （`nj4/i` / `nj4/h`，布局 `akc.xml`）。
///
/// 「原进度」= `AudioSyncReaderController.K()`（:768）：回到朗读处并继续跟；
/// 「从本页听」= `L()`（:702）：从本页重新起播并沿用当前音色。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
    ListeningSession.instance.setFollowArmed(false);
  });

  tearDown(() {
    ListeningSession.instance.clear();
  });

  group('default follow', () {
    test(
      'playback start, resume and a new book arm following by themselves',
      () {
        final session = ListeningSession.instance;
        _publish(session, playing: false);
        expect(session.followArmed, isFalse);

        _publish(session, playing: true);
        expect(session.followArmed, isTrue, reason: 'onPlayStart 起播即跟随');

        // 手动翻页退出跟随；同一段播放的 tick 不能把它又打开。
        session.setFollowArmed(false);
        _publish(session, playing: true);
        expect(session.followArmed, isFalse, reason: '同一段播放的 tick 不重开跟随');

        // 暂停后继续 = 官方 onPlayResume（AudioSyncReaderController.java:381），
        // 重新跟随。
        _publish(session, playing: false);
        _publish(session, playing: true);
        expect(session.followArmed, isTrue, reason: '继续播放要重新跟随');

        // 换一本正在播的书也算一次起播。
        session.setFollowArmed(false);
        _publish(session, playing: true, bookId: 'other');
        expect(session.followArmed, isTrue, reason: '换书起播要重新跟随');
      },
    );

    test('completion clears on the next playback, close clears both', () {
      final session = ListeningSession.instance;
      _publish(session, playing: true);
      session.markCompleted();
      expect(session.completed, isTrue);

      _publish(session, playing: true);
      expect(session.completed, isFalse, reason: '下一次起播清掉完成标记');

      session.markCompleted();
      session.clear();
      expect(session.completed, isFalse);
      expect(session.followArmed, isFalse);
    });

    test('an auto-advanced chapter does not drag a reader who turned away', () {
      final session = ListeningSession.instance;
      _publish(session, playing: true);
      expect(session.followArmed, isTrue, reason: '起播默认跟随');

      // 用户手动翻页走开（`AudioSyncReaderController` `C=true`），然后本章
      // 自然播完：guard 先发 playing:false，再标记完成，下一章接着播。
      session.setFollowArmed(false);
      _publish(session, playing: false);
      session.markCompleted();
      _publish(session, playing: true, chapterId: 'c2');

      expect(
        session.followArmed,
        isFalse,
        reason: '连播换章不是用户重新起播，不能把翻页走开的人拽回新章',
      );
      expect(session.completed, isFalse, reason: '新章起播后完成标记要清掉');
    });
  });

  group('ReaderSyncPill', () {
    Future<void> mount(
      WidgetTester tester, {
      double width = 400,
      VoidCallback? onReturn,
      VoidCallback? onListen,
      ReaderThemePreset preset = ReaderThemePreset.light,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, 640)),
            child: Scaffold(
              body: Center(
                child: ReaderSyncPill(
                  preset: preset,
                  onReturnOriginalProgress: onReturn ?? () {},
                  onListenFromPage: onListen ?? () {},
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows both actions and wires them up', (tester) async {
      var returns = 0;
      var listens = 0;
      await mount(tester, onReturn: () => returns++, onListen: () => listens++);
      expect(find.text('原进度'), findsOneWidget);
      expect(find.text('从本页听'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader_sync_return_original')),
      );
      await tester.tap(
        find.byKey(const ValueKey('reader_sync_listen_from_here')),
      );
      expect(returns, 1);
      expect(listens, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the official 32dp height and order', (tester) async {
      await mount(tester);
      final size = tester.getSize(
        find.byKey(const ValueKey('reader_sync_pill')),
      );
      expect(size.height, 32);
      final returnX = tester
          .getCenter(find.byKey(const ValueKey('reader_sync_return_original')))
          .dx;
      final listenX = tester
          .getCenter(find.byKey(const ValueKey('reader_sync_listen_from_here')))
          .dx;
      expect(returnX, lessThan(listenX), reason: '原进度在左，从本页听在右');
    });

    testWidgets('narrow screens drop 原进度 text and keep the icon', (
      tester,
    ) async {
      await mount(tester, width: 360);
      expect(find.text('原进度'), findsNothing);
      expect(
        find.byKey(const ValueKey('reader_sync_return_original')),
        findsOneWidget,
      );
      // 右边保留文字。
      expect(find.text('从本页听'), findsOneWidget);
    });

    testWidgets('375dp keeps the 原进度 text', (tester) async {
      await mount(tester, width: 375);
      expect(find.text('原进度'), findsOneWidget);
    });

    testWidgets('text and divider follow the reader theme color', (
      tester,
    ) async {
      const preset = ReaderThemePreset.parchment;
      await mount(tester, preset: preset);
      final label = tester.widget<Text>(find.text('原进度'));
      expect(label.style!.color, preset.playerText);
      final icon = tester.widget<Icon>(find.byIcon(Icons.replay));
      expect(icon.color, preset.playerText);
      final divider = tester.widget<SizedBox>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.width == 0.5 && widget.height == 12,
        ),
      );
      final color = (divider.child! as ColoredBox).color;
      expect(color.a, closeTo(preset.playerText.a * 0.24, 0.001));
    });
  });

  group('host swap', () {
    late ValueNotifier<int> viewport;
    setUp(() => viewport = ValueNotifier(0));
    tearDown(() => viewport.dispose());

    Future<void> mountHost(
      WidgetTester tester, {
      required bool highlightOnScreen,
      bool normalPage = true,
      bool controlsVisible = false,
      VoidCallback? onReturn,
      VoidCallback? onListen,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPlayerPillHost(
              bookId: 'b1',
              viewportChanges: viewport,
              highlightOnScreen: () => highlightOnScreen,
              normalPage: () => normalPage,
              controlsVisible: controlsVisible,
              animate: false,
              onReturnOriginalProgress: onReturn,
              onListenFromPage: onListen,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('highlight on screen keeps the play/pause pill', (
      tester,
    ) async {
      _publish(ListeningSession.instance, playing: true);
      await mountHost(tester, highlightOnScreen: true);
      expect(find.byKey(const ValueKey('reader_player_pill')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsNothing);
    });

    testWidgets('highlight off screen swaps in the sync pill', (tester) async {
      _publish(ListeningSession.instance, playing: true);
      await mountHost(tester, highlightOnScreen: false);
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader_player_pill')), findsNothing);
    });

    testWidgets('no sync pill on a non-normal page', (tester) async {
      _publish(ListeningSession.instance, playing: true);
      await mountHost(tester, highlightOnScreen: false, normalPage: false);
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsNothing);
      expect(find.byKey(const ValueKey('reader_player_pill')), findsNothing);
    });

    testWidgets('opening the menus hides both', (tester) async {
      _publish(ListeningSession.instance, playing: true);
      await mountHost(tester, highlightOnScreen: false, controlsVisible: true);
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsNothing);
    });

    testWidgets('closing the player hides the sync pill', (tester) async {
      _publish(ListeningSession.instance, playing: true);
      await mountHost(tester, highlightOnScreen: false);
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsOneWidget);
      ListeningSession.instance.clear();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsNothing);
    });

    testWidgets('completion hides the sync pill', (tester) async {
      _publish(ListeningSession.instance, playing: true);
      await mountHost(tester, highlightOnScreen: false);
      ListeningSession.instance.markCompleted();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsNothing);
    });

    testWidgets('normal page helper rejects image-only pages', (tester) async {
      // 纯图片页没有可朗读文字。
      final layout = ReaderChapterLayout(
        title: '',
        content: ChapterContent(blocks: [ChapterImage(url: 'a.png')]),
        spec: ReaderLayoutSpec(
          viewport: const Size(320, 480),
          textScaler: TextScaler.noScaling,
          fontFamily: null,
          preferences: const ReaderPreferences(),
        ),
      );
      expect(
        readerSyncPillNormalPage(layout: layout, paged: true, pageIndex: 0),
        isFalse,
      );
      expect(
        readerSyncPillNormalPage(layout: layout, paged: false, pageIndex: 0),
        isFalse,
      );
    });
  });
}

void _publish(
  ListeningSession session, {
  required bool playing,
  String bookId = 'b1',
  String chapterId = 'c1',
}) {
  session.update(
    bookId: bookId,
    chapterId: chapterId,
    chapterTitle: '第一章',
    position: Duration.zero,
    duration: const Duration(seconds: 60),
    playing: playing,
  );
}
