import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

import 'support/fakes.dart';

const _title = '书名很长时也应该完整换行显示的离线阅读测试小说';

CachedBook _book(int count) => CachedBook(
  id: 'book',
  title: _title,
  chapters: [
    for (var i = 0; i < count; i++)
      Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
  ],
);

String _text(String text) => ChapterContent.fromPlainText(
  text,
  illustrationsChecked: true,
).toCacheText();

Widget _app(Widget body, {double scale = 1, bool classic = true}) =>
    MaterialApp(
      theme: ThemeData(
        extensions: [
          if (classic)
            const AppStyleTokens.classic()
          else
            const AppStyleTokens.archive(),
        ],
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: body),
    );

void main() {
  testWidgets('classic reader aligns a two-column grid inside equal gutters', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final cache = MemoryChapterCache();
    cache.content['book'] = {'0': _text('当前章'), 'removed': _text('旧目录')};
    await tester.pumpWidget(
      _app(
        ChapterCacheSheet(
          book: _book(122),
          currentIndex: 0,
          cache: cache,
          loader: (_) async => _text('正文'),
          shell: ChapterCacheShell.reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = tester.getRect(
      find.widgetWithText(OutlinedButton, '缓存后 20 章'),
    );
    final second = tester.getRect(
      find.widgetWithText(OutlinedButton, '缓存后 50 章'),
    );
    final third = tester.getRect(
      find.widgetWithText(OutlinedButton, '缓存后 100 章'),
    );
    final all = tester.getRect(find.byKey(const Key('chapter_cache_all')));
    expect(first.left, 20);
    expect(second.right, 370);
    expect(first.top, second.top);
    expect(third.top, all.top);
    expect(first.width, second.width);
    expect(first.width, all.width);
    expect(first.height, greaterThanOrEqualTo(48));
    expect(second.left - first.right, 8);
    expect(find.text('已缓存 1 / 122 章'), findsOneWidget);
    final summary = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('classic-cache-summary-progress')),
    );
    expect(summary.value, 1 / 122);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp dark reader at 2x text reflows and scrolls every action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      _app(
        ChapterCacheSheet(
          book: _book(122),
          currentIndex: 0,
          cache: MemoryChapterCache(),
          loader: (_) async => _text('正文'),
          shell: ChapterCacheShell.reader,
          readerPreset: ReaderThemePreset.dark,
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    final first = tester.getRect(
      find.widgetWithText(OutlinedButton, '缓存后 20 章'),
    );
    final second = tester.getRect(
      find.widgetWithText(OutlinedButton, '缓存后 50 章'),
    );
    expect(first.left, 16);
    expect(first.right, 304);
    expect(second.top, greaterThan(first.bottom));
    final title = tester.widget<Text>(find.text(_title));
    expect(title.maxLines, isNull);
    expect(title.style!.color, ReaderThemePreset.dark.textColor);
    await tester.ensureVisible(find.byKey(const Key('chapter_cache_all')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('chapter_cache_all')).hitTestable(),
      findsOneWidget,
    );
    await tester.ensureVisible(find.textContaining('关闭面板会停止下载'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final close in [false, true]) {
    testWidgets('classic reader ${close ? 'close' : 'stop'} preserves reuse '
        'callbacks and rejects late saves', (tester) async {
      final cache = MemoryChapterCache();
      final cached = _text('已缓存正文');
      cache.content['book'] = {'1': cached};
      final pending = Completer<String>();
      final requested = <String>[];
      final delivered = <String, String>{};
      final sheet = ChapterCacheSheet(
        book: _book(22),
        currentIndex: 0,
        cache: cache,
        shell: ChapterCacheShell.reader,
        loader: (chapter) {
          requested.add(chapter.itemId);
          return pending.future;
        },
        onContentAvailable: (chapter, text) => delivered[chapter.itemId] = text,
      );
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => sheet,
              ),
              child: const Text('打开缓存'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 20 章'));
      await tester.pump();
      expect(requested, ['2']);
      expect(delivered, {'1': cached});
      expect(find.text('正在缓存 1 / 20 章'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '缓存后 20 章'),
            )
            .onPressed,
        isNull,
      );
      if (close) {
        await tester.tap(find.byTooltip('关闭'));
      } else {
        await tester.ensureVisible(find.text('停止缓存'));
        await tester.tap(find.text('停止缓存'));
      }
      await tester.pumpAndSettle();
      pending.complete(_text('停止后到达的正文'));
      await tester.pumpAndSettle();
      expect(await cache.cachedChapterIds('book'), {'1'});
      expect(cache.pinned['book'], isNull);
      expect(delivered, {'1': cached});
      expect(requested, ['2']);
      if (close) {
        expect(find.byType(ChapterCacheSheet), findsNothing);
      } else {
        expect(find.textContaining('已停止缓存'), findsOneWidget);
        expect(find.text('停止缓存'), findsNothing);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '缓存后 20 章'),
              )
              .onPressed,
          isNotNull,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('classic whole-book action preserves range and pinned storage', (
    tester,
  ) async {
    final cache = MemoryChapterCache(chapterCapacity: 4);
    final fetched = <String>[];
    await tester.pumpWidget(
      _app(
        ChapterCacheSheet(
          book: _book(102),
          currentIndex: 0,
          cache: cache,
          shell: ChapterCacheShell.reader,
          loader: (chapter) async {
            fetched.add(chapter.itemId);
            return _text('正文${chapter.itemId}');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chapter_cache_all')));
    await tester.pumpAndSettle();
    expect(fetched, [for (var i = 1; i <= 101; i++) '$i']);
    expect(cache.pinned['book'], fetched.toSet());
    expect(find.text('已缓存 101 / 102 章'), findsOneWidget);
    expect(find.textContaining('缓存完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final shell in ChapterCacheShell.values) {
    testWidgets('$shell archive retains its existing cache content', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          ChapterCacheSheet(
            book: _book(122),
            currentIndex: 0,
            cache: MemoryChapterCache(),
            loader: (_) async => _text('正文'),
            shell: shell,
          ),
          classic: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('classic-cache-content')), findsNothing);
      expect(find.byType(Wrap), findsOneWidget);
      expect(find.textContaining('关闭此面板会停止下载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
