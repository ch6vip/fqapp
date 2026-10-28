import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/widgets/reader/reader_player_pill.dart';

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

  testWidgets('compact mode keeps only the icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReaderPlayerPill(
              playing: true,
              compact: true,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    // 官方 `ButtonType.indicator`：没有文字，宽高都是 32dp 的圆。
    expect(find.text('暂停播放'), findsNothing);
    expect(find.text('继续播放'), findsNothing);
    final size = tester.getSize(
      find.byKey(const ValueKey('reader_player_pill')),
    );
    expect(size.height, 32);
    expect(size.width, 32);
  });

  group('overlay', () {
    Future<void> mountOverlay(
      WidgetTester tester, {
      required String bookId,
      bool highlightOnScreen = false,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                ReaderPlayerPillOverlay(
                  bookId: bookId,
                  highlightOnScreen: highlightOnScreen,
                ),
              ],
            ),
          ),
        ),
      );
    }

    void publish({required String bookId, required bool playing}) {
      ListeningSession.instance.update(
        bookId: bookId,
        chapterId: 'c1',
        chapterTitle: '第1章',
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        playing: playing,
      );
    }

    testWidgets('stays hidden when the audio book is a different one',
        (tester) async {
      publish(bookId: 'other', playing: true);
      await mountOverlay(tester, bookId: 'mine');
      expect(find.byKey(const ValueKey('reader_player_pill')), findsNothing);
    });

    testWidgets('shrinks to the icon while playing with the highlight on screen',
        (tester) async {
      publish(bookId: 'mine', playing: true);
      await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
      expect(find.text('暂停播放'), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('reader_player_pill'))).width,
        32,
      );
    });

    testWidgets('stays a full pill while paused even with the highlight visible',
        (tester) async {
      publish(bookId: 'mine', playing: false);
      await mountOverlay(tester, bookId: 'mine', highlightOnScreen: true);
      // 官方：「暂停状态下，不展示弱化效果」。
      expect(find.text('继续播放'), findsOneWidget);
    });

    testWidgets('shows for the book currently being listened to',
        (tester) async {
      publish(bookId: 'mine', playing: false);
      await mountOverlay(tester, bookId: 'mine');
      expect(find.byKey(const ValueKey('reader_player_pill')), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);
    });
  });
}
