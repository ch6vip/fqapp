import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_classic_more_sheet.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

const _longTitle = '这是一本书名非常非常长而且必须保持单行省略的小说';
const _longAuthor = '这是一位名字很长很长的小说作者';

void main() {
  testWidgets('title truncates on one line and opens details independently', (
    tester,
  ) async {
    var details = 0;
    var authors = 0;
    await _pumpSheet(
      tester,
      title: _longTitle,
      onDetails: () => details++,
      onAuthor: () => authors++,
    );

    final title = tester.widget<Text>(find.text(_longTitle));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(
      tester
          .renderObject<RenderParagraph>(find.text(_longTitle))
          .didExceedMaxLines,
      isTrue,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('classic-reader-title')),
        matching: find.byIcon(LucideIcons.chevron_right),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('classic-reader-title')));
    await tester.pump();
    expect(details, 1);
    expect(authors, 0);
    await tester.tap(find.byKey(const ValueKey('classic-reader-cover')));
    await tester.pump();
    expect(details, 2);
    await tester.tap(find.byKey(const ValueKey('classic-reader-details')));
    await tester.pump();
    expect(details, 3);
    expect(authors, 0);
  });

  testWidgets('author has its own callback, chevron and 48dp touch target', (
    tester,
  ) async {
    var details = 0;
    var authors = 0;
    await _pumpSheet(
      tester,
      onDetails: () => details++,
      onAuthor: () => authors++,
    );
    final author = find.byKey(const ValueKey('classic-reader-author'));
    expect(
      find.descendant(
        of: author,
        matching: find.byIcon(LucideIcons.chevron_right),
      ),
      findsOneWidget,
    );
    for (final key in const [
      'classic-reader-title',
      'classic-reader-cover',
      'classic-reader-author',
      'classic-reader-details',
      'classic-reader-add-bookmark',
      'classic-reader-bookmarks',
      'classic-reader-full-search',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }

    await tester.tap(author);
    await tester.pump();
    expect(authors, 1);
    expect(details, 0);
  });

  testWidgets('unavailable author is plain text without a button or chevron', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var details = 0;
      await _pumpSheet(tester, onDetails: () => details++);

      final author = find.byKey(const ValueKey('classic-reader-author'));
      expect(tester.widget<InkWell>(author).onTap, isNull);
      expect(find.byIcon(LucideIcons.chevron_right), findsNothing);
      expect(
        tester.getSemantics(author),
        matchesSemantics(
          label: '作者名字',
          isButton: false,
          hasEnabledState: false,
        ),
      );
      await tester.tap(author);
      await tester.pump();
      expect(details, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('blank author stays hidden even if a callback was provided', (
    tester,
  ) async {
    var authors = 0;
    await _pumpSheet(tester, author: '  ', onAuthor: () => authors++);
    expect(find.byKey(const ValueKey('classic-reader-author')), findsNothing);
    expect(find.byIcon(LucideIcons.chevron_right), findsNothing);
    expect(authors, 0);
  });

  testWidgets(
    'bookmark management is separate and works without add permission',
    (tester) async {
      var bookmarks = 0;
      await _pumpSheet(
        tester,
        canBookmark: false,
        canSearch: false,
        onBookmarks: () => bookmarks++,
      );
      expect(find.text('书籍详情'), findsOneWidget);
      expect(find.text('添加书签'), findsOneWidget);
      expect(find.text('书签管理'), findsOneWidget);
      expect(find.text('全文搜索'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('classic-reader-add-bookmark')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('classic-reader-full-search')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('classic-reader-bookmarks')));
      await tester.pump();
      expect(bookmarks, 1);
    },
  );

  testWidgets('default actions return distinct route results', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<String>(
                  context: context,
                  builder: (_) => const ReaderClassicMoreSheet(
                    title: '书名',
                    author: '作者',
                    cover: '',
                    preset: ReaderThemePreset.light,
                    canBookmark: true,
                    canSearch: true,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    for (final (key, expected) in const [
      ('classic-reader-title', 'details'),
      ('classic-reader-details', 'details'),
      ('classic-reader-add-bookmark', 'bookmark'),
      ('classic-reader-bookmarks', 'bookmarks'),
      ('classic-reader-full-search', 'search'),
    ]) {
      result = null;
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(result, expected, reason: key);
    }
  });

  for (final preset in [ReaderThemePreset.light, ReaderThemePreset.dark]) {
    testWidgets('320dp at 2x fits all actions in ${preset.name}', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        title: _longTitle,
        author: _longAuthor,
        preset: preset,
        size: const Size(320, 700),
        textScale: 2,
        onAuthor: () {},
      );
      expect(tester.takeException(), isNull);
      final details = tester.getRect(
        find.byKey(const ValueKey('classic-reader-details')),
      );
      final bookmarks = tester.getRect(
        find.byKey(const ValueKey('classic-reader-bookmarks')),
      );
      expect(bookmarks.top, greaterThan(details.bottom));
      for (final label in ['书籍详情', '添加书签', '书签管理', '全文搜索']) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
        final bounds = tester.getRect(find.text(label));
        expect(bounds.left, greaterThanOrEqualTo(0), reason: label);
        expect(bounds.right, lessThanOrEqualTo(320), reason: label);
      }
      expect(
        tester.widget<Text>(find.text(_longTitle)).style?.color,
        preset.textColor,
      );
      expect(
        tester.widget<Text>(find.text(_longAuthor)).style?.color,
        preset.mutedTextColor,
      );
    });
  }

  testWidgets('normal phone keeps four circular actions in one row', (
    tester,
  ) async {
    await _pumpSheet(tester, size: const Size(320, 700));
    final details = tester.getTopLeft(
      find.byKey(const ValueKey('classic-reader-details')),
    );
    final search = tester.getTopLeft(
      find.byKey(const ValueKey('classic-reader-full-search')),
    );
    expect(details.dy, search.dy);
    expect(search.dx, greaterThan(details.dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape viewport can scroll to the final action', (
    tester,
  ) async {
    var bookmarks = 0;
    await _pumpSheet(
      tester,
      size: const Size(568, 280),
      textScale: 2,
      onBookmarks: () => bookmarks++,
    );
    final action = find.byKey(const ValueKey('classic-reader-bookmarks'));
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pump();
    expect(bookmarks, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  String title = '书名',
  String author = '作者名字',
  ReaderThemePreset preset = ReaderThemePreset.light,
  bool canBookmark = true,
  bool canSearch = true,
  VoidCallback? onDetails,
  VoidCallback? onAuthor,
  VoidCallback? onBookmarks,
  Size size = const Size(375, 700),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: preset.isDark ? Brightness.dark : Brightness.light,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: preset.backgroundColor,
            child: ReaderClassicMoreSheet(
              title: title,
              author: author,
              cover: '',
              preset: preset,
              canBookmark: canBookmark,
              canSearch: canSearch,
              onDetails: onDetails,
              onAuthor: onAuthor,
              onBookmarks: onBookmarks,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
