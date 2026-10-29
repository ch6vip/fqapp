import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_narration_visibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReaderChapterLayout layout;
  setUp(() {
    layout = ReaderChapterLayout(
      title: 'Title',
      content: ChapterContent.fromPlainText(
        List.filled(
          30,
          'A paragraph with enough words to wrap across several lines.',
        ).join('\n'),
      ),
      spec: ReaderLayoutSpec(
        viewport: const Size(320, 480),
        textScaler: TextScaler.noScaling,
        fontFamily: null,
        preferences: const ReaderPreferences(),
      ),
    );
  });

  bool visible(
    (int, int)? range, {
    int page = 0,
    double? scroll,
    double? height,
  }) => readerNarrationOnScreen(
    layout: layout,
    range: range,
    paged: scroll == null,
    pageIndex: page,
    scrollOffset: scroll,
    viewportHeight: height ?? layout.spec.viewport.height,
  );

  test(
    'paged ranges are half open and an end page is not the last text page',
    () {
      final first = layout.pages.first;
      final second = layout.pages[1];
      expect(visible((first.start, first.end)), isTrue);
      expect(visible((second.start, second.end)), isFalse);
      expect(visible((second.start, second.end), page: 1), isTrue);
      expect(
        visible((
          layout.pages.last.start,
          layout.textLength,
        ), page: layout.pages.length),
        isFalse,
      );
      expect(visible(null), isFalse);
      expect(visible((4, 4)), isFalse);
    },
  );

  test(
    'scroll visibility uses the viewport rather than a stale page index',
    () {
      final block = layout.blocks[16];
      final range = (block.start, block.end);
      final scroll = layout.spec.verticalPadding + block.top;
      expect(visible(range, page: 0, scroll: 0), isFalse);
      expect(visible(range, page: 0, scroll: scroll), isTrue);
      expect(visible(range, page: layout.pages.length, scroll: scroll), isTrue);
      expect(visible(range, scroll: scroll + block.height), isFalse);
    },
  );

  test(
    'a partially clipped highlighted line counts but touching an edge does not',
    () {
      final block = layout.blocks[8];
      final line = block.lines.first;
      final range = (block.start + line.start, block.start + line.end);
      final top = layout.spec.verticalPadding + block.top + line.top;
      final bottom = layout.spec.verticalPadding + block.top + line.bottom;
      expect(visible(range, scroll: top - 100, height: 100), isFalse);
      expect(visible(range, scroll: top - 99, height: 100), isTrue);
      expect(visible(range, scroll: bottom - 1, height: 100), isTrue);
      expect(visible(range, scroll: bottom, height: 100), isFalse);
    },
  );

  test('padding and trailing footer space are not highlighted text', () {
    final last = layout.blocks.last;
    expect(
      visible(
        (last.start, last.end),
        scroll: layout.spec.verticalPadding + last.top + last.height,
        height: 200,
      ),
      isFalse,
    );
    expect(
      visible(
        (0, layout.textLength),
        scroll: 0,
        height: layout.spec.verticalPadding,
      ),
      isFalse,
    );
    expect(visible((0, layout.textLength), scroll: 0, height: 0), isFalse);
  });
}
