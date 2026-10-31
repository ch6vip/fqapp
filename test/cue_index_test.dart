import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/cue_index.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ReaderChapterLayout layoutWith(List<String> paragraphs) =>
      ReaderChapterLayout(
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
    final layout = layoutWith(['他骗了未婚妻，伪造了公司流水。', '这件事只有他一个人知道。', '后来他开了电视。']);
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
    final layout = layoutWith(['他说。然后是一段沉默。', '他说。后面这句才是第二句。']);
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
    final layout = layoutWith(['他停了停，扇子在胸口点了两下。', '上辈子的古人说，一饮一啄。']);
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
    final layout = layoutWith(['他把电视打开，屏幕上一片雪白', '的信号在跳，像是谁在敲门。']);
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

  testWidgets('冒号与分号也算句读边界，标点归属前一片', (tester) async {
    const body = '“别啊！”陈青源赶紧说着：“那些家伙不可能与我同境界一战，那就是欺负人。”';
    final layout = layoutWith([body]);
    final track = SubtitleTrack([SubtitleCue(startMs: 0, text: body)]);

    final index = CueIndex.build(layout: layout, track: track);
    final block = layout.blocks[1];
    final pieces = index.spans
        .map(
          (s) =>
              block.text.substring(s.start - block.start, s.end - block.start),
        )
        .toList();

    // 标点（含收尾引号）跟着前一片走：`！”` 不该被拆到下一句开头。
    expect(pieces, contains('“别啊！”'));
    expect(pieces, contains('陈青源赶紧说着：'));
    expect(pieces.first, startsWith('“别啊！”'));
    expect(pieces.any((p) => p.endsWith('，')), isTrue, reason: '逗号同样收在前一片末尾');
  });

  testWidgets('没有字幕时不建表', (tester) async {
    final layout = layoutWith(['正文。']);
    final index = CueIndex.build(layout: layout, track: SubtitleTrack.empty);
    expect(index.isEmpty, isTrue);
    expect(index.spanAtPositionMs(0), isNull);
    expect(index.spanAtChar(0), isNull);
  });

  testWidgets('字幕与正文标点写法不同时，高亮落在句读边界而不是字中间', (tester) async {
    const body = '“镇压……召唤……”他嘴唇哆嗦着，“那……那它在召唤什么？被它镇压的，又是什么？”';
    final layout = layoutWith([body]);
    // 字幕把省略号写成半角三点、丢掉了引号：精确匹配必然失败，只能走剥噪兜底。
    final track = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '镇压...召唤...他嘴唇哆嗦着，那...那它在召唤什么？被它镇压的，又是什么？'),
      SubtitleCue(startMs: 12000, text: '下一句。'),
    ]);

    final index = CueIndex.build(layout: layout, track: track);
    final block = layout.blocks[1];
    final pieces = index.spans.where((s) => s.cueIndex == 0).toList();
    expect(pieces.length, greaterThan(2), reason: '剥噪命中同样要按标点拆片');

    final boundary = RegExp(r'[，、。！？…—：；”’」』）】]');
    for (final span in pieces) {
      final tail = block.text[span.end - 1 - block.start];
      expect(
        boundary.hasMatch(tail) || span.end == block.end,
        isTrue,
        reason: '片尾「$tail」不是句读边界，高亮会在句子中间截断',
      );
    }
    // 片与片的接续必须严丝合缝，没有跳空也没有重叠。
    for (var i = 1; i < pieces.length; i++) {
      expect(pieces[i].start, pieces[i - 1].end);
    }
    // 省略号处停顿更久，该片拿到的时长必须明显大于同字数的普通片。
    final ellipsis = pieces.first;
    expect(ellipsis.endMs - ellipsis.startMs, greaterThan(500));
  });

  testWidgets('自然播放跨到下一句时先多留上一句，越界才切', (tester) async {
    final layout = layoutWith(['第一句在开头。', '第二句在后面。']);
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 1000, text: '第一句在开头。'),
        SubtitleCue(startMs: 4000, text: '第二句在后面。'),
      ]),
    );
    final first = index.spans[0];
    final shown = (first.start, first.end);
    // 屏幕上正亮着上一句 —— 这是自然播放走到边界的特征，此时才保持。
    expect(
      index
          .spanAtPositionMs(4000, crossCueHoldMs: 200, currentRange: shown)
          ?.cueIndex,
      0,
    );
    expect(
      index
          .spanAtPositionMs(4199, crossCueHoldMs: 200, currentRange: shown)
          ?.cueIndex,
      0,
    );
    expect(
      index
          .spanAtPositionMs(4200, crossCueHoldMs: 200, currentRange: shown)
          ?.cueIndex,
      1,
    );
  });

  testWidgets('目标句已是当前高亮时，跨 cue 保持不会把它退回上一句', (tester) async {
    final layout = layoutWith(['第一句在开头。', '第二句在后面。']);
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 1000, text: '第一句在开头。'),
        SubtitleCue(startMs: 4000, text: '第二句在后面。'),
      ]),
    );
    final second = index.spans[1];
    // 双击跳读会先把高亮设成目标句，于是「当前显示 = 目标句」直接胜出。
    expect(
      index
          .spanAtPositionMs(
            4000,
            crossCueHoldMs: 200,
            currentRange: (second.start, second.end),
          )
          ?.cueIndex,
      1,
      reason: '双击落在目标句起点，绝不能因为保持而退回上一句',
    );
  });

  testWidgets('同一句内部的子片切换不吃跨 cue 保持', (tester) async {
    const body = '他骗了未婚妻，伪造了公司流水，还偷偷把房子卖了。';
    final layout = layoutWith([body]);
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 0, text: body),
        SubtitleCue(startMs: 9000, text: '下一句。'),
      ]),
    );
    final pieces = index.spans.where((s) => s.cueIndex == 0).toList();
    expect(pieces.length, greaterThan(1));
    final first = pieces[0];
    final second = pieces[1];
    expect(
      index
          .spanAtPositionMs(
            second.startMs,
            crossCueHoldMs: 200,
            currentRange: (first.start, first.end),
          )
          ?.start,
      second.start,
      reason: '同一条 cue 内的子片必须按时间轴准点切，不能层层延迟',
    );
  });

  testWidgets('长 cue 的每一片都有保底停留', (tester) async {
    const body = '他骗了未婚妻，伪造了公司流水，还偷偷把房子卖了。';
    final layout = layoutWith([body]);
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 0, text: body),
        SubtitleCue(startMs: 10000, text: '下一句。'),
      ]),
    );
    final pieces = index.spans.where((s) => s.cueIndex == 0).toList();
    expect(pieces.length, greaterThan(1));
    for (final piece in pieces) {
      expect(
        piece.endMs - piece.startMs,
        greaterThanOrEqualTo(CueIndex.pieceBaseMs),
        reason: '尾片也不能只剩几十毫秒',
      );
    }
    for (var i = 1; i < pieces.length; i++) {
      expect(pieces[i].startMs, pieces[i - 1].endMs, reason: '片间不能有空洞或重叠');
    }
    expect(pieces.last.endMs, 10000);
  });

  testWidgets('整条 cue 太短时退成均分，不撑出边界', (tester) async {
    const body = '他骗了未婚妻，伪造了公司流水，还偷偷把房子卖了。';
    final layout = layoutWith([body]);
    // 这段正文按标点拆成 3 片，每片 140ms 保底共需 420ms，这里只给 300ms。
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 0, text: body),
        SubtitleCue(startMs: 300, text: '下一句。'),
      ]),
    );
    final pieces = index.spans.where((s) => s.cueIndex == 0).toList();
    expect(pieces.length, greaterThan(1));
    for (var i = 1; i < pieces.length; i++) {
      expect(pieces[i].startMs, pieces[i - 1].endMs);
    }
    expect(pieces.first.startMs, 0);
    expect(pieces.last.endMs, 300, reason: '均分也不能越过 cue 边界');
    final durations = pieces.map((p) => p.endMs - p.startMs).toList();
    expect(
      durations.reduce((a, b) => a > b ? a : b) -
          durations.reduce((a, b) => a < b ? a : b),
      lessThanOrEqualTo(1),
      reason: '退成均分后各片时长应基本相等',
    );
  });

  testWidgets('按段查首个片：整段都是上一段续行时返回 null', (tester) async {
    final layout = layoutWith(['第一段文字。', '第二段文字。']);
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 0, text: '第一段文字。'),
        SubtitleCue(startMs: 5000, text: '第二段文字。'),
      ]),
    );
    final first = layout.blocks[1];
    final second = layout.blocks[2];
    expect(index.firstSpanIn(first.start, first.end)?.cueIndex, 0);
    expect(index.firstSpanIn(second.start, second.end)?.cueIndex, 1);
    // 空区间 = 没有「从段内起」的片，调用方应改走段落锚。
    expect(index.firstSpanIn(first.end, first.end), isNull);
  });

  testWidgets('段间空隙不会把上一段当成双击目标', (tester) async {
    final layout = layoutWith(['第一段文字。', '第二段文字。']);
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 0, text: '第一段文字。'),
        SubtitleCue(startMs: 5000, text: '第二段文字。'),
      ]),
    );
    final first = layout.blocks[1];
    final second = layout.blocks[2];
    // 段内：正常命中本段。
    expect(
      index.spanAtCharIn(second.start, second.start, second.end)?.cueIndex,
      1,
    );
    // 段间空隙：spanAtChar 的既有语义是「返回前一句」，这里必须被重叠校验挡掉，
    // 否则双击第二段会亮第一段 —— 就是实测那个「点了这句、亮的是上一句」。
    expect(index.spanAtChar(first.end)?.cueIndex, 0, reason: '底层语义不变');
    expect(index.spanAtCharIn(first.end, second.start, second.end), isNull);
  });

  testWidgets('顿号不算句读边界：并列短语不会被拆成三字一片', (tester) async {
    const body = '修行之道，划分为：后天境、先天境、黄灵境、玄灵境、地灵境、天灵境。';
    final layout = layoutWith([body]);
    final index = CueIndex.build(
      layout: layout,
      track: SubtitleTrack([
        SubtitleCue(startMs: 0, text: body),
        SubtitleCue(startMs: 9000, text: '下一句。'),
      ]),
    );
    final block = layout.blocks[1];
    final pieces = index.spans.where((s) => s.cueIndex == 0).toList();
    expect(pieces.length, greaterThan(1), reason: '按逗号/冒号/句号仍要拆');

    for (final piece in pieces) {
      final text = block.text.substring(
        piece.start - block.start,
        piece.end - block.start,
      );
      expect(
        text.endsWith('、'),
        isFalse,
        reason: '片尾「$text」是顿号：并列短语被逐词切开了，高亮会跳得极碎',
      );
      expect(
        text.length,
        greaterThan(3),
        reason: '片「$text」太短，多半是按顿号切碎了',
      );
    }
  });
}
