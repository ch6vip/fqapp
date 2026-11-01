import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/services/audio_subtitle_synth.dart';

/// 服务端没有文稿时，用正文 + `/timepoints` 反推近似字幕轨。
///
/// 官方的时间轴是 TTS 合成时一并产出的（`speech/text` 每行 `[ms]<..>句`），
/// 没有那次合成的书官方就是空着。这里补的是估算，所以精度分两档：
/// 有锚点走插值，没有锚点按字符数均摊。
void main() {
  AudioTimeTrack trackOf(List<(int para, int off, int ms)> rows) =>
      AudioTimeTrack([
        for (final (para, off, ms) in rows)
          AudioSyncPoint(
            startTime: ms,
            startPara: para,
            startParaOff: off,
            endPara: para,
            endParaOff: off,
          ),
      ]);

  group('splitSentences', () {
    test('splits on Chinese sentence enders and newlines', () {
      final out = SubtitleSynthesis.splitSentences('第一句。第二句！第三句？\n第四句');
      expect(out, ['第一句。', '第二句！', '第三句？', '第四句']);
    });

    test('breaks an over-long sentence at commas', () {
      final long = '${'甲' * 40}，${'乙' * 40}，${'丙' * 40}。';
      final out = SubtitleSynthesis.splitSentences(long);
      expect(out.length, greaterThan(1));
      for (final line in out) {
        expect(
          line.length,
          lessThanOrEqualTo(SubtitleSynthesis.maxSentenceChars + 1),
        );
      }
    });

    test('keeps the original punctuation instead of rewriting it', () {
      // 「他说：」里的冒号不能被改写成逗号，否则正文语义被篡改。
      final out = SubtitleSynthesis.splitSentences('他说：走吧。然后呢；不知道。');
      expect(out.join(), contains('：'));
      expect(out.join(), contains('；'));
    });

    test('keeps an ellipsis run and following quote in one sentence', () {
      final out = SubtitleSynthesis.splitSentences('他愣住……「走吧。」她说。');
      // `……` 不能被切成两段，`」` 也不能被拎到下一句开头。
      expect(out.any((line) => line.contains('……')), isTrue);
      expect(out.any((line) => line.startsWith('」')), isFalse);
    });

    test('returns nothing for blank input', () {
      expect(SubtitleSynthesis.splitSentences('   \n\n '), isEmpty);
    });
  });

  group('build', () {
    const text = '第一句。第二句。第三句。第四句。';

    test('is empty without text or duration', () {
      expect(
        SubtitleSynthesis.build(text: '', duration: const Duration(minutes: 1)),
        SubtitleTrack.empty,
      );
      expect(
        SubtitleSynthesis.build(text: text, duration: Duration.zero),
        SubtitleTrack.empty,
      );
    });

    test('distributes sentences over the duration when there is no anchor', () {
      final track = SubtitleSynthesis.build(
        text: text,
        duration: const Duration(seconds: 100),
      );
      expect(track.cues, hasLength(4));
      expect(track.cues.first.startMs, 0);
      // 四句字数相同 → 起点应均匀落在 0/25/50/75 秒附近。
      expect(track.cues[1].startMs, closeTo(25000, 1500));
      expect(track.cues[2].startMs, closeTo(50000, 1500));
      expect(track.cues[3].startMs, closeTo(75000, 1500));
    });

    test('never lets the timeline run backwards', () {
      final track = SubtitleSynthesis.build(
        text: text,
        duration: const Duration(seconds: 100),
      );
      for (var i = 1; i < track.cues.length; i++) {
        expect(
          track.cues[i].startMs,
          greaterThanOrEqualTo(track.cues[i - 1].startMs),
        );
      }
    });

    test('uses anchors to place sentences on the real timeline', () {
      // 单段落，锚点把「第 0 字符 → 0ms」「第 16 字符 → 80s」钉住。
      const anchored = '第一句。第二句。第三句。第四句。';
      final track = SubtitleSynthesis.build(
        text: anchored,
        duration: const Duration(seconds: 100),
        anchors: trackOf([(0, 0, 0), (0, 16, 80000)]),
      );
      expect(track.cues, hasLength(4));
      // 第 4 句起点在 12/16 处 → 约 60 秒，而不是均摊的 75 秒。
      expect(track.cues[3].startMs, closeTo(60000, 4000));
    });

    test('refuses anchors whose paragraph ids leave holes', () {
      // 多段落 + 段号跳号：`contentText` 会丢空段落，此时按段号当行序
      // 会整章错位，必须退回均摊而不是硬用。
      final track = SubtitleSynthesis.build(
        text: '第一段。\n第二段。\n第三段。',
        duration: const Duration(seconds: 60),
        anchors: trackOf([(0, 0, 0), (2, 0, 30000)]),
      );
      expect(track.cues, hasLength(3));
      // 退回均摊：三句等分，第二句起点约 20 秒（而不是锚点插值的结果）。
      expect(track.cues[1].startMs, closeTo(20000, 4000));
    });

    test('ignores anchors that do not line up with the text', () {
      // 段落编号超出正文段落数 → 判定对不上，退回均摊。
      final track = SubtitleSynthesis.build(
        text: text,
        duration: const Duration(seconds: 100),
        anchors: trackOf([(99, 0, 0)]),
      );
      expect(track.cues, hasLength(4));
      expect(track.cues[1].startMs, closeTo(25000, 1500));
    });
  });

  group('rewrite equivalence', () {
    // 长章节：超过 isolateThreshold，覆盖后台 isolate 路径；里面混入
    // 代理对（😀）、连续标点、引号与多段落。
    final longChapter = [
      for (var i = 0; i < 260; i++) '第$i段：他说：“今天天气不错。”然后走了……「明天见！」她喊道😀！',
    ].join('\n');

    final corpus = <String>[
      '',
      '   \n\n ',
      '第一句。第二句！第三句？\n第四句',
      '他愣住……「走吧。」她说。',
      '连续标点？！？！”」』）)]}然后。',
      '行一\r\n行二\r行三\n\n行四。',
      '😀表情！😀😀？……「结束」',
      'a!b?c.',
      '${'甲' * 130}，${'乙' * 70}；${'丙' * 51}。',
      '他说：走吧。然后呢；不知道。',
      longChapter,
    ];

    test('splitSentences matches the pre-rewrite implementation', () {
      for (var i = 0; i < corpus.length; i++) {
        expect(
          SubtitleSynthesis.splitSentences(corpus[i]),
          referenceSplitSentences(corpus[i]),
          reason: 'corpus[$i]',
        );
      }
    });

    test('a long chapter splits identically off the UI isolate', () async {
      expect(
        longChapter.length,
        greaterThan(SubtitleSynthesis.isolateThreshold),
      );
      expect(
        await SubtitleSynthesis.splitSentencesAsync(longChapter),
        referenceSplitSentences(longChapter),
      );
    });

    test('buildAsync produces the same track as build', () async {
      final syncTrack = SubtitleSynthesis.build(
        text: longChapter,
        duration: const Duration(minutes: 30),
      );
      final asyncTrack = await SubtitleSynthesis.buildAsync(
        text: longChapter,
        duration: const Duration(minutes: 30),
      );
      expect(asyncTrack.cues.length, syncTrack.cues.length);
      for (var i = 0; i < syncTrack.cues.length; i++) {
        expect(asyncTrack.cues[i].startMs, syncTrack.cues[i].startMs);
        expect(asyncTrack.cues[i].text, syncTrack.cues[i].text);
      }
    });

    test('buildAsync keeps anchored timing for a short chapter', () async {
      const anchored = '第一句。第二句。第三句。第四句。';
      final anchors = trackOf([(0, 0, 0), (0, 16, 80000)]);
      final syncTrack = SubtitleSynthesis.build(
        text: anchored,
        duration: const Duration(seconds: 100),
        anchors: anchors,
      );
      final asyncTrack = await SubtitleSynthesis.buildAsync(
        text: anchored,
        duration: const Duration(seconds: 100),
        anchors: anchors,
      );
      expect(asyncTrack.cues.length, syncTrack.cues.length);
      for (var i = 0; i < syncTrack.cues.length; i++) {
        expect(asyncTrack.cues[i].startMs, syncTrack.cues[i].startMs);
        expect(asyncTrack.cues[i].text, syncTrack.cues[i].text);
      }
    });
  });
}

// 改写前的实现（逐 rune + 正则）留作等价性参照：只用于证明
// `SubtitleSynthesis.splitSentences` 的输出没有变化。
final RegExp _referenceSentenceEnd = RegExp(r'[。！？!?…]+');
const String _referenceClosingQuotes = '”’」』）)]}';
const String _referenceSoftChars = '，,、；;：:';
const int _referenceMaxSentenceChars = 60;

List<String> referenceSplitSentences(String text) {
  final out = <String>[];
  final buffer = StringBuffer();
  var pendingEnd = false;

  void flush() {
    final value = buffer.toString().trim();
    buffer.clear();
    pendingEnd = false;
    if (value.isEmpty) return;
    _referenceSplitLong(value, out);
  }

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '\n' || ch == '\r') {
      flush();
      continue;
    }
    if (pendingEnd) {
      if (_referenceSentenceEnd.hasMatch(ch) ||
          _referenceClosingQuotes.contains(ch)) {
        buffer.write(ch);
        continue;
      }
      flush();
    }
    buffer.write(ch);
    if (_referenceSentenceEnd.hasMatch(ch)) pendingEnd = true;
  }
  flush();
  return out;
}

void _referenceSplitLong(String value, List<String> out) {
  if (value.length <= _referenceMaxSentenceChars) {
    out.add(value);
    return;
  }
  final chunk = StringBuffer();
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    if (!_referenceSoftChars.contains(value[i])) continue;
    final candidate = value.substring(start, i + 1);
    if (chunk.isNotEmpty &&
        chunk.length + candidate.length > _referenceMaxSentenceChars) {
      out.add(chunk.toString());
      chunk.clear();
    }
    chunk.write(candidate);
    start = i + 1;
  }
  final rest = value.substring(start);
  if (chunk.isNotEmpty &&
      chunk.length + rest.length > _referenceMaxSentenceChars) {
    out.add(chunk.toString());
    chunk.clear();
  }
  chunk.write(rest);
  final tail = chunk.toString();
  if (tail.isNotEmpty) out.add(tail);
}
