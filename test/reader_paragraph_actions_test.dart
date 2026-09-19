import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_paragraph_menu.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';


import 'support/fakes.dart';

const _html =
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">“对不起......”</p><p></p>'
    '<p idx="1"><span start_time="4200">“老子是兔子啊！”</span></p><p></p>'
    '</article>';

/// A chapter the reader cached before it ever read the spoken timeline.
String _legacyHtml() {
  final content = parseChapterContent(
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">“对不起......”</p><p></p>'
    '<p idx="1"><span start_time="4200">“老子是兔子啊！”</span></p><p></p>'
    '</article>',
  );
  final cached =
      '\u001efqapp:chapter:2\n'
      '{"version":2,"illustrationsChecked":true,"paragraphIdsChecked":true,'
      '"paragraphParserRevision":1,"legacyText":${jsonEncode(content.legacyText)},'
      '"blocks":[{"type":"text","text":"“对不起......”","idx":0},'
      '{"type":"text","text":"“老子是兔子啊！”","idx":1}]}';
  return cached;
}

final List<Chapter> _chapters = [
  Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
  Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
];

/// In-memory 划线 box so the tests never touch Hive.
class _MemoryUnderlines extends ReaderUnderlineStore {
  _MemoryUnderlines() : super(hive: null);

  final entries = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, ReaderUnderline>> load(
    String bookId,
    String chapterId,
  ) async {
    return {
      for (final raw in entries.values)
        if (ReaderUnderline.fromMap(raw) case final ReaderUnderline entry
            when entry.bookId == bookId && entry.chapterId == chapterId)
          entry.key: entry,
    };
  }

  @override
  Future<void> add(ReaderUnderline underline) async {
    entries[underline.key] = underline.toMap();
  }

  @override
  Future<void> remove(String key) async {
    entries.remove(key);
  }
}

Widget _app(ReaderUnderlineStore store, {String? html}) => MaterialApp(
  home: ReaderPage(
    bookId: 'reader-test',
    title: '测试书籍',
    chapters: _chapters,
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: (_) async =>
        parseChapterContent(html ?? _html).toCacheText(),
    underlineStore: store,
  ),
);

/// Long-presses the paragraph carrying `idx` and opens the action sheet.
Future<void> _longPressParagraph(WidgetTester tester, int paraIndex) async {
  final finder = find.byKey(ValueKey('reader-paragraph-$paraIndex'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.longPress(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  // `/api/content` answers with plain text and no `<p idx>`, so those chapters
  // carry no upstream paragraph ids at all. The menu used to require one and
  // silently did nothing, which looked like the long press was not working.
  const plainHtml =
      '<header><div class="tt-title">第一章</div></header>'
      '<article><p>“对不起......”</p><p>“老子是兔子啊！”</p></article>';

  // Paged mode puts every paragraph behind ReaderPageContent, whose own
  // GestureDetector needs the callback forwarded from ReaderPagedView. Scroll
  // mode was the only path covered, so 翻页 readers got no menu at all.
  testWidgets('paged mode also opens the menu on a long press', (tester) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    final finder = find.byKey(const ValueKey('reader-paragraph-press-0'));
    expect(finder, findsOneWidget);
    await tester.longPress(finder);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-action-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsOneWidget);
  });

  // The official bar takes u_ #FF303030 by day and s7 #FF1C1C1C at night
  // (selection/m.java#o); the mapping used to be recorded the other way round.
  testWidgets('the bar background is #FF303030 by day and #FF1C1C1C at night', (
    tester,
  ) async {
    Future<Color?> barColor({required bool dark}) async {
      await tester.pumpWidget(
        MaterialApp(home: ReaderParagraphMenu(isDark: dark)),
      );
      final containers = tester.widgetList<Container>(
        find.byWidgetPredicate(
          (widget) => widget is Container && widget.decoration is BoxDecoration,
        ),
      );
      return (containers.single.decoration! as BoxDecoration).color;
    }

    expect(await barColor(dark: false), const Color(0xFF303030));
    expect(await barColor(dark: true), const Color(0xFF1C1C1C));
  });

  testWidgets('the pressed paragraph keeps a wash while the bar is up', (
    tester,
  ) async {
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    final textId = paragraphUnderlineId(paraIndex: 0, blockIndex: 0);
    Color? highlightOfParagraph0() {
      for (final content
          in tester.widgetList<ReaderBlockContent>(
            find.byType(ReaderBlockContent),
          )) {
        if (content.block.textId == textId) return content.highlight;
      }
      return null;
    }

    expect(highlightOfParagraph0(), isNull);

    await _longPressParagraph(tester, 0);
    expect(
      highlightOfParagraph0(),
      ReaderPreferences().themePreset.selectionHighlightColor,
    );

    // Dismissing the bar clears the wash, like the official selection does.
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();
    expect(highlightOfParagraph0(), isNull);
  });

  testWidgets('paged mode paints the wash on the pressed paragraph too', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('reader-paragraph-press-0')),
    );
    await tester.pumpAndSettle();

    final pages = tester.widgetList<ReaderPageContent>(
      find.byType(ReaderPageContent),
    );
    final pressed = pages
        .where((page) => page.pressedParagraphTextId != null)
        .toList();
    expect(pressed, hasLength(1));
    expect(
      pressed.single.pressedParagraphTextId,
      paragraphUnderlineId(paraIndex: 0, blockIndex: 0),
    );
    expect(
      find.descendant(
        of: find.byWidget(pressed.single),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox &&
              widget.color ==
                  ReaderPreferences().themePreset.selectionHighlightColor,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a chapter without paragraph ids still offers the menu', (
    tester,
  ) async {
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store, html: plainHtml));
    await tester.pumpAndSettle();

    // Upstream gave no ids, so paragraphs fall back to their ordinal.
    final content = parseChapterContent(plainHtml);
    expect(
      content.blocks
          .whereType<ChapterParagraph>()
          .every((p) => p.paraIndex == null),
      isTrue,
    );

    await _longPressParagraph(tester, 0);
    expect(find.byKey(const ValueKey('reader-action-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-action-underline')),
      findsOneWidget,
    );
  });

  testWidgets('划线 works and is toggled off on an id-less paragraph', (
    tester,
  ) async {
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store, html: plainHtml));
    await tester.pumpAndSettle();

    await _longPressParagraph(tester, 0);
    await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
    await tester.pumpAndSettle();

    final saved = ReaderUnderline.fromMap(store.entries.values.single)!;
    expect(saved.paraIndex, isNull);
    expect(saved.blockIndex, 0);
    expect(saved.id, paragraphUnderlineId(paraIndex: null, blockIndex: 0));

    // The ordinal is the identity here, so the menu must show the undo state.
    await _longPressParagraph(tester, 0);
    expect(find.text('取消划线'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
    await tester.pumpAndSettle();
    expect(store.entries, isEmpty);
  });

  testWidgets('long-pressing a paragraph offers 复制 / 从本段听 / 划线', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_MemoryUnderlines()));
    await tester.pumpAndSettle();

    await _longPressParagraph(tester, 0);
    expect(find.byKey(const ValueKey('reader-action-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-action-underline')),
      findsOneWidget,
    );
    expect(find.text('取消划线'), findsNothing);
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('复制 puts the whole paragraph on the clipboard', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_MemoryUnderlines()));
    await tester.pumpAndSettle();

    await _longPressParagraph(tester, 0);
    await tester.tap(find.byKey(const ValueKey('reader-action-copy')));
    await tester.pumpAndSettle();

    expect(copied, ['“对不起......”']);
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('划线 saves locally, underlines the paragraph and can be undone', (
    tester,
  ) async {
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await _longPressParagraph(tester, 0);
    await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
    await tester.pumpAndSettle();

    expect(store.entries, hasLength(1));
    final saved = ReaderUnderline.fromMap(store.entries.values.single)!;
    expect(saved.bookId, 'reader-test');
    expect(saved.chapterId, 'c1');
    expect(saved.paraIndex, 0);
    expect(saved.text, '“对不起......”');
    expect(find.text('已划线'), findsOneWidget);

    final span = tester
        .widget<Text>(find.byKey(const ValueKey('reader-paragraph-0')))
        .textSpan!;
    expect(span.style?.decoration, TextDecoration.underline);

    // The sheet now offers to undo it.
    await _longPressParagraph(tester, 0);
    expect(find.text('取消划线'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
    await tester.pumpAndSettle();
    expect(store.entries, isEmpty);
    expect(find.text('已取消划线'), findsOneWidget);
  });

  testWidgets('从本段听 opens the listening page for this chapter', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_MemoryUnderlines()));
    await tester.pumpAndSettle();

    await _longPressParagraph(tester, 1);
    await tester.tap(find.byKey(const ValueKey('reader-action-listen')));
    await tester.pumpAndSettle();

    // The listening page is pushed on top of the reader for this chapter.
    expect(find.byType(AudioPage), findsOneWidget);
    final audio = tester.widget<AudioPage>(find.byType(AudioPage));
    expect(audio.bookId, 'reader-test');
    // Listening is per chapter, so the reader hands over the chapter it is on.
    expect(audio.startIndex, 0);
    expect(audio.chapters.first.itemId, 'c1');
    expect(audio.chapters, hasLength(2));
    // Paragraph 1 carries `<span start_time="4200">`, so playback starts there
    // instead of at the chapter's opening.
    expect(audio.startPosition, const Duration(milliseconds: 4200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a paragraph without a timeline starts at the chapter opening', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_MemoryUnderlines()));
    await tester.pumpAndSettle();

    // Paragraph 0 has no `<span start_time>`. This is still a paragraph-anchored
    // request, so it carries an explicit zero: falling back to null would resume
    // saved history instead of starting the chapter at its opening.
    await _longPressParagraph(tester, 0);
    await tester.tap(find.byKey(const ValueKey('reader-action-listen')));
    await tester.pumpAndSettle();

    final audio = tester.widget<AudioPage>(find.byType(AudioPage));
    expect(audio.startPosition, Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a cache written before the timeline is refetched only when asked to listen',
    (tester) async {
      final cache = MemoryChapterCache();
      cache.content['reader-test'] = {'c1': _legacyHtml()};
      // Only c1 matters: _prefetchAround warms neighbouring chapters, so the
      // plain request count would not prove anything about this chapter.
      final requests = <String>[];
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'reader-test',
            title: '测试书籍',
            chapters: _chapters,
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            chapterCache: cache,
            chapterLoader: (chapter) async {
              requests.add(chapter.itemId);
              return parseChapterContent(_html).toCacheText();
            },
            underlineStore: _MemoryUnderlines(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Reading old text must never wait on the timeline: the cached chapter is
      // used as-is, so no request is made for it.
      expect(requests.where((id) => id == 'c1'), isEmpty);
      expect(
        find.textContaining('“对不起......”', findRichText: true),
        findsOneWidget,
      );

      await _longPressParagraph(tester, 1);
      await tester.tap(find.byKey(const ValueKey('reader-action-listen')));
      await tester.pumpAndSettle();

      // Asking to listen from a paragraph pays for the timeline exactly once,
      // and the resulting position comes from the freshly parsed chapter.
      expect(requests.where((id) => id == 'c1'), hasLength(1));
      final audio = tester.widget<AudioPage>(find.byType(AudioPage));
      expect(audio.startPosition, const Duration(milliseconds: 4200));
      expect(tester.takeException(), isNull);
    },
  );

  test('underline keys separate chapters and paragraphs', () {
    expect(
      ReaderUnderlineStore.keyFor(
        bookId: 'b',
        chapterId: 'c1',
        paraIndex: 3,
        blockIndex: 3,
      ),
      isNot(
        ReaderUnderlineStore.keyFor(
          bookId: 'b',
          chapterId: 'c2',
          paraIndex: 3,
          blockIndex: 3,
        ),
      ),
    );
    // Ordinal identity is used only when the paragraph has no upstream id.
    expect(
      ReaderUnderlineStore.keyFor(bookId: 'b', chapterId: 'c1', blockIndex: 4),
      isNot(
        ReaderUnderlineStore.keyFor(
          bookId: 'b',
          chapterId: 'c1',
          blockIndex: 5,
        ),
      ),
    );
  });
}
