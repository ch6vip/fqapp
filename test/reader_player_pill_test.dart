import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_player_pill.dart';
import 'package:fqapp/widgets/reader/reader_player_style.dart';

/// 官方 `ReaderPlayerButton`（`ajo.xml` 的 `TextView j53`）：阅读页底部那枚
/// 32dp 高的胶囊，播放中显示「暂停播放」，暂停时显示「继续播放」。
void main() {
  setUp(() => ListeningSession.instance.clear());

  Future<void> mountPill(
    WidgetTester tester, {
    required bool playing,
    VoidCallback? onTap,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReaderPlayerPill(playing: playing, onTap: onTap ?? () {}),
          ),
        ),
      ),
    );
  }

  testWidgets('says 继续播放 with a play icon while paused', (tester) async {
    await mountPill(tester, playing: false);
    expect(find.text('继续播放'), findsOneWidget);
    expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.play_arrow);
  });

  testWidgets('says 暂停播放 with a pause icon while playing', (tester) async {
    await mountPill(tester, playing: true);
    expect(find.text('暂停播放'), findsOneWidget);
    expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.pause);
  });

  testWidgets('toggles playback on tap', (tester) async {
    var taps = 0;
    await mountPill(tester, playing: false, onTap: () => taps++);
    await tester.tap(find.byKey(const ValueKey('reader_player_pill')));
    expect(taps, 1);
  });

  testWidgets('keeps the official 32dp pill geometry', (tester) async {
    await mountPill(tester, playing: false);
    final size = tester.getSize(
      find.byKey(const ValueKey('reader_player_pill')),
    );
    // 官方 `ajo.xml`：高 32dp；宽度 = 左18 + 图标14 + 间距4 + 四字56 + 右20。
    expect(size.height, 32);
    expect(size.width, greaterThan(100));
    expect(size.width, lessThan(130));
  });

  testWidgets('weak mode keeps the label without a capsule background', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReaderPlayerPill(playing: true, weak: true, onTap: () {}),
          ),
        ),
      ),
    );
    expect(find.text('暂停播放'), findsOneWidget);
    expect(find.text('继续播放'), findsNothing);
    final size = tester.getSize(
      find.byKey(const ValueKey('reader_player_pill')),
    );
    expect(size.height, 32);
    expect(size.width, greaterThan(100));
    expect(
      tester
          .widget<Material>(find.byKey(const ValueKey('reader-player-text')))
          .color,
      Colors.transparent,
    );
  });

  group('overlay', () {
    late ValueNotifier<int> viewportChanges;
    setUp(() => viewportChanges = ValueNotifier(0));
    tearDown(() => viewportChanges.dispose());

    Future<void> mountOverlay(
      WidgetTester tester, {
      required String bookId,
      bool highlightOnScreen = false,
      bool Function()? visibility,
      bool controlsVisible = false,
      bool animate = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPlayerPillHost(
              bookId: bookId,
              highlightOnScreen: visibility ?? () => highlightOnScreen,
              viewportChanges: viewportChanges,
              controlsVisible: controlsVisible,
              animate: animate,
              child: const SizedBox.expand(key: ValueKey('content')),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    void publish({
      required String bookId,
      required bool playing,
      String chapterId = 'c1',
    }) {
      ListeningSession.instance.update(
        bookId: bookId,
        chapterId: chapterId,
        chapterTitle: '第1章',
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        playing: playing,
      );
    }

    testWidgets('stays hidden when the audio book is a different one', (
      tester,
    ) async {
      publish(bookId: 'other', playing: true);
      await mountOverlay(tester, bookId: 'mine');
      expect(find.byKey(const ValueKey('reader_player_pill')), findsNothing);
    });

    testWidgets(
      'weakens after five seconds without removing text or reflowing',
      (tester) async {
        publish(bookId: 'mine', playing: true);
        await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
        final content = tester.getRect(find.byKey(const ValueKey('content')));
        expect(
          tester.widget<ReaderPlayerPill>(find.byType(ReaderPlayerPill)).weak,
          isFalse,
        );
        await tester.pump(const Duration(milliseconds: 4999));
        expect(
          tester.widget<ReaderPlayerPill>(find.byType(ReaderPlayerPill)).weak,
          isFalse,
        );
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(
          tester.widget<ReaderPlayerPill>(find.byType(ReaderPlayerPill)).weak,
          isTrue,
        );
        expect(find.text('暂停播放'), findsOneWidget);
        expect(tester.getRect(find.byKey(const ValueKey('content'))), content);
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('reader-player-text')))
              .dy,
          greaterThanOrEqualTo(content.bottom),
        );
      },
    );

    testWidgets(
      'stays a full pill while paused even with the highlight visible',
      (tester) async {
        publish(bookId: 'mine', playing: false);
        await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
        // 官方：「暂停状态下，不展示弱化效果」。
        expect(find.text('继续播放'), findsOneWidget);
      },
    );

    testWidgets('shows for the book currently being listened to', (
      tester,
    ) async {
      publish(bookId: 'mine', playing: false);
      await mountOverlay(tester, bookId: 'mine');
      expect(find.byKey(const ValueKey('reader_player_pill')), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);
    });

    testWidgets('pause restores the capsule and resume starts a fresh delay', (
      tester,
    ) async {
      publish(bookId: 'mine', playing: true);
      await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      publish(bookId: 'mine', playing: false);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
      expect(find.text('继续播放'), findsOneWidget);
      publish(bookId: 'mine', playing: true);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-player-text')), findsOneWidget);
    });

    testWidgets('viewport changes cancel weakening and restore a weak button', (
      tester,
    ) async {
      var visible = true;
      publish(bookId: 'mine', playing: true);
      await mountOverlay(tester, bookId: 'mine', visibility: () => visible);
      await tester.pump(const Duration(seconds: 4));
      visible = false;
      viewportChanges.value++;
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
      visible = true;
      viewportChanges.value++;
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-player-text')), findsOneWidget);
      visible = false;
      viewportChanges.value++;
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
    });

    testWidgets('ticks do not restart the delay but a new chapter does', (
      tester,
    ) async {
      publish(bookId: 'mine', playing: true);
      await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
      for (var i = 0; i < 5; i++) {
        viewportChanges.value++;
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-player-text')), findsOneWidget);
      publish(bookId: 'mine', playing: true, chapterId: 'c2');
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('reader-player-text')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-player-text')), findsOneWidget);
    });

    testWidgets('menus hide both hosts and stop the pending delay', (
      tester,
    ) async {
      publish(bookId: 'mine', playing: true);
      await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
      final size = tester.getSize(find.byKey(const ValueKey('content')));
      await tester.pump(const Duration(seconds: 4));
      await mountOverlay(
        tester,
        bookId: 'mine',
        highlightOnScreen: true,
        controlsVisible: true,
      );
      await tester.pump(const Duration(seconds: 6));
      expect(find.byType(ReaderPlayerPill), findsNothing);
      expect(tester.getSize(find.byKey(const ValueKey('content'))), size);
      await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
    });

    testWidgets('closing or switching books cannot leave a stale weak timer', (
      tester,
    ) async {
      publish(bookId: 'mine', playing: true);
      await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
      await tester.pump(const Duration(seconds: 4));
      ListeningSession.instance.clear();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-player-footer')), findsNothing);
      publish(bookId: 'other', playing: true);
      await mountOverlay(tester, bookId: 'other', highlightOnScreen: true);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'missing controller reports failure instead of silently doing nothing',
      (tester) async {
        publish(bookId: 'mine', playing: false);
        await mountOverlay(tester, bookId: 'mine');
        await tester.tap(find.byKey(const ValueKey('reader_player_pill')));
        await tester.pump();
        expect(find.text('当前播放尚未就绪，请稍后重试'), findsOneWidget);
      },
    );
  });

  for (final preset in ReaderThemePreset.values) {
    testWidgets('${preset.name} supplies strong and weak theme colors', (
      tester,
    ) async {
      for (final weak in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ReaderPlayerPill(
                  playing: true,
                  onTap: () {},
                  preset: preset,
                  weak: weak,
                ),
              ),
            ),
          ),
        );
        expect(
          tester.widget<Text>(find.text('暂停播放')).style!.color,
          weak ? preset.playerWeakText : preset.playerText,
        );
        expect(
          tester
              .widget<Material>(
                find.byKey(
                  ValueKey(
                    weak ? 'reader-player-text' : 'reader-player-indicator',
                  ),
                ),
              )
              .color,
          weak ? Colors.transparent : preset.playerBackground,
        );
      }
    });
  }

  testWidgets(
    'both styles expose one accessible playback action at large text size',
    (tester) async {
      final semantics = tester.ensureSemantics();
      for (final weak in [false, true]) {
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: Center(
                  child: ReaderPlayerPill(
                    playing: true,
                    weak: weak,
                    onTap: () => taps++,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.bySemanticsLabel('暂停播放'), findsOneWidget);
        expect(
          tester.getSemantics(find.bySemanticsLabel('暂停播放')),
          matchesSemantics(label: '暂停播放', isButton: true, hasTapAction: true),
        );
        await tester.tap(find.byKey(const ValueKey('reader_player_pill')));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      }
      semantics.dispose();
    },
  );
}
