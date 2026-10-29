import '../models/audio_time_track.dart';

/// 把「正文某一段」落到 `/timepoints` 时间轴上的起播毫秒。
///
/// 时间轴里的 `AudioSyncPoint.startPara` 是上游段号，而正文有两种来源：
///
/// * 带 `<p idx="N">` 的标记章节 —— 段号（[paraIndex]）直接可对；
/// * 纯文本章节（`/api/content`，一个 id 都不带）—— 只能按段序对。
///
/// 后者「标题算不算第 0 段」各家书源口径不一，所以两个口径都试一遍：先
/// [ordinal]（标题不计入），再 `ordinal + 1`（标题占第 0 段）。都对不上返回
/// null，调用方落回章首——错位的时间轴比没有更糟，宁可从头播。
int? startMsForParagraph(
  AudioTimeTrack track, {
  int? paraIndex,
  required int ordinal,
}) {
  if (track.isEmpty) return null;
  // 同一段会有多个点（按句切），起播只要最早的那个：points 已按时间升序。
  final starts = <int, int>{};
  for (final point in track.points) {
    if (!point.isBody) continue;
    starts.putIfAbsent(point.startPara, () => point.startTime);
  }
  if (starts.isEmpty) return null;
  if (paraIndex != null) {
    final exact = starts[paraIndex];
    if (exact != null) return exact;
  }
  if (ordinal < 0) return null;
  return starts[ordinal] ?? starts[ordinal + 1];
}
