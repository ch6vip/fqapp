import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/widgets/reader/reader_joined_chapter_end.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';

void main() {
  testWidgets('chapter comments fit the measured footer with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const ideas = ChapterIdeas(
      paragraphs: [ParagraphIdeas(paraIndex: 10000, count: 12)],
    );
    for (final scale in [1.0, 2.0, 3.0]) {
      final scaler = TextScaler.linear(scale);
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: scaler),
            child: Scaffold(
              body: SizedBox(
                width: 280,
                height: ReaderJoinedChapterEnd.height(scaler, true),
                child: ReaderJoinedChapterEnd(
                  index: 0,
                  ideas: ideas,
                  onComments: () => opened = true,
                ),
              ),
            ),
          ),
        ),
      );
      final comments = find.byKey(
        const ValueKey('reader-joined-chapter-comments-0'),
      );
      expect(
        tester.getBottomLeft(comments).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('本章完')).dy),
      );
      await tester.tap(comments);
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(tester.takeException(), isNull, reason: 'text scale $scale');
    }
  });

  testWidgets('prepending a chapter preserves the very first painted frame', (
    tester,
  ) async {
    final previous = Completer<JoinedReaderChapter>();
    final controller = ScrollController();
    final key = GlobalKey<ReaderJoinedScrollState>();
    final chapters = List.generate(3, _chapter);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: ReaderJoinedScroll(
            key: key,
            controller: controller,
            index: 1,
            chapter: chapters[1],
            chapterCount: 3,
            loader: (index, _) =>
                index == 0 ? previous.future : Future.value(chapters[index]),
            onPosition: (_) {},
            onDragStart: () {},
            blockBuilder: (index, layout, block) => ReaderBlockText(
              key: ValueKey('chapter-$index-block-${block.index}'),
              block: block,
              spec: layout.spec,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    controller.jumpTo(180);
    await tester.pump();
    final marker = find.byKey(
      (tester.widgetList<ReaderBlockText>(find.byType(ReaderBlockText)).first)
          .key!,
    );
    final before = tester.getTopLeft(marker);
    previous.complete(chapters[0]);
    await tester.pump();
    // Check before another frame can hide a post-frame jumpTo correction.
    expect(tester.getTopLeft(marker), before);
    expect(
      controller.offset,
      closeTo(key.currentState!.chapterStart(1) + 180, .01),
    );
    await tester.pump();
    expect(tester.getTopLeft(marker), before);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

JoinedReaderChapter _chapter(int index) {
  final text = List.generate(
    35,
    (i) => '章节 $index 段落 $i：保持文字的位置。',
  ).join('\n\n');
  final content = ChapterContent.fromCacheText(text);
  final spec = ReaderLayoutSpec(
    viewport: const Size(400, 600),
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  return JoinedReaderChapter(
    text,
    content,
    null,
    ReaderChapterLayout(title: '章节 $index', content: content, spec: spec),
    ideas: const ChapterIdeas(
      paragraphs: [ParagraphIdeas(paraIndex: 10000, count: 12)],
    ),
  );
}
