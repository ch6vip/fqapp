import 'package:flutter/foundation.dart';

/// 连播倒计时的秒数。
///
/// 官方是 `te`「%s后播放下一集」的可取消倒计时，具体秒数没有从资源里取到；
/// 这里取 3 秒：足够看清并点「取消」，又不会拖慢连续收听。
const int kAdvanceCountdownSeconds = 3;

/// 睡眠定时档位：关闭 / 听完本章 / N 分钟后，三者互斥。
///
/// 官方 `cip` = 「听完本章」，`doc` = 「剩余本章」，`dod` = 「剩余播放」——
/// 说明官方把「听到本章结束」和「按分钟倒计时」当成两种不同的定时。
@immutable
class SleepTimerChoice {
  const SleepTimerChoice.off() : minutes = null, endOfChapter = false;
  const SleepTimerChoice.endOfChapter() : minutes = null, endOfChapter = true;
  const SleepTimerChoice.minutes(int value)
    : minutes = value,
      endOfChapter = false;

  final int? minutes;
  final bool endOfChapter;

  bool get isOff => minutes == null && !endOfChapter;

  @override
  bool operator ==(Object other) =>
      other is SleepTimerChoice &&
      other.minutes == minutes &&
      other.endOfChapter == endOfChapter;

  @override
  int get hashCode => Object.hash(minutes, endOfChapter);
}

/// 按书配置的跳过片头 / 片尾，单位秒。
///
/// 官方 `du`/`dq` = 「跳过片头 / 跳过片尾」，`e8`/`e9`/`e_` = 设置成功的提示，
/// 说明这是**按书**保存的偏好，而不是全局开关。
@immutable
class AudioSkipPoints {
  const AudioSkipPoints({this.introSeconds = 0, this.outroSeconds = 0});

  final int introSeconds;
  final int outroSeconds;

  static const none = AudioSkipPoints();

  bool get isActive => introSeconds > 0 || outroSeconds > 0;

  /// 片头跳点：必须大于 0 且小于总时长，否则视为无效配置。
  Duration? introSeek(Duration duration) {
    if (introSeconds <= 0 || duration <= Duration.zero) return null;
    final target = Duration(seconds: introSeconds);
    return target < duration ? target : null;
  }

  /// 是否已进入片尾跳过区间（距离结束不足 [outroSeconds]）。
  bool atOutro(Duration position, Duration duration) {
    if (outroSeconds <= 0 || duration <= Duration.zero) return false;
    if (position <= Duration.zero) return false;
    return duration - position <= Duration(seconds: outroSeconds);
  }

  @override
  bool operator ==(Object other) =>
      other is AudioSkipPoints &&
      other.introSeconds == introSeconds &&
      other.outroSeconds == outroSeconds;

  @override
  int get hashCode => Object.hash(introSeconds, outroSeconds);
}
