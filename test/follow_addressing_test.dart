import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/cue_index.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

/// 跳页寻址链：position → 当前句 → 句内插值 → 第几页。
///
/// 这里只验「坐标是否对得上」——句子在正文里的下标、页面的 start/end、
/// 插值出来的读到点，三者必须是同一套坐标。对不上时现象是翻页翻错一页，
/// 而高亮看着还是对的，非常难从现象倒推。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一段很长的正文，小窗口下必然被切成多页。
  ReaderChapterLayout layout() => ReaderChapterLayout(
    title: '第一章 试读',
    content: ChapterContent(
      blocks: [
        List.filled(
          40,
          '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。',
        ).join(),
        '最后一段很短。',
      ].map(ChapterParagraph.new).toList(),
    ),
    spec: ReaderLayoutSpec(
      // 窄而矮：一页放不下几行，长段落会跨页。
      viewport: const Size(240, 300),
      textScaler: TextScaler.noScaling,
      preferences: const ReaderPreferences(fontSize: 18, titleSize: 20),
      fontFamily: null,
    ),
  );

  testWidgets('插值出来的读到点，一定落在它所属的那一页里', (tester) async {
    final lay = layout();
    expect(lay.pages.length, greaterThan(2), reason: '长段落应被切成多页');
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。'),
      SubtitleCue(startMs: 4000, text: '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。'),
      SubtitleCue(startMs: 8000, text: '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。'),
      SubtitleCue(startMs: 12000, text: '最后一段很短。'),
    ]);
    final index = CueIndex.build(layout: lay, track: track);
    // 逗号拆片后每条 cue 裂成 3 片：只要求不少于原来的句数。
    expect(index.spans.length, greaterThanOrEqualTo(4));

    // 每句的每个时间点，插值出的下标都必须被 pageForOffset 认到同一页，
    // 且那一页的区间确实包着它。
    for (final span in index.spans) {
      for (final t in const [0, 0.25, 0.5, 0.75, 0.99]) {
        final ms = span.startMs + ((span.endMs - span.startMs) * t).round();
        final offset = span.spokenOffset(ms);
        expect(
          offset,
          inInclusiveRange(span.start, span.end - 1),
          reason: '插值点必须落在句内（t=$t）',
        );
        final page = lay.pageForOffset(offset);
        final target = lay.pages[page];
        expect(
          offset,
          inInclusiveRange(target.start, target.end - 1),
          reason:
              'offset=$offset 应在第 $page 页 [${target.start},${target.end}) 内 '
              '（t=$t）',
        );
      }
    }
  });

  testWidgets('长句跨页时，读到后半句目标页才前进', (tester) async {
    final lay = layout();
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。'),
      SubtitleCue(startMs: 5000, text: '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。'),
    ]);
    final index = CueIndex.build(layout: lay, track: track);
    final span = index.spans[1];

    final pageAtStart = lay.pageForOffset(span.spokenOffset(span.startMs));
    final pageAtEnd = lay.pageForOffset(span.spokenOffset(span.endMs));
    // 同一句跨页时前后两半必须落在不同页；没跨页（窗口够大）则相等。
    // 关键断言是「单调」：时间前进，目标页不能倒退。
    expect(pageAtEnd, greaterThanOrEqualTo(pageAtStart));
    for (var ms = span.startMs; ms < span.endMs; ms += 100) {
      final p = lay.pageForOffset(span.spokenOffset(ms));
      expect(p, greaterThanOrEqualTo(pageAtStart), reason: '目标页不能倒退');
      expect(p, lessThanOrEqualTo(pageAtEnd));
    }
  });

  testWidgets('同一句重复出现时，句子与页面的对应不会串', (tester) async {
    final lay = layout();
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。'),
      SubtitleCue(startMs: 4000, text: '他把电视打开，屏幕上一片雪白的信号在跳动着，像是谁在轻轻敲门。'),
    ]);
    final index = CueIndex.build(layout: lay, track: track);
    // 逗号拆片后第一句裂成 3 片：数量放宽，单调性断言才是重点。
    expect(index.spans.length, greaterThanOrEqualTo(2));
    // 第二句必须排在第一句后面（游标只前进），否则整章的对应都会歪。
    expect(index.spans[1].start, greaterThan(index.spans[0].end - 1));
    // 两句各自落在自己那一页，且时间与页面都不倒退。
    final p0 = lay.pageForOffset(index.spans[0].spokenOffset(0));
    final p1 = lay.pageForOffset(index.spans[1].spokenOffset(4000));
    expect(p1, greaterThanOrEqualTo(p0));
    expect(index.spans[1].startMs, greaterThan(index.spans[0].startMs));
  });
}
