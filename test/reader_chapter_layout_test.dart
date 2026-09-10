import 'package:flutter/material.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in [
    (size: const Size(350, 640), scale: 1.0, font: 18.0, spacing: 12.0),
    (size: const Size(260, 430), scale: 2.0, font: 32.0, spacing: 32.0),
    (size: const Size(740, 180), scale: 1.4, font: 24.0, spacing: 0.0),
    (size: const Size(240, 85), scale: 2.5, font: 32.0, spacing: 32.0),
  ]) {
    test('pages preserve every character and full line: $scenario', () {
      final layout = _layout(
        title: List.filled(12, '第一章 山间来信').join(' '),
        size: scenario.size,
        scale: scenario.scale,
        preferences: ReaderPreferences(
          fontSize: scenario.font,
          paragraphSpacing: scenario.spacing,
          titleAlignment: ReaderTitleAlignment.center,
        ),
      );
      expect(layout.pages.length, greaterThan(1));
      for (final block in layout.blocks) {
        final fragments = layout.pages
            .expand((p) => p.fragments)
            .where((fragment) => identical(fragment.block, block))
            .toList();
        expect(fragments.map((f) => f.text).join(), block.text);
        final boundaries = <int>{0};
        var offset = 0;
        for (final grapheme in block.text.characters) {
          boundaries.add(offset += grapheme.length);
        }
        for (final fragment in fragments) {
          expect(boundaries, contains(fragment.start - block.start));
          expect(boundaries, contains(fragment.end - block.start));
          expect(fragment.height, greaterThan(0));
          expect(fragment.sourceTop, greaterThanOrEqualTo(0));
          expect(
            fragment.sourceTop + fragment.height,
            lessThanOrEqualTo(block.height + .001),
          );
        }
      }
      var previousEnd = 0;
      for (var i = 0; i < layout.pages.length; i++) {
        final page = layout.pages[i];
        expect(page.fragments, isNotEmpty);
        expect(page.start, greaterThanOrEqualTo(previousEnd));
        previousEnd = page.end;
        expect(layout.pageForOffset(page.start), i);
        if (page.height > layout.spec.pageHeight + .001) {
          expect(page.fragments, hasLength(1));
          expect(
            page.fragments.single.firstLine,
            page.fragments.single.lastLine,
          );
        }
        var bottom = 0.0;
        for (final fragment in page.fragments) {
          expect(fragment.top, greaterThanOrEqualTo(bottom - .001));
          bottom = fragment.top + fragment.height;
        }
      }
      expect(layout.pages.last.end, layout.textLength);
    });
  }

  testWidgets('measurement matches rendered indentation, wrapping and height', (
    tester,
  ) async {
    final layout = _layout(scale: 1.3, size: const Size(360, 600));
    final block = layout.blocks[1];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            child: SizedBox(
              width: layout.spec.width,
              child: ReaderBlockText(block: block, spec: layout.spec),
            ),
          ),
        ),
      ),
    );
    final render = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(ReaderBlockText),
        matching: find.byType(RichText),
      ),
    );
    expect(render.size.height, closeTo(block.height, .01));
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: 1, extentOffset: block.text.length + 1),
    );
    expect(boxes.first.left, closeTo(18 * 1.3 * 2, .01));
    expect(boxes[1].left, closeTo(0, .01));
    for (final line in block.lines) {
      final actual = render.getPositionForOffset(
        Offset(0, (line.top + line.bottom) / 2),
      );
      expect(actual.offset - 1, inInclusiveRange(line.start - 1, line.end));
    }
    expect(tester.takeException(), isNull);
  });

  test('an absent chapter title never creates a blank page', () {
    final layout = _layout(title: '', size: const Size(240, 85), scale: 2.5);
    expect(layout.pages.first.start, 0);
    for (final page in layout.pages) {
      expect(
        page.fragments.map((fragment) => fragment.text).join(),
        isNotEmpty,
      );
    }
  });

  for (final size in [
    const Size(390, 760),
    const Size(760, 190),
    const Size(240, 85),
  ]) {
    test('illustrations stay whole and ordered in $size', () {
      final content = ChapterContent(
        blocks: const [
          ChapterParagraph('图前正文。'),
          ChapterImage(url: 'https://images.test/a', width: 1400, height: 2100),
          ChapterImage(url: 'https://images.test/a', width: 1400, height: 2103),
          ChapterParagraph('图后正文。'),
          ChapterImage(
            url: 'https://images.test/wide',
            width: 600,
            height: 100,
          ),
          ChapterImage(url: 'https://images.test/unknown'),
        ],
      );
      final layout = _layout(content: content, size: size);
      final fragments = layout.pages.expand((page) => page.fragments).toList();
      final images = fragments.where((f) => f.block.isImage).toList();
      expect(images.map((f) => f.block.illustration), content.images);
      for (final image in images) {
        expect(image.firstLine, 0);
        expect(image.lastLine, 0);
        expect(image.end - image.start, 1);
        expect(image.height, lessThanOrEqualTo(layout.spec.pageHeight));
        final page = layout.pages[layout.pageForOffset(image.start)];
        expect(page.height, lessThanOrEqualTo(layout.spec.pageHeight + .001));
      }
      for (var i = 1; i < images.length; i++) {
        expect(images[i].start, greaterThan(images[i - 1].end));
      }
      expect(
        fragments.where((f) => !f.block.isImage).map((f) => f.text).join(),
        layout.blocks.where((b) => !b.isImage).map((b) => b.text).join(),
      );
    });
  }

  test('image-only chapter without a title has no phantom top spacing', () {
    final layout = _layout(
      title: '',
      content: ChapterContent(
        blocks: const [
          ChapterImage(
            url: 'https://images.test/tall',
            width: 100,
            height: 900,
          ),
        ],
      ),
    );
    expect(layout.pages, hasLength(1));
    expect(layout.pages.single.fragments.single.top, 0);
    expect(layout.pages.single.height, layout.spec.pageHeight);
    expect(layout.blocks.last.top, 0);
    expect(
      layout.contentHeight,
      layout.spec.pageHeight + layout.spec.paragraphSpacing,
    );
    expect(layout.textLength, 1);
  });

  test('v1 text anchors migrate across inline and consecutive pictures', () {
    const title = '第一章';
    const html =
        '<p>第一章</p><p>开头。</p>'
        '<p>图片之前<img src="https://images.test/a">图片之后继续阅读。</p>'
        '<img src="https://images.test/a"><img src="https://images.test/b">'
        '<p>这段正文在所有插图后面。</p>';
    final original = _layout(
      title: title,
      content: ChapterContent.fromPlainText(normalizeChapterText(html)),
    );
    final illustrated = _layout(
      title: title,
      content: parseChapterContent(html),
    );
    for (final text in ['图片之后继续阅读。', '这段正文在所有插图后面。']) {
      final oldBlock = original.blocks.firstWhere((b) => b.text.contains(text));
      final newBlock = illustrated.blocks.firstWhere((b) => b.text == text);
      final oldOffset = oldBlock.start + oldBlock.text.indexOf(text) + 3;
      final restored = illustrated.restore(
        {'chapterId': 'c', 'positionVersion': 1, 'textOffset': oldOffset},
        chapterId: 'c',
        startAtEnd: false,
        paged: true,
      );
      expect(restored.textOffset, newBlock.start + 3);
      expect(illustrated.legacyOffsetForText(restored.textOffset), oldOffset);
    }
  });

  test('v2 picture anchors survive rotation and changing reading mode', () {
    final content = ChapterContent(
      blocks: [
        for (var i = 0; i < 3; i++)
          ChapterImage(
            url: 'https://images.test/$i',
            width: 1400,
            height: 2100,
          ),
        const ChapterParagraph('插图后的正文。'),
      ],
    );
    final original = _layout(content: content);
    final landscape = _layout(content: content, size: const Size(740, 250));
    for (final image in original.blocks.where((block) => block.isImage)) {
      final restored = landscape.restore(
        {'chapterId': 'c', 'positionVersion': 2, 'textOffset': image.start},
        chapterId: 'c',
        startAtEnd: false,
        paged: false,
      );
      expect(restored.textOffset, image.start);
      expect(landscape.textOffsetAtScroll(restored.scroll + .001), image.start);
      final page =
          landscape.pages[landscape.pageForOffset(restored.textOffset)];
      expect(
        page.fragments.single.block.illustration?.url,
        image.illustration!.url,
      );
    }
  });

  test(
    'text positions survive different page sizes, fonts and scroll mode',
    () {
      final original = _layout();
      final changed = _layout(
        size: const Size(720, 250),
        scale: 1.5,
        preferences: const ReaderPreferences(fontSize: 27, lineHeight: 2.1),
      );
      expect(original.pages.length, isNot(changed.pages.length));
      for (final page in original.pages.skip(1)) {
        final anchor = page.start;
        final restored = changed.restore(
          {
            'kind': 'book',
            'chapterId': 'chapter',
            'positionVersion': 1,
            'textOffset': anchor,
            'position': 0,
          },
          chapterId: 'chapter',
          startAtEnd: false,
          paged: true,
        );
        expect(restored.textOffset, anchor);
        final target = changed.pages[changed.pageForOffset(anchor)];
        expect(target.start, lessThanOrEqualTo(anchor));
        expect(target.end, greaterThanOrEqualTo(anchor));
        final restoredLine = changed.textOffsetAtScroll(restored.scroll);
        expect(restoredLine, lessThanOrEqualTo(anchor));
      }
    },
  );

  test(
    'distant scroll positions map to the same text line without estimates',
    () {
      final layout = _layout();
      for (final block in layout.blocks) {
        for (final line in block.lines) {
          final anchor = block.start + line.start;
          final scroll = layout.scrollForTextOffset(anchor);
          if (scroll == layout.maxScroll) continue;
          expect(layout.textOffsetAtScroll(scroll + .001), anchor);
        }
      }
    },
  );

  test('legacy history migrates by ratio and ignores other chapters/media', () {
    final layout = _layout();
    final saved = <String, dynamic>{
      'chapterId': 123,
      'position': 300.0,
      'maxScroll': 900.0,
    };
    final migrated = layout.restore(
      saved,
      chapterId: '123',
      startAtEnd: false,
      paged: true,
    );
    expect(migrated.scroll, closeTo(layout.maxScroll / 3, .001));
    expect(migrated.textOffset, greaterThan(0));
    for (final entry in [
      {...saved, 'chapterId': 'other'},
      {...saved, 'kind': 'audio'},
    ]) {
      expect(
        layout.restore(entry, chapterId: '123', startAtEnd: false, paged: true),
        (textOffset: 0, scroll: 0.0),
      );
    }
    final end = layout.restore(
      saved,
      chapterId: '123',
      startAtEnd: true,
      paged: true,
    );
    expect(end.textOffset, layout.pages.last.start);
  });

  test(
    'corrupt positions fall back safely and future versions use old fields',
    () {
      final layout = _layout();
      for (final value in [null, '42', -10, 1.5, double.nan, double.infinity]) {
        final restored = layout.restore(
          {
            'chapterId': 'chapter',
            'positionVersion': 1,
            'textOffset': value,
            'position': 30,
            'maxScroll': 100,
          },
          chapterId: 'chapter',
          startAtEnd: false,
          paged: true,
        );
        expect(restored.scroll, closeTo(layout.maxScroll * .3, .001));
      }
      final future = layout.restore(
        {
          'chapterId': 'chapter',
          'positionVersion': 99,
          'textOffset': 20,
          'position': double.infinity,
        },
        chapterId: 'chapter',
        startAtEnd: false,
        paged: true,
      );
      expect(future, (textOffset: 0, scroll: 0.0));
      final end = layout.restore(
        {'chapterId': 'chapter', 'positionVersion': 1, 'textOffset': 1e100},
        chapterId: 'chapter',
        startAtEnd: false,
        paged: true,
      );
      expect(end.textOffset, layout.textLength);
    },
  );

  testWidgets('a text line taller than the window remains scrollable', (
    tester,
  ) async {
    final layout = _layout(
      size: const Size(240, 85),
      scale: 2.5,
      preferences: const ReaderPreferences(fontSize: 32, titleSize: 40),
    );
    final page = layout.pages.first;
    expect(page.height, greaterThan(layout.spec.pageHeight));
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: layout.spec.viewport,
            child: ReaderPageContent(page: page, spec: layout.spec),
          ),
        ),
      ),
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -50));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}

ReaderChapterLayout _layout({
  String title = '第一章 山间来信',
  Size size = const Size(350, 640),
  double scale = 1,
  ReaderPreferences preferences = const ReaderPreferences(),
  ChapterContent? content,
}) => ReaderChapterLayout(
  title: title,
  content:
      content ??
      ChapterContent(
        blocks: [
          List.filled(12, '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。').join(),
          List.filled(
            6,
            'Hello 👩🏽‍🚀👨‍👩‍👧‍👦 e\u0301 🇨🇳 — العربية，\u00a0保留空格。',
          ).join(' '),
          List.filled(
            10,
            'Short words, verylongwordwithoutanybreaks0123456789。',
          ).join(' '),
          '完。',
        ].map(ChapterParagraph.new).toList(),
      ),
  spec: ReaderLayoutSpec(
    viewport: size,
    textScaler: TextScaler.linear(scale),
    preferences: preferences,
    fontFamily: null,
  ),
);
