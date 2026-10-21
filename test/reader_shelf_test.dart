import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';

/// 阅读器内「加入书架」（issue #103）：小说阅读器与漫画阅读器都不再依赖详情页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    directory = await Directory.systemTemp.createTemp('fqapp-reader-shelf-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    // 仍挂着的页面会留着 box 监听，Hive.close() 可能永远等不到；设个上限兜底。
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // 临时目录清了就清了，失败只是噪音。
    }
  });

  testWidgets('小说阅读器里可以直接加入/移出书架', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'reader-shelf',
          title: '阅读器测试书',
          chapters: _chapters,
          startIndex: 0,
          chapterLoader: _loadChapter,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openReaderMenu(tester);

    final button = find.byKey(const ValueKey('reader-shelf-button'));
    expect(button, findsOneWidget);
    expect(tester.widget<IconButton>(button).tooltip, '加入书架');

    await tester.tap(button);
    await _settleShelfWrite(tester, '已加入书架');

    expect(ShelfStore.instance.contains('book', 'reader-shelf'), isTrue);
    expect(find.text('已加入书架'), findsOneWidget);
    expect(tester.widget<IconButton>(button).tooltip, '已在书架');

    await tester.tap(button);
    await _settleShelfWrite(tester, '已移出书架');

    expect(ShelfStore.instance.contains('book', 'reader-shelf'), isFalse);
    expect(find.text('已移出书架'), findsOneWidget);
    expect(tester.widget<IconButton>(button).tooltip, '加入书架');
  });

  testWidgets('漫画阅读器里可以直接加入书架', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderPage(
          bookId: 'comic-shelf',
          title: '漫画测试书',
          chapters: _chapters,
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterLoader: (chapter) async => const [
            ComicImage(url: 'memory://page-1'),
          ],
          imageProviderFactory: (_) => MemoryImage(_transparentPng),
        ),
      ),
    );
    await tester.pump();
    // 图片解码走真实异步，fake-async 的 pumpAndSettle 等不到它。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    final button = find.byKey(const Key('comic_reader_shelf_button'));
    expect(button, findsOneWidget);
    expect(tester.widget<IconButton>(button).tooltip, '加入书架');

    await tester.tap(button);
    await _settleShelfWrite(tester, '已加入书架');

    expect(ShelfStore.instance.contains('manga', 'comic-shelf'), isTrue);
    expect(find.text('已加入书架'), findsOneWidget);
    expect(tester.widget<IconButton>(button).tooltip, '已在书架');
  });
}

/// 点正文中间唤出阅读菜单（工具栏只在菜单展开时存在）。
Future<void> _openReaderMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
  );
  await tester.pumpAndSettle();
}

/// 书架写入走 Hive：真实事件循环的回合里才完成，`pump` 只推进 fake-async。
///
/// 等的是**这条**提示：连续两次切换会产生两条 SnackBar，第二条要等前一条的 2 秒
/// 期限走完才轮得到，所以每轮额外把 fake 时钟往前推一点。
Future<void> _settleShelfWrite(
  WidgetTester tester,
  String expectedText,
) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.text(expectedText).evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.pump(const Duration(milliseconds: 300));

}
final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章', volumeName: '正文'),
];

Future<String> _loadChapter(Chapter chapter) async =>
    '${chapter.title}\n这是 ${chapter.title} 的正文。';

/// 1×1 透明 PNG：漫画占位图不必真的联网。
final _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);
