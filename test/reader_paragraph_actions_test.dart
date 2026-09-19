import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_paragraph_menu.dart';
import 'package:fqapp/widgets/reader/reader_text_selection.dart';


import 'support/fakes.dart';

const _html =
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">“对不起......”</p><p></p>'
    '<p idx="1"><span start_time="4200">“老子是兔子啊！”</span></p><p></p>'
    '</article>';

/// A paragraph long enough to wrap, followed by another one — the shape the
/// official cross-boundary drag scenarios need (行尾气泡区、拖过段界).
const _longHtml =
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">前十八年，叶望川还以为自己只是普普通通穿越到了一个富人家，略有些钱而已。</p>'
    '<p idx="1">虽然没有系统和金手指啥的，但生活过得也算逍遥自在。</p>'
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

/// In-memory 划线 box so the tests never touch Hive. Both record shapes
/// share the entry map; each load filters for its own.
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
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) async => [
    for (final raw in entries.values)
      if (ReaderRangeUnderline.fromMap(raw)
          case final ReaderRangeUnderline entry
          when entry.bookId == bookId && entry.chapterId == chapterId)
        entry,
  ]..sort((a, b) => a.start.compareTo(b.start));

  @override
  Future<void> add(ReaderUnderline underline) async {
    entries[underline.key] = underline.toMap();
  }

  @override
  Future<void> addRange(ReaderRangeUnderline underline) async {
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

/// Drags the end handle into the next paragraph with two slop-crossing
/// steps — a single small move never leaves the pan slop, so the selection
/// would not update at all.
Future<void> _dragEndHandleIntoNextParagraph(WidgetTester tester) async {
  final center = tester.getCenter(
    find.byKey(const ValueKey('reader-selection-handle-end')),
  );
  final gesture = await tester.startGesture(center);
  await gesture.moveBy(const Offset(0, 30));
  await gesture.moveBy(const Offset(0, 30));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The mark painter of the block whose text contains [textHint].
ReaderBlockMarkPainter? _painterFor(WidgetTester tester, String textHint) {
  for (final custom
      in tester.widgetList<CustomPaint>(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is ReaderBlockMarkPainter,
        ),
      )) {
    final painter = custom.painter! as ReaderBlockMarkPainter;
    if (painter.block.text.contains(textHint)) return painter;
  }
  return null;
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
        MaterialApp(
          home: ReaderParagraphMenu(isDark: dark, onAction: (_) {}),
        ),
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

  testWidgets('long press selects the paragraph with wash and handles', (
    tester,
  ) async {
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    const startHandle = ValueKey('reader-selection-handle-start');
    const endHandle = ValueKey('reader-selection-handle-end');
    expect(find.byKey(startHandle), findsNothing);
    expect(find.byKey(endHandle), findsNothing);

    await _longPressParagraph(tester, 0);
    expect(find.byKey(startHandle), findsOneWidget);
    expect(find.byKey(endHandle), findsOneWidget);
    // The whole first paragraph is selected: its mark layer carries the wash.
    final layer = tester
        .widgetList<ReaderBlockMarkLayer>(find.byType(ReaderBlockMarkLayer))
        .first;
    expect(layer.selection, isNotNull);
    expect(layer.selection!.start, layer.block.start);
    expect(layer.selection!.end, layer.block.end);
    expect(layer.selection!.isWholeParagraph, isTrue);

    // Dismissing the bar cancels the selection, like the official unselect.
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();
    expect(find.byKey(startHandle), findsNothing);
    expect(find.byKey(endHandle), findsNothing);
  });

  testWidgets('paged mode floats the handles too', (tester) async {
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

    expect(
      find.byKey(const ValueKey('reader-selection-handle-start')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-selection-handle-end')),
      findsOneWidget,
    );
    expect(
      tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).selection,
      isNotNull,
    );
  });

  testWidgets('dragging the end handle reshapes the selection and the bar', (
    tester,
  ) async {
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

    const full = '“对不起......”';
    await _longPressParagraph(tester, 0);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsOneWidget);

    // Pull the end handle into the next paragraph: the selection grows past
    // its paragraph, and the bar reopens without 从本段听 (a dragged range
    // cannot anchor it).
    await _dragEndHandleIntoNextParagraph(tester);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsNothing);
    expect(find.byKey(const ValueKey('reader-action-copy')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-action-copy')));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect(copied.single.length, greaterThan(full.length));
    expect(copied.single.startsWith(full), isTrue);
  });

  testWidgets('划线 on a dragged selection saves a range record, deletable', (
    tester,
  ) async {
    final store = _MemoryUnderlines();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    Future<List<ReaderRangeUnderline>> savedRanges() async => [
      for (final raw in store.entries.values)
        ?ReaderRangeUnderline.fromMap(raw),
    ];

    await _longPressParagraph(tester, 0);
    await _dragEndHandleIntoNextParagraph(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
    await tester.pumpAndSettle();

    final ranges = await savedRanges();
    expect(ranges, hasLength(1));
    expect(ranges.single.text.length, greaterThan('“对不起......”'.length));
    // The action consumed the selection: handles are gone.
    expect(
      find.byKey(const ValueKey('reader-selection-handle-start')),
      findsNothing,
    );

    // The same selection now offers 删除划线 and removes the record.
    await _longPressParagraph(tester, 0);
    await _dragEndHandleIntoNextParagraph(tester);
    await tester.pumpAndSettle();
    expect(find.text('删除划线'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
    await tester.pumpAndSettle();
    expect(await savedRanges(), isEmpty);
    // The paragraph record space stays untouched by range operations.
    expect(store.entries, isEmpty);
  });

  test('range underline records keep their own key space', () {
    const bookId = 'b';
    const chapterId = 'c1';
    final record = ReaderRangeUnderline(
      bookId: bookId,
      chapterId: chapterId,
      start: 3,
      end: 9,
      text: '样本文字',
    );
    // Range keys never collide with the 4-tuple paragraph keys, and the two
    // map shapes reject each other so one box can hold both.
    expect(
      record.key,
      isNot(
        ReaderUnderlineStore.keyFor(
          bookId: bookId,
          chapterId: chapterId,
          paraIndex: 0,
          blockIndex: 0,
        ),
      ),
    );
    expect(ReaderUnderline.fromMap(record.toMap()), isNull);
    expect(
      ReaderRangeUnderline.fromMap(
        const ReaderUnderline(
          bookId: bookId,
          chapterId: chapterId,
          blockIndex: 0,
          text: '整段',
        ).toMap(),
      ),
      isNull,
    );
    final decoded = ReaderRangeUnderline.fromMap(record.toMap())!;
    expect(decoded.start, 3);
    expect(decoded.end, 9);
    expect(decoded.coversExactly(3, 9), isTrue);
    expect(decoded.coversExactly(3, 10), isFalse);
    expect(decoded.contains(4, 8), isTrue);
    expect(decoded.contains(2, 9), isFalse);
    // Malformed or half-shaped maps never resurrect a record.
    expect(ReaderRangeUnderline.fromMap(<String, dynamic>{}), isNull);
    expect(
      ReaderRangeUnderline.fromMap({
        ...record.toMap(),
        'end': 2,
      }),
      isNull,
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

  test('withBound never collapses to an empty selection', () {
    const paragraph = ReaderTextSelection(start: 0, end: 36);
    // Exact hit on the opposite bound pins one character — it used to produce
    // start == end and wipe the whole selection mid-drag.
    expect(
      paragraph.withBound(isStart: true, offset: 36, textLength: 61),
      const ReaderTextSelection(start: 36, end: 37),
    );
    // Past the bound swaps the range, like a native selection.
    expect(
      paragraph.withBound(isStart: true, offset: 40, textLength: 61),
      const ReaderTextSelection(start: 36, end: 40),
    );
    // Pinning at the very end of the chapter falls back to the last character.
    const tail = ReaderTextSelection(start: 0, end: 61);
    expect(
      tail.withBound(isStart: true, offset: 61, textLength: 61),
      const ReaderTextSelection(start: 60, end: 61),
    );
    expect(
      const ReaderTextSelection(
        start: 40,
        end: 61,
      ).withBound(isStart: false, offset: 40, textLength: 61),
      const ReaderTextSelection(start: 39, end: 40),
    );
    expect(
      tail.withBound(isStart: false, offset: 0, textLength: 61),
      const ReaderTextSelection(start: 0, end: 1),
    );
  });

  // The 官方 native update always answers with a non-empty range, so a drag
  // onto the opposite bound must pin the selection, never wipe it.
  testWidgets('dragging a handle onto the opposite bound pins one character', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_MemoryUnderlines(), html: _longHtml));
    await tester.pumpAndSettle();

    await _longPressParagraph(tester, 0);
    final start = tester.getCenter(
      find.byKey(const ValueKey('reader-selection-handle-start')),
    );
    // The end of the wrapped paragraph's last line: the offset under the
    // finger lands exactly on the selection's end bound — the old collapse.
    final line = tester.getRect(find.byKey(const ValueKey('reader-paragraph-0')));
    final goal = Offset(line.right - 10, line.bottom - 8);
    final gesture = await tester.startGesture(start);
    for (var i = 1; i <= 12; i++) {
      await gesture.moveBy((goal - start) / 12);
      await tester.pump();
    }
    await tester.pump();

    // The drag crossed the bound: the selection survived, pinned onto the
    // next paragraph's first real character (the separator itself paints
    // nothing, so the guard grows it by one).
    expect(
      find.byKey(const ValueKey('reader-selection-handle-start')),
      findsOneWidget,
    );
    expect(_painterFor(tester, '虽然没有')!.selectionRange, const (0, 1));

    await gesture.up();
    await tester.pumpAndSettle();
    // A dragged range: the bar reopens without 从本段听.
    expect(find.byKey(const ValueKey('reader-action-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsNothing);
  });

  // 官方 TTMarkingHelper 的 MOVE 分支: after a long press the finger keeps
  // dragging without ever grabbing a handle; which bound follows it is the
  // half of the selection the finger is on.
  testWidgets('moving the finger after a long press drags without lifting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_MemoryUnderlines()));
    await tester.pumpAndSettle();

    final center = tester.getCenter(
      find.byKey(const ValueKey('reader-paragraph-0')),
    );
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 700));
    // Below the selection's vertical midpoint: the end bound follows, growing
    // into the next paragraph.
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();

    expect(_painterFor(tester, '老子')!.selectionRange, isNotNull);

    await gesture.up();
    await tester.pumpAndSettle();
    // The bar reopens at the finger for the dragged range.
    expect(find.byKey(const ValueKey('reader-action-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsNothing);
  });

  // 官方 ke5.a.a 的 SelectTextByRange 分支: long-pressing text that already
  // carries a range underline restores that exact range, not the paragraph.
  testWidgets('long-pressing a saved range underline restores its range', (
    tester,
  ) async {
    final store = _MemoryUnderlines();
    // Display text: "第一章\n前十八年…" — the paragraph starts at 4; cover its
    // first eight characters.
    final record = ReaderRangeUnderline(
      bookId: 'reader-test',
      chapterId: 'c1',
      start: 4,
      end: 12,
      text: '前十八年，叶望',
    );
    store.entries[record.key] = record.toMap();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store, html: _longHtml));
    await tester.pumpAndSettle();

    final line = tester.getRect(find.byKey(const ValueKey('reader-paragraph-0')));
    await tester.longPressAt(Offset(line.left + 20, line.top + 15));
    await tester.pumpAndSettle();

    expect(_painterFor(tester, '前十八年')!.selectionRange, const (0, 8));
    expect(find.text('删除划线'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-listen')), findsNothing);
  });

  // A range record that spans exactly one paragraph (a whole-paragraph drag)
  // must be toggled in the range store even though the selection restores as
  // a whole paragraph — the paragraph-identity route would strand it.
  testWidgets('a whole-paragraph range record stays deletable', (tester) async {
    final store = _MemoryUnderlines();
    // Display text: "第一章\n前十八年…" — paragraph 0 is [4, 40).
    final record = ReaderRangeUnderline(
      bookId: 'reader-test',
      chapterId: 'c1',
      start: 4,
      end: 40,
      text: '前十八年，叶望川还以为自己只是普普通通穿越到了一个富人家，略有些钱而已。',
    );
    store.entries[record.key] = record.toMap();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(store, html: _longHtml));
    await tester.pumpAndSettle();

    // The long press restores the exact range, which happens to be the whole
    // paragraph — the bar must still offer the undo action for the range
    // record (整段文案是取消划线,动作同为 removeUnderline).
    await _longPressParagraph(tester, 0);
    expect(find.text('取消划线'), findsOneWidget);
    expect(find.text('划线'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
    await tester.pumpAndSettle();
    // The range record is gone and no paragraph record was created or left.
    expect(store.entries, isEmpty);
  });
}
