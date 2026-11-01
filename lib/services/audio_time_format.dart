/// 听书页专用的时长文案。
///
/// 共用的 `formatPlaybackTime` 会把 75 分 30 秒写成 `75:30`（分钟位一直进位），
/// 那是视频进度条的既有语义。听书进度药丸需要小时位，因此单独一份格式化，
/// 满一小时时输出 `H:MM:SS`，不足一小时仍是 `MM:SS`。
String formatAudioTime(Duration value, {bool withHours = false}) {
  final seconds = value.inSeconds.clamp(0, 0x7fffffff);
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  String two(int part) => part.toString().padLeft(2, '0');
  if (withHours || hours > 0) {
    return '$hours:${two(minutes)}:${two(secs)}';
  }
  return '${two(minutes)}:${two(secs)}';
}

/// 进度药丸的 `当前/总时长`。
///
/// 总时长满一小时时两端都带小时位，避免出现 `1:02:05/59:30` 这种一宽一窄
/// 的混排。
String formatAudioProgress(Duration position, Duration duration) {
  final withHours = duration.inSeconds >= 3600;
  return '${formatAudioTime(position, withHours: withHours)}/'
      '${formatAudioTime(duration, withHours: withHours)}';
}
