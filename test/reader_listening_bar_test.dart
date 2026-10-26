import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/listening_session.dart';

import 'support/fakes.dart';

/// 阅读页左下角的听书悬浮条。
///
/// 官方把它做成一个小胶囊（圆封面 + 暂停 + 关闭），浮在正文之上，只在
/// 「这本书正在朗读、且菜单收起」时出现。它让读者能边听边读而不必退回
/// 听书页去按暂停。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ListeningSession.instance.clear();
  });

  tearDown(() => ListeningSession.instance.clear());


  /// 让这本书进入朗读状态。生产环境里 TTS 与听书控制器在每次发布时都会挂上
  /// 控制回调，这里照做——悬浮条的显隐要求至少有一个回调可用。
  void startNarrating({
    String bookId = 'bar-book',
    String chapterId = 'bar-chapter',
    bool playing = true,
    Future<void> Function()? onToggle,
    Future<void> Function()? onStop,
  }) {
    ListeningSession.instance
      ..onToggle = onToggle ?? () async {}
      ..onStop = onStop ?? () async {};
    ListeningSession.instance.update(
      bookId: bookId,
      chapterId: chapterId,
      chapterTitle: '第 1 章',
      position: Duration.zero,
      duration: const Duration(seconds: 60),
      playing: playing,
    );
  }

  Future<void> pumpReader(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'bar-book',
          title: '悬浮条测试',
          cover: '',
          chapters: [
            Chapter(itemId: 'bar-chapter', title: '第 1 章', volumeName: ''),
          ],
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (_) async => '第 1 章\n\n正文内容。',
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('is hidden when nothing is being narrated', (tester) async {
    await pumpReader(tester);
    expect(find.byKey(const ValueKey('reader-listening-bar')), findsNothing);
  });

  testWidgets('appears once this book is narrating', (tester) async {
    await pumpReader(tester);
    startNarrating();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('reader-listening-bar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-listening-toggle')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reader-listening-close')), findsOneWidget);
  });

  testWidgets('another book narrating does not show the bar', (tester) async {
    await pumpReader(tester);
    startNarrating(bookId: 'some-other-book');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('reader-listening-bar')), findsNothing);
  });

  testWidgets('disappears when narration stops', (tester) async {
    await pumpReader(tester);
    startNarrating();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('reader-listening-bar')), findsOneWidget);

    ListeningSession.instance.clear();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('reader-listening-bar')), findsNothing);
  });

  testWidgets('the pause button calls the engine hook', (tester) async {
    await pumpReader(tester);
    var toggled = 0;
    startNarrating(onToggle: () async {
      toggled++;
    });
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('reader-listening-toggle')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(toggled, 1);
  });

  testWidgets('the close button calls the engine hook', (tester) async {
    await pumpReader(tester);
    var stopped = 0;
    startNarrating(onStop: () async {
      stopped++;
    });
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('reader-listening-close')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(stopped, 1);
  });

  testWidgets('hides while the reader menu is open', (tester) async {
    await pumpReader(tester);
    startNarrating();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('reader-listening-bar')), findsOneWidget);

    // Opening the menu: the menu carries its own transport, so the floating
    // bar would only duplicate it.
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('reader-listening-bar')), findsNothing);
  });
}
