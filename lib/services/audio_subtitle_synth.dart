import '../models/audio_extra.dart';
import '../models/audio_time_track.dart';

/// 在没有服务端文稿时，用章节正文 + 已有时轴反推一条**近似**字幕轨。
///
/// 背景：官方的字幕来自 TTS 合成时一并产出的时间轴
/// （`api/novel/audio/speech/text/v1`，每行形如 `[3025,0]<3025,0,0>对不起`，
/// 开头即该句起始毫秒）。没有那次合成的书就没有时间轴，官方直接 `gone`。
/// 这里给这类书补一条估算轨，代价是可能与声音差半句。
///
/// 精度分两档：
/// * 有 `/timepoints`（音频毫秒 → 段落 + 字符偏移）且段号能对上时，把字符
///   偏移换算成时间再切句，误差通常在 1 秒内；
/// * 没有可用锚点时，按字符数把句子均摊到 `[0, duration]`。
class SubtitleSynthesis {
  const SubtitleSynthesis._();

  /// 单句最长字符数：过长的句子按次要标点再切，免得一行显示不完。
  static const int maxSentenceChars = 60;

  /// 句末标点（中英文）。
  static final RegExp _sentenceEnd = RegExp(r'[。！？!?…]+');

  /// 右引号/右括号：应当跟在句末标点后面，而不是另起一句。
  static const String _closingQuotes = '”’」』）)]}';

  /// 长句的次要切点；保留原字符，不把 `：`/`；` 改写成 `，`。
  static const String _softChars = '，,、；;：:';

  /// 用 [text] 和 [duration] 合成一条字幕轨。
  ///
  /// [anchors] 为空或与正文对不上时自动退回均摊。
  static SubtitleTrack build({
    required String text,
    required Duration duration,
    AudioTimeTrack? anchors,
  }) {
    final sentences = splitSentences(text);
    if (sentences.isEmpty || duration <= Duration.zero) {
      return SubtitleTrack.empty;
    }
    // 每句在整篇里的起始字符偏移，供锚点插值使用。
    final offsets = <int>[];
    var cursor = 0;
    for (final sentence in sentences) {
      offsets.add(cursor);
      cursor += sentence.length;
    }
    final totalChars = cursor;
    if (totalChars <= 0) return SubtitleTrack.empty;

    final anchorPairs = _anchorPairs(text, anchors);
    final durationMs = duration.inMilliseconds;

    final cues = <SubtitleCue>[];
    var lastMs = -1;
    for (var i = 0; i < sentences.length; i++) {
      final startMs = anchorPairs.isEmpty
          ? (durationMs * offsets[i] / totalChars).round()
          : _msAtOffset(anchorPairs, offsets[i], durationMs, totalChars);
      // 单调递增：锚点插值理论上已保证，这里再兜一道，避免时间轴倒流。
      final clamped = startMs < lastMs ? lastMs : startMs;
      cues.add(SubtitleCue(startMs: clamped, text: sentences[i]));
      lastMs = clamped;
    }
    return SubtitleTrack(cues);
  }

  /// 按句末标点切句；过长的句子在次要标点处再切。
  ///
  /// 句末标点的连续串（`……`、`？！”`）连同右引号留在同一句里，
  /// 否则 `……` 会被拆成两段、`」` 会跑到下一句开头。
  static List<String> splitSentences(String text) {
    final out = <String>[];
    final buffer = StringBuffer();
    var pendingEnd = false;

    void flush() {
      final value = buffer.toString().trim();
      buffer.clear();
      pendingEnd = false;
      if (value.isEmpty) return;
      _splitLong(value, out);
    }

    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '\n' || ch == '\r') {
        flush();
        continue;
      }
      if (pendingEnd) {
        if (_sentenceEnd.hasMatch(ch) || _closingQuotes.contains(ch)) {
          buffer.write(ch);
          continue;
        }
        flush();
      }
      buffer.write(ch);
      if (_sentenceEnd.hasMatch(ch)) pendingEnd = true;
    }
    flush();
    return out;
  }

  /// 把超过 [maxSentenceChars] 的句子在次要标点处切开，分隔符留在前一段。
  static void _splitLong(String value, List<String> out) {
    if (value.length <= maxSentenceChars) {
      out.add(value);
      return;
    }
    final chunk = StringBuffer();
    var start = 0;
    for (var i = 0; i < value.length; i++) {
      if (!_softChars.contains(value[i])) continue;
      final candidate = value.substring(start, i + 1);
      if (chunk.isNotEmpty &&
          chunk.length + candidate.length > maxSentenceChars) {
        out.add(chunk.toString());
        chunk.clear();
      }
      chunk.write(candidate);
      start = i + 1;
    }
    final rest = value.substring(start);
    if (chunk.isNotEmpty && chunk.length + rest.length > maxSentenceChars) {
      out.add(chunk.toString());
      chunk.clear();
    }
    chunk.write(rest);
    final tail = chunk.toString();
    if (tail.isNotEmpty) out.add(tail);
  }

  /// 把 `/timepoints` 的「段落 + 段内偏移」换算成「整篇字符偏移 → 毫秒」。
  ///
  /// `AudioSyncPoint.startPara` 是上游 `<p idx>` 的段号，**不是**显示行序；
  /// 而 `contentText` 会丢掉空段落。所以只有段号恰好铺满 `0..段数-1` 时才敢
  /// 按行序使用，否则返回空表（调用方退回均摊）——错位的时间轴比没有更糟。
  static List<({int offset, int ms})> _anchorPairs(
    String text,
    AudioTimeTrack? anchors,
  ) {
    if (anchors == null || anchors.isEmpty) return const [];
    final paragraphs = text.replaceAll('\r\n', '\n').split('\n');
    final starts = <int>[];
    var acc = 0;
    for (final paragraph in paragraphs) {
      starts.add(acc);
      // +1 补回被切掉的换行，保证偏移落在同一篇文本上。
      acc += paragraph.length + 1;
    }
    final body = [
      for (final point in anchors.points)
        if (!point.isTitle) point,
    ];
    if (body.isEmpty) return const [];
    // 双射检查：锚点覆盖的段号集合必须恰好是 `0..段数-1`。只比最大值不够——
    // `contentText` 丢掉一个空段后段号会出现洞（如 0,2），按行序用仍会错位。
    final paras = body.map((point) => point.startPara).toSet();
    if (paras.length != paragraphs.length || !paras.contains(0)) {
      return const [];
    }

    final pairs = <({int offset, int ms})>[];
    for (final point in body) {
      final para = point.startPara;
      if (para < 0 || para >= starts.length) continue;
      // 段内偏移夹到本段长度，避免越界后静默落进后一段。
      final offset =
          starts[para] + point.startParaOff.clamp(0, paragraphs[para].length);
      if (offset < 0 || offset > text.length) continue;
      final previous = pairs.isEmpty ? null : pairs.last;
      if (previous != null &&
          (offset <= previous.offset || point.startTime < previous.ms)) {
        continue;
      }
      pairs.add((offset: offset, ms: point.startTime));
    }
    return pairs;
  }

  /// 在锚点之间线性插值；落在首/尾锚点之外则按均摊比例外推。
  static int _msAtOffset(
    List<({int offset, int ms})> pairs,
    int offset,
    int durationMs,
    int totalChars,
  ) {
    if (pairs.isEmpty) return (durationMs * offset / totalChars).round();
    final first = pairs.first;
    if (offset <= first.offset) {
      final ratio = first.offset == 0 ? 0.0 : offset / first.offset;
      return (first.ms * ratio).round().clamp(0, durationMs);
    }
    for (var i = 1; i < pairs.length; i++) {
      final previous = pairs[i - 1];
      final current = pairs[i];
      if (offset > current.offset) continue;
      final span = current.offset - previous.offset;
      if (span <= 0) return current.ms;
      final ratio = (offset - previous.offset) / span;
      return (previous.ms + (current.ms - previous.ms) * ratio).round();
    }
    // 超过最后一个锚点：从它按剩余字符比例外推到总时长。
    final last = pairs.last;
    final remainingChars = totalChars - last.offset;
    final remainingMs = durationMs - last.ms;
    if (remainingChars <= 0 || remainingMs <= 0) {
      return last.ms.clamp(0, durationMs);
    }
    final ratio = (offset - last.offset) / remainingChars;
    return (last.ms + remainingMs * ratio).round().clamp(0, durationMs);
  }
}
