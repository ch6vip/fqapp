import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_underline_store.dart';

import 'support/fakes.dart';

const _html =
    '<header><div class="tt-title">第一章</div></header><article>'
    '<p idx="0">“对不起......”</p><p></p>'
    '<p idx="1">“老子是兔子啊！”</p><p></p>'
    '</article>';

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

Widget _app(ReaderUnderlineStore store) => MaterialApp(
  home: ReaderPage(
    bookId: 'reader-test',
    title: '测试书籍',
    chapters: _chapters,
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: (_) async => parseChapterContent(_html).toCacheText(),
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
    expect(tester.takeException(), isNull);
  });

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
