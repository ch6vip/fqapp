import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_full_search.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/widgets/reader/reader_full_search_panel.dart';

final _chapters = [
  Chapter(itemId: 'a', title: '第一章', volumeName: ''),
  Chapter(itemId: 'b', title: '第二章', volumeName: ''),
];
TextReplacementResult _text(String value) {
  final content = ChapterContent.fromPlainText(
    value,
    illustrationsChecked: true,
  );
  return TextReplacementResult(
    source: content,
    content: content,
    snapshotRevision: 0,
  );
}

Future<void> _mount(
  WidgetTester tester,
  ReaderFullSearchLoader loader, {
  ReaderThemePreset preset = ReaderThemePreset.light,
  Size size = const Size(375, 812),
  double scale = 1,
  double keyboard = 0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
          disableAnimations: true,
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ReaderFullSearchPanel(
              chapters: _chapters,
              loadChapter: loader,
              preset: preset,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'empty search does no work; groups sort by complete mention counts',
    (tester) async {
      var calls = 0;
      await _mount(tester, (chapter) async {
        ++calls;
        return _text(chapter.itemId == 'a' ? '他的书' : '他的书和他的笔');
      });
      expect(calls, 0);
      expect(find.text('输入关键词，查找全书内容'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reader-full-search-field')),
        '他的',
      );
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('全书 2 章 · 3 处匹配'), findsOneWidget);
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('reader-full-search-field')),
          )
          .controller!
          .selection = const TextSelection.collapsed(
        offset: 0,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        calls,
        2,
        reason: 'Caret movement must not restart chapter loads.',
      );
      final first = find.byKey(const ValueKey('reader-full-search-result-0-0'));
      final second = find.byKey(
        const ValueKey('reader-full-search-result-1-0'),
      );
      expect(
        tester.getTopLeft(first).dy,
        lessThan(tester.getTopLeft(second).dy),
      );
      await tester.tap(
        find.byKey(const ValueKey('reader-full-search-order-mentions')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(second).dy,
        lessThan(tester.getTopLeft(first).dy),
      );
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-full-search-results')),
        findsNothing,
      );
      expect(find.text('输入关键词，查找全书内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'IME composition does not start loads and stopped work stays stopped',
    (tester) async {
      final pending = Completer<TextReplacementResult>();
      var calls = 0;
      await _mount(tester, (_) {
        ++calls;
        return pending.future;
      });
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('reader-full-search-field')),
      );
      field.controller!.value = const TextEditingValue(
        text: '他的',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, 0);
      expect(find.text('完成输入后搜索'), findsOneWidget);
      field.controller!.value = const TextEditingValue(
        text: '他的',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.pump(const Duration(milliseconds: 310));
      expect(calls, 1);
      await tester.tap(find.text('停止'));
      await tester.pump();
      pending.complete(_text('他的书'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('已停止 · 已搜索 0/2 章'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-full-search-results')),
        findsNothing,
      );
    },
  );

  testWidgets('load failures show partial scope and can retry', (tester) async {
    var fail = true;
    await _mount(tester, (chapter) async {
      if (fail && chapter.itemId == 'b') throw StateError('offline');
      return _text('他的书');
    });
    await tester.enterText(
      find.byKey(const ValueKey('reader-full-search-field')),
      '他的',
    );
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 章未能搜索'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-full-search-result-0-0')),
      findsOneWidget,
    );
    fail = false;
    await tester.tap(find.text('重新搜索'));
    await tester.pumpAndSettle();
    expect(find.text('全书 2 章 · 2 处匹配'), findsOneWidget);
    expect(find.textContaining('未能搜索'), findsNothing);
  });

  for (final scenario in [
    (
      name: 'dark large text small phone',
      size: const Size(375, 812),
      scale: 2.0,
      keyboard: 280.0,
      preset: ReaderThemePreset.dark,
    ),
    (
      name: 'landscape',
      size: const Size(812, 375),
      scale: 1.0,
      keyboard: 0.0,
      preset: ReaderThemePreset.light,
    ),
  ]) {
    testWidgets('${scenario.name} keeps input and close control visible', (
      tester,
    ) async {
      await _mount(
        tester,
        (_) async => _text('他的书'),
        size: scenario.size,
        scale: scenario.scale,
        keyboard: scenario.keyboard,
        preset: scenario.preset,
      );
      expect(
        find.byKey(const ValueKey('reader-full-search-field')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-full-search-close')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
