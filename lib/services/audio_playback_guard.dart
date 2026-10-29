part of '../pages/audio_page.dart';

/// 应用睡眠定时档位。
///
/// 分钟档沿用原来的「到点暂停」；「听完本章」不挂计时器，只置一个标志，
/// 由 [_onChapterFinished] 在章末兑现。
void _applySleepTimerChoice(
  _AudioPlaybackController c,
  SleepTimerChoice? choice,
) {
  if (c._closed) return;
  c._sleepTimer?.cancel();
  c._sleepTimer = null;
  c._sleepTimerTick?.cancel();
  c._sleepTimerTick = null;

  final next = choice ?? const SleepTimerChoice.off();
  final atChapterEnd = next.endOfChapter;
  if (c._sleepAtChapterEnd != atChapterEnd) {
    c._sleepAtChapterEnd = atChapterEnd;
    unawaited(AudioPreferences.instance.setSleepAtChapterEnd(atChapterEnd));
  }

  final minutes = next.minutes;
  if (minutes == null) {
    c._update(() => c._sleepRemaining = null);
    c._publishMoreState();
    return;
  }

  c._update(() => c._sleepRemaining = Duration(minutes: minutes));
  c._publishMoreState();
  c._sleepTimer = Timer(Duration(minutes: minutes), () {
    c._sleepTimer = null;
    c._sleepTimerTick?.cancel();
    if (c._closed) return;
    c._update(() {
      c._sleepRemaining = null;
      c._wantPlay = false;
    });
    c._publishMoreState();
    final player = c._player;
    if (player != null && player.isCreated) {
      unawaited(c._pause(player, c._generation));
    }
  });
  _startSleepTicker(c);
}

/// 睡眠定时的秒级倒计时刷新。
void _startSleepTicker(_AudioPlaybackController c) {
  c._sleepTimerTick?.cancel();
  c._sleepTimerTick = Timer.periodic(const Duration(seconds: 1), (_) {
    final remaining = c._sleepRemaining;
    if (remaining == null || c._closed) return;
    final next = remaining - const Duration(seconds: 1);
    c._update(() => c._sleepRemaining = next > Duration.zero ? next : null);
    c._publishMoreState();
    if (next <= Duration.zero) c._sleepTimerTick?.cancel();
  });
}

/// 启动连播倒计时；归零后打开下一章。
void _beginAdvanceCountdown(
  _AudioPlaybackController c, {
  int seconds = kAdvanceCountdownSeconds,
}) {
  _cancelAdvanceCountdown(c);
  if (c._closed || seconds <= 0) return;
  c._advanceRemaining = seconds;
  c._advanceCountdown.value = seconds;
  c._advanceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
    if (c._closed) {
      timer.cancel();
      return;
    }
    final next = (c._advanceRemaining ?? 1) - 1;
    if (next > 0) {
      c._advanceRemaining = next;
      c._advanceCountdown.value = next;
      return;
    }
    timer.cancel();
    c._advanceTimer = null;
    c._advanceRemaining = null;
    c._advanceCountdown.value = null;
    if (c._closed) return;
    if (c._index + 1 < c._chapters.length) {
      unawaited(c._openChapter(c._index + 1));
    }
  });
}

/// 中止连播倒计时（取消 / 暂停 / 选集 / 离开页面）。
void _cancelAdvanceCountdown(_AudioPlaybackController c) {
  c._advanceTimer?.cancel();
  c._advanceTimer = null;
  c._advanceRemaining = null;
  if (c._advanceCountdown.value != null) {
    c._advanceCountdown.value = null;
  }
}

/// 章节播完后的分流：听完本章 → 章末连播 → 其它。
void _onChapterFinished(
  _AudioPlaybackController c, {
  required bool shouldAdvance,
  required NativePlayer player,
  required int generation,
}) {
  // 「听完本章」优先于连播：停在章末并把档位清掉（一次性语义）。
  if (c._sleepAtChapterEnd) {
    c._sleepAtChapterEnd = false;
    unawaited(AudioPreferences.instance.setSleepAtChapterEnd(false));
    c._publishMoreState();
    unawaited(c._pause(player, generation));
    return;
  }
  if (shouldAdvance && c._index + 1 < c._chapters.length) {
    _beginAdvanceCountdown(c);
    return;
  }
  unawaited(c._pause(player, generation));
}

/// 章节播完（自然播完或命中片尾跳过）的统一出口。
///
/// 放在这里而不是控制器里：控制器文件已顶到行数预算，而这个方法是纯编排，
/// 不持有任何自己的状态。
void _handleChapterCompleted(
  _AudioPlaybackController c,
  NativePlayer player,
  int generation,
) {
  if (c._closed || c._completed) return;
  final shouldAdvance = c._wantPlay && c._autoAdvance;
  c._update(() {
    c._completed = true;
    c._wantPlay = false;
    c._position.value = _AudioPlaybackController._boundedPosition(
      player.position,
      c._duration,
    );
  });
  c._publishReadAlong();
  c._listenTime.stop();
  c._syncForeground();
  unawaited(c._persistProgress());
  _onChapterFinished(
    c,
    shouldAdvance: shouldAdvance,
    player: player,
    generation: generation,
  );
  // _openChapter resets completion before its source is ready.
  // The next player's playing event will publish the actual start.
  c._publishListeningSession(playing: false);
  // 官方 onPlayCompletion（d.java:92-100）收起播放/同步按钮；阅读页据此
  // 停止显示，下一章起播时由 update(playing:true) 清掉。
  ListeningSession.instance.markCompleted();
}

/// 控制器对外的只读查询与跳过配置写入。
///
/// 用 extension 而不是往类里加成员：控制器文件已经顶到行数预算，而这些
/// 都只是对既有私有状态的薄封装。
extension _AudioPlaybackQueries on _AudioPlaybackController {
  /// 连播倒计时剩余秒数；null 表示当前没有在倒计时。
  ValueNotifier<int?> get advanceCountdown => _advanceCountdown;

  /// 当前是否停在本轮目录的最后一章。
  bool get atLastChapter => _index + 1 >= _chapters.length;

  /// 睡眠定时是否停在「听完本章」。
  bool get sleepAtChapterEnd => _sleepAtChapterEnd;

  /// 当前字幕轨是否由本地估算生成（服务端没有文稿时的兜底）。
  bool get subtitlesEstimated => _subtitlesEstimated;

  /// 当前这本书的跳过片头/片尾配置。
  AudioSkipPoints get skipPoints => _skipPoints;

  /// 写入跳过片头/片尾（按书持久化）。
  Future<void> setSkipPoints(AudioSkipPoints points) async {
    _skipPoints = points;
    _skipOutroFired = false;
    await AudioPreferences.instance.setSkipIntroSeconds(
      _bookId,
      points.introSeconds,
    );
    await AudioPreferences.instance.setSkipOutroSeconds(
      _bookId,
      points.outroSeconds,
    );
    _publishMoreState();
  }
}

/// 没有服务端文稿时，用章节正文 + 已有时轴反推一条近似字幕轨。
///
/// 注入 loader（测试）与离线环境直接跳过：那两种情况下没有正文来源，
/// 也不该在播放链路上发网络请求。
Future<SubtitleTrack?> _synthesizeSubtitles(
  _AudioPlaybackController c,
  String itemId,
) async {
  if (c.request.sourceLoader != null ||
      c.request.playerFactory != null ||
      c._offline) {
    return null;
  }
  final duration = c._duration;
  if (duration <= Duration.zero) return null;
  try {
    final text = await ApiClient.instance.contentText(itemId);
    if (text.trim().isEmpty) return null;
    return SubtitleSynthesis.build(
      text: text,
      duration: duration,
      anchors: c._timeTrack,
    );
  } catch (_) {
    return null;
  }
}
