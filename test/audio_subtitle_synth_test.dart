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
        expect(line.length, lessThanOrEqualTo(SubtitleSynthesis.maxSentenceChars + 1));
      }
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
}
