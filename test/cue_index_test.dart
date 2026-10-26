import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/cue_index.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ReaderChapterLayout layoutWith(List<String> paragraphs) => ReaderChapterLayout(
    title: '第一章 试读',
    content: ChapterContent(
      blocks: paragraphs.map(ChapterParagraph.new).toList(),
    ),
    spec: ReaderLayoutSpec(
      viewport: const Size(350, 640),
      textScaler: TextScaler.noScaling,
      preferences: const ReaderPreferences(),
      fontFamily: null,
    ),
  );

  testWidgets('按顺序把每句字幕映射到正文，区间与时间都对得上', (tester) async {
    final layout = layoutWith([
      '他骗了未婚妻，伪造了公司流水。',
      '这件事只有他一个人知道。',
      '后来他开了电视。',
    ]);
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '他骗了未婚妻，伪造了公司流水。'),
      SubtitleCue(startMs: 3200, text: '这件事只有他一个人知道。'),
      SubtitleCue(startMs: 6100, text: '后来他开了电视。'),
    ]);

    final index = CueIndex.build(layout: layout, track: track);

    expect(index.spans, hasLength(3));
    for (var i = 0; i < index.spans.length; i++) {
      final span = index.spans[i];
      final block = layout.blocks[i + 1];
      expect(span.cueIndex, i);
      expect(span.start, block.start);
      expect(span.end, block.end);
      expect(span.startMs, track.cues[i].startMs);
    }
    // 结束时间来自下一句的起点。
    expect(index.spans[0].endMs, 3200);
    expect(index.spans[1].endMs, 6100);
  });

  testWidgets('同一句重复出现时游标只前进，不会跳回前面的段', (tester) async {
    final layout = layoutWith([
      '他说。然后是一段沉默。',
      '他说。后面这句才是第二句。',
    ]);
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '他说。'),
      SubtitleCue(startMs: 900, text: '他说。'),
      SubtitleCue(startMs: 1800, text: '后面这句才是第二句。'),
    ]);

    final index = CueIndex.build(layout: layout, track: track);

    expect(index.spans.length, greaterThanOrEqualTo(2));
    expect(index.spans[0].start, layout.blocks[1].start);
    // 第二句必须落在第二段，不能又命中第一段的「他说。」
    expect(index.spans[1].start, layout.blocks[2].start);
    expect(index.spans[1].start, greaterThan(index.spans[0].end - 1));
  });

  testWidgets('字幕与正文标点不一致时剥掉标点仍能对上', (tester) async {
    final layout = layoutWith([
      '他停了停，扇子在胸口点了两下。',
      '上辈子的古人说，一饮一啄。',
    ]);
    final track = SubtitleTrack([
      // 字幕省了标点，正文有逗号和句号：精确匹配必然失败。
      SubtitleCue(startMs: 0, text: '他停了停扇子在胸口点了两下'),
      SubtitleCue(startMs: 2500, text: '上辈子的古人说，一饮一啄。'),
    ]);

    final index = CueIndex.build(layout: layout, track: track);

    expect(index.spans, hasLength(2));
    expect(index.spans[0].start, layout.blocks[1].start);
    expect(index.spans[1].start, layout.blocks[2].start);
  });

  testWidgets('一句跨两段也能给出完整区间', (tester) async {
    final layout = layoutWith([
      '他把电视打开，屏幕上一片雪白',
      '的信号在跳，像是谁在敲门。',
    ]);
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '他把电视打开，屏幕'),
      // 这句的后半落在下一段：只有把正文拼接起来才能整句命中。
      SubtitleCue(startMs: 1200, text: '上一片雪白的信号在跳，像是谁在敲门。'),
    ]);

    final index = CueIndex.build(layout: layout, track: track);

    expect(index.spans, hasLength(2));
    final span = index.spans[1];
    expect(span.start, layout.blocks[1].start + '他把电视打开，屏幕'.length);
    expect(span.end, layout.blocks[2].end);
  });

  testWidgets('按时间取当前句：第一句之前返回 null，之后取最后一句', (tester) async {
    final layout = layoutWith(['第一句在开头。', '第二句在后面。']);
    final track = SubtitleTrack([
      SubtitleCue(startMs: 1000, text: '第一句在开头。'),
      SubtitleCue(startMs: 4000, text: '第二句在后面。'),
    ]);
    final index = CueIndex.build(layout: layout, track: track);

    expect(index.spanAtPositionMs(0), isNull);
    expect(index.spanAtPositionMs(1000)?.cueIndex, 0);
    expect(index.spanAtPositionMs(3999)?.cueIndex, 0);
    expect(index.spanAtPositionMs(4000)?.cueIndex, 1);
    expect(index.spanAtPositionMs(99999)?.cueIndex, 1);
  });

  testWidgets('按字符取句：点在句内取该句，点在段间空隙取前一句', (tester) async {
    final layout = layoutWith(['第一句在开头。', '第二句在后面。']);
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '第一句在开头。'),
      SubtitleCue(startMs: 2000, text: '第二句在后面。'),
    ]);
    final index = CueIndex.build(layout: layout, track: track);

    final first = index.spans[0];
    final second = index.spans[1];
    expect(index.spanAtChar(first.start)?.cueIndex, 0);
    expect(index.spanAtChar(first.end - 1)?.cueIndex, 0);
    expect(index.spanAtChar(second.start)?.cueIndex, 1);
    expect(index.spanAtChar(second.end - 1)?.cueIndex, 1);
    // 章节最开头（标题块）算第一句；最后一句之后仍算最后一句。
    expect(index.spanAtChar(0)?.cueIndex, 0);
    expect(index.spanAtChar(second.end + 50)?.cueIndex, 1);
  });

  testWidgets('句内按时间插值出正在读的位置', (tester) async {
    final layout = layoutWith(['第一句在开头。', '第二句在后面。']);
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '第一句在开头。'),
      SubtitleCue(startMs: 2000, text: '第二句在后面。'),
    ]);
    final index = CueIndex.build(layout: layout, track: track);
    final span = index.spans[0];
    final len = span.end - span.start;

    expect(span.spokenOffset(0), span.start);
    expect(span.spokenOffset(1000), span.start + len ~/ 2);
    // 读完的瞬间停在这句最后一个字，不能落到下一句的开头。
    expect(span.spokenOffset(2000), span.end - 1);
    // 位置戳越界时夹在句内。
    expect(span.spokenOffset(-5), span.start);
    expect(span.spokenOffset(99999), span.end - 1);
  });

  testWidgets('没有字幕时不建表', (tester) async {
    final layout = layoutWith(['正文。']);
    final index = CueIndex.build(layout: layout, track: SubtitleTrack.empty);
    expect(index.isEmpty, isTrue);
    expect(index.spanAtPositionMs(0), isNull);
    expect(index.spanAtChar(0), isNull);
  });
}
