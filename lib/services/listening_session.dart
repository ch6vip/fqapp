import 'package:flutter/foundation.dart';

import '../models/audio_extra.dart';

/// Listening state shared between the playback controller and the reader, so the
/// reader can follow the narration while 听书跟随翻页 is on — the official
/// 「听书进度支持自动翻页」 behaviour. The controller publishes; the reader
/// reads. See .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
class ListeningSession extends ChangeNotifier {
  ListeningSession._();
  static final ListeningSession instance = ListeningSession._();

  String? bookId;
  String? chapterId;
  String? chapterTitle;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;

  /// System TTS reports character progress, never a fabricated audio duration.
  double? textProgress;
  int? textReplacementRevision;

  /// The sentence currently being spoken, in TTS-text coordinates (offsets
  /// into SystemTtsBook.plainText: body paragraphs joined by '\n', title
  /// stripped, images excluded). The reader translates it into layout
  /// coordinates to paint the 句高亮 wash. Null for audiobook playback,
  /// which reports [audioParaRange] instead.
  ({int start, int end})? sentenceRange;

  /// The passage being narrated by 听书 (真人讲书 / 智能朗读), in the backend's
  /// own coordinates: `(paragraph ordinal, offset inside that paragraph)`.
  ///
  /// This is *not* [sentenceRange]: the audio timeline numbers body paragraphs
  /// from the backend's markup (official `AudioTimePoint.start_para`), while
  /// [sentenceRange] indexes the TTS text blob. Conflating them would smear the
  /// highlight across paragraphs, so they stay separate fields and the reader
  /// picks whichever its source produced.
  ({
    int startPara,
    int startOff,
    int endPara,
    int endOff,
    int? elemIndex,
    int? elemOff,
  })?
  audioParaRange;

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether this session is narrating the given chapter right now.
  bool matches(String bookId, String chapterId) =>
      playing && this.bookId == bookId && this.chapterId == chapterId;

  /// Estimated chapter progress (0..1), from text position for system TTS or
  /// elapsed audio time for recordings. Reader page following is proportional.
  double get progress =>
      textProgress ??
      (duration > Duration.zero
          ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
          : 0);

  /// Publishes a state change. Position updates arrive far more often than the
  /// reader needs, so notifications are throttled to one per second unless
  /// something structural changed (chapter, playing).

  /// 当前正在朗读的那句文本，来自听书字幕（智能朗读 / 真人讲书）。
  ///
  /// 系统朗读走 [sentenceRange]（引擎上报字符范围）；音频朗读没有这种回调，
  /// 只有逐句时间轴，所以由播放器把 `SubtitleTrack.cueAt(position).text`
  /// 报上来，阅读页再拿它在正文里定位。
  String? cue;

  /// 当前这句朗读结束的时刻（媒体毫秒）。null = 无字幕或取不到。
  ///
  /// 阅读页靠它决定"什么时候可以翻页"：句没读完就不翻，读完立刻翻。比自己
  /// 猜字符位置准得多，因为字幕的时间轴本来就是朗读时长。
  int? cueEndsAtMs;

  /// 整条字幕轨（本章）。阅读页拿它建「正文字符位置 <-> 音频时间」索引。
  ///
  /// 只在换章时变；日常 tick 传的是同一个引用，不会触发额外通知。
  SubtitleTrack? subtitles;

  /// 当前正在朗读的段落区间，官方 AudioTimePoint 直出的坐标。
  ///
  /// `(段落号, 段内字符偏移)`，段落号从正文第一段（不含标题）数起。与
  /// [sentenceRange] 是两套坐标系，不能混用：那个是 TTS 文本偏移。有这个
  /// 时高亮不需要在正文里做句子匹配，直接映射到布局偏移。

  /// 迷你听书栏的「跳到播放位置」：由阅读页注册，指向正在读的那一句。
  ///
  /// 放在会话上是因为迷你栏在 AudioPlaybackScope 里，不认识阅读页；注册方
  /// 换页/退出时要负责清掉。
  ///
  /// 用 [ValueNotifier] 存而不是普通字段：迷你栏挂在 Overlay 上，只随
  /// AudioPlaybackScope 的结构性重建刷新 —— 「先起播、再打开书」时它压根
  /// 不重建，阅读页注册完按钮还是灰的。值没变不通知，不会每帧刷。
  final ValueNotifier<void Function()?> _jumpToPlaybackHandler =
      ValueNotifier<void Function()?>(null);

  /// 迷你栏监听这个来知道按钮该不该可点。
  ValueListenable<void Function()?> get jumpToPlaybackHandlerListenable =>
      _jumpToPlaybackHandler;

  void Function()? get jumpToPlaybackHandler => _jumpToPlaybackHandler.value;

  set jumpToPlaybackHandler(void Function()? handler) =>
      _jumpToPlaybackHandler.value = handler;

  /// 当前正在用的音色 id（智能朗读的音色、或真人讲书的 narrator id）。
  ///
  /// 阅读页「从本页播放」要沿用同一个音色重新起播 —— 之前不传，播放页只能
  /// 拿历史记录或默认音色，于是听着真人讲书点一下就换成了内置 TTS 音色。
  String? toneId;

  /// 跟随开关：默认跟随朗读，手动翻页后停下等「原进度」。
  ///
  /// 官方默认跟随：播放一开始（`AudioSyncReaderController` 的父类
  /// `d.java:143-151` `onPlayStart`，以及 `AudioSyncReaderController.java:381`
  /// `onPlayResume`）就把页面同步到朗读处，不需要用户按任何按钮。这里在
  /// [update] 检测到「开始播这本书」时自动置真；手动翻页会把它清掉，之后同一
  /// 段播放的 tick 不会再打开它（对应官方 `d.java:288-293` 中 `C=true` 后
  /// 暂停、等「原进度」恢复）。
  bool followArmed = false;

  /// 本章已自然播完。官方在 `onPlayCompletion`（`d.java:92-100`）收起
  /// 播放/同步按钮；下一次起播会清掉这个标记。
  bool completed = false;

  /// 阅读页打开时，这本书已经在播就默认跟随。
  ///
  /// 起播可能发生在阅读页打开之前（`onPlayStart` 的时机已经过去），
  /// 这条补上「打开书就跟随」。
  void followIfPlaying(String bookId) {
    if (playing && this.bookId == bookId) setFollowArmed(true);
  }

  /// 本章播完（自然播完或片尾跳过），阅读页收起底部按钮。
  void markCompleted() {
    if (completed) return;
    completed = true;
    notifyListeners();
  }

  /// 改跟随开关并广播。
  ///
  /// 阅读页手动翻页要退出跟随，而底部的同步胶囊/播放胶囊靠这条通知刷新，
  /// 所以「退出」也必须广播，否则按钮会一直显示旧状态。
  void setFollowArmed(bool value) {
    if (followArmed == value) return;
    followArmed = value;
    notifyListeners();
  }

  void update({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required Duration position,
    required Duration duration,
    required bool playing,
    double? textProgress,
    int? textReplacementRevision,
    ({int start, int end})? sentenceRange,
    ({
      int startPara,
      int startOff,
      int endPara,
      int endOff,
      int? elemIndex,
      int? elemOff,
    })?
    audioParaRange,
    String? cue,
    int? cueEndsAtMs,
    String? toneId,
    SubtitleTrack? subtitles,
  }) {
    final wasPlaying = this.playing;
    final switchedBook = this.bookId != bookId;
    final structural =
        this.bookId != bookId ||
        this.chapterId != chapterId ||
        this.playing != playing ||
        this.sentenceRange != sentenceRange ||
        this.cue != cue ||
        this.cueEndsAtMs != cueEndsAtMs ||
        this.subtitles != subtitles ||
        this.audioParaRange != audioParaRange;
    this.bookId = bookId;
    this.chapterId = chapterId;
    this.chapterTitle = chapterTitle;
    this.position = position;
    this.duration = duration;
    this.playing = playing;
    // 官方默认跟随：播放开始 / 继续播放 / 换了一本正在播的书，都重新开跟随。
    // 同一段播放里的 tick 不会重开，手动翻页退出跟随才站得住。
    if (playing && (!wasPlaying || switchedBook)) followArmed = true;
    if (playing) completed = false;
    this.textProgress = textProgress;
    this.textReplacementRevision = textReplacementRevision;
    this.sentenceRange = sentenceRange;
    this.toneId = toneId;
    this.cue = cue;
    this.cueEndsAtMs = cueEndsAtMs;
    this.subtitles = subtitles;
    this.audioParaRange = audioParaRange;
    final now = DateTime.now();
    if (structural ||
        now.difference(_lastNotify) >= const Duration(seconds: 1)) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  /// Playback closed or failed; the reader must not keep following.
  void clear() {
    if (!playing && bookId == null && chapterId == null) return;
    bookId = null;
    chapterId = null;
    chapterTitle = null;
    position = Duration.zero;
    duration = Duration.zero;
    playing = false;
    textProgress = null;
    textReplacementRevision = null;
    sentenceRange = null;
    cue = null;
    cueEndsAtMs = null;
    toneId = null;
    subtitles = null;
    audioParaRange = null;
    completed = false;
    followArmed = false;
    notifyListeners();
  }
}
