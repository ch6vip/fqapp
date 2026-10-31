import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';
import 'package:fqapp/widgets/home/home_sheet.dart';
import 'package:fqapp/widgets/reader/settings/reader_settings_widgets.dart';

import 'support/fakes.dart';

/// 章节缓存面板的两种外壳：听书页用通用 [HomeSheetFrame]，阅读器用阅读设置
/// 面板的 [ReaderSettingsSheetFrame]（配色跟随阅读 preset）。
void main() {
  CachedBook book() => CachedBook(
    id: 'book',
    title: '缓存测试',
    chapters: [
      Chapter(itemId: '1', title: '第一章', volumeName: ''),
      Chapter(itemId: '2', title: '第二章', volumeName: ''),
    ],
  );

  Widget mount({
    ChapterCacheShell shell = ChapterCacheShell.home,
    ReaderThemePreset preset = ReaderThemePreset.light,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ChapterCacheSheet(
          book: book(),
          currentIndex: 0,
          cache: MemoryChapterCache(),
          loader: (_) async => '正文',
          shell: shell,
          readerPreset: preset,
        ),
      ),
    );
  }

  testWidgets('the home shell renders the shared HomeSheetFrame', (
    tester,
  ) async {
    await tester.pumpWidget(mount());
    await tester.pumpAndSettle();
    expect(find.byType(HomeSheetFrame), findsOneWidget);
    expect(find.byType(ReaderSettingsSheetFrame), findsNothing);
    expect(find.text('章节缓存'), findsOneWidget);
  });

  testWidgets('the reader shell follows the reading preset', (tester) async {
    await tester.pumpWidget(
      mount(shell: ChapterCacheShell.reader, preset: ReaderThemePreset.dark),
    );
    await tester.pumpAndSettle();
    final frame = tester.widget<ReaderSettingsSheetFrame>(
      find.byType(ReaderSettingsSheetFrame),
    );
    expect(frame.preset, ReaderThemePreset.dark);
    expect(find.byType(HomeSheetFrame), findsNothing);
    expect(find.text('章节缓存'), findsOneWidget);
  });
}
