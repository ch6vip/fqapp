import '../../models/audio_extra.dart';
import 'reader_chapter_layout.dart';

/// 字幕里的一句，在正文中的落点。
///
/// 坐标是「章节显示文本」下标（与 [ReaderChapterLayout] 的
/// `ReaderContentBlock.start` 同一套），不是页面下标，所以跨页、跨段都对得上。
class CueSpan {
  const CueSpan({
    required this.start,
    required this.end,
    required this.cueIndex,
    required this.startMs,
    required this.endMs,
  });

  /// 正文起点（含）。
  final int start;

  /// 正文终点（不含）。
  final int end;

  /// 在 [SubtitleTrack.cues] 里的序号。
  final int cueIndex;

  /// 这句开始的媒体时间（毫秒）。
  final int startMs;

  /// 这句结束的媒体时间（毫秒）。最后一句由
  /// [SubtitleTrack.endMsAt] 估出来，不是精确值。
  final int endMs;

  Duration get startPosition => Duration(milliseconds: startMs);

  /// 播到 [ms] 时，这一句里**已经读到**的正文位置（布局下标）。
  ///
  /// 不是句首，而是句内插值：一句跨页时，读到后半句的那一刻屏幕就该翻到下一
  /// 页。时间轴已经给了这句的起止，插值不需要估语速。
  int spokenOffset(int ms) {
    if (endMs <= startMs) return start;
    final t = ((ms - startMs) / (endMs - startMs)).clamp(0.0, 1.0);
    final spanLen = end - start;
    if (spanLen <= 1) return start;
    // 收在最后一个字上：t=1 时若直接取 end，那是排版的开区间端点，会被算进
    // 下一页，正好在「这句读完的瞬间」翻错。
    final advance = (spanLen * t).floor().clamp(0, spanLen - 1);
    return start + advance;
  }

  @override
  String toString() =>
      'CueSpan[$start,$end) cue=$cueIndex $startMs→$endMs';
}

/// 「正文字符位置 ↔ 音频时间」对照表。
///
/// 字幕和正文来自同一次朗读，顺序天然一致，所以建表用**顺序扫描**：游标只往
/// 前走，找到一句就把游标推到它的末尾。全文搜索做不到这一点 —— 后面某句完全
/// 可能先匹配到前面出现过的相同短片段，一旦错位，高亮和跟随就整体歪掉，而现
/// 象看上去只是「有点不准」，很难定位。
///
/// 三个功能共用这张表：句高亮、跟随翻页、双击跳读。换章时建一次，之后按时间
/// 或按字符位置二分查找。
class CueIndex {
  const CueIndex._(this.spans);

  /// 空表（无字幕的书）。
  static const empty = CueIndex._([]);

  /// 按时间升序排列，可能比字幕条数少 —— 对不上正文的句子不会进表。
  final List<CueSpan> spans;

  bool get isEmpty => spans.isEmpty;
  bool get isNotEmpty => spans.isNotEmpty;

  /// 字幕与正文之间可以忽略的字符：标点与空白。
  ///
  /// 两边常在全/半角、省略号写法上不一致，精确匹配失败后要剥掉这些再比一次。
  static final RegExp cueNoise = RegExp(
    r'[\s，。！？；：、“”‘’（）《》〈〉…—·,.!?;:"()\[\]{}]',
  );

  /// 用 [layout] 的正文块顺序去匹配 [track] 的每一句。
  factory CueIndex.build({
    required ReaderChapterLayout layout,
    required SubtitleTrack track,
  }) {
    if (track.isEmpty) return empty;

    // 把正文块拼成一整条字符串，并记下每个字符对应的布局下标。
    // 拼接之后 `indexOf` 可以跨段落命中 —— 一句朗读跨两段是常态。
    final text = StringBuffer();
    final origin = <int>[];
    for (var i = 1; i < layout.blocks.length; i++) {
      final block = layout.blocks[i];
      if (block.isImage || block.text.isEmpty) continue;
      final base = block.start;
      for (var c = 0; c < block.text.length; c++) {
        text.write(block.text[c]);
        origin.add(base + c);
      }
    }
    if (origin.isEmpty) return empty;
    final combined = text.toString();

    // 剥噪版：只留实字，同样记一份原串下标。
    final strippedText = StringBuffer();
    final strippedOrigin = <int>[];
    for (var k = 0; k < combined.length; k++) {
      final ch = combined[k];
      if (cueNoise.hasMatch(ch)) continue;
      strippedText.write(ch);
      strippedOrigin.add(origin[k]);
    }
    final stripped = strippedText.toString();

    final spans = <CueSpan>[];
    // 游标：上一句命中的正文终点。下一句只能从这里往后找。
    var lastEnd = 0;
    for (var i = 0; i < track.cues.length; i++) {
      final needle = track.cues[i].text.trim();
      if (needle.isEmpty) continue;

      var start = -1;
      var end = -1;

      final at = combined.indexOf(needle, _atOrAfter(origin, lastEnd));
      if (at >= 0) {
        start = origin[at];
        end = origin[at + needle.length - 1] + 1;
      } else {
        final bare = needle.replaceAll(cueNoise, '');
        if (bare.isNotEmpty) {
          final at2 = stripped.indexOf(
            bare,
            _atOrAfter(strippedOrigin, lastEnd),
          );
          if (at2 >= 0) {
            start = strippedOrigin[at2];
            end = strippedOrigin[at2 + bare.length - 1] + 1;
          }
        }
      }
      if (start < 0 || end <= start) continue;
      // 单调性保险：命中必须在上一次之后，否则宁可丢掉这句。
      if (start < lastEnd) continue;
      lastEnd = end;
      spans.add(
        CueSpan(
          start: start,
          end: end,
          cueIndex: i,
          startMs: track.cues[i].startMs,
          endMs: track.endMsAt(i),
        ),
      );
    }
    return CueIndex._(spans);
  }

  /// [sorted] 里第一个 >= [value] 的下标（找不到返回长度）。
  ///
  /// [origin] 是按布局位置递增的映射表，用它把「布局下标游标」换算成「拼接串
  /// 下标游标」，不必两头各维护一套游标。
  static int _atOrAfter(List<int> sorted, int value) {
    if (sorted.isEmpty) return 0;
    var low = 0;
    var high = sorted.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (sorted[mid] < value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 播放到 [ms] 时应该亮起的句子：起点不晚于它的最后一句。
  ///
  /// 这一句如果因为标点差异没能对上正文，会退回到上一句 —— 比整页变黑好。
  /// 返回 null 表示播放位置还在第一句之前。
  CueSpan? spanAtPositionMs(int ms) {
    if (spans.isEmpty) return null;
    var low = 0;
    var high = spans.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (spans[mid].startMs <= ms) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found < 0 ? null : spans[found];
  }

  /// 正文 [offset] 处属于哪一句（双击跳读用）。
  ///
  /// 落在两句之间的空隙（段落间距）时算作前一句 —— 用户点的通常就是眼前那段
  /// 文字，而空隙两侧的文字他分辨不出差别。第一个字符之前算第一句。
  CueSpan? spanAtChar(int offset) {
    if (spans.isEmpty) return null;
    var low = 0;
    var high = spans.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (spans[mid].start <= offset) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found < 0 ? spans.first : spans[found];
  }
}
