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
  ({int startPara, int startOff, int endPara, int endOff, int? elemIndex, int? elemOff})? audioParaRange;

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
  void Function()? jumpToPlaybackHandler;

  /// 跟随开关：按一次定位键开跟随，再按一次放开自由翻页。
  ///
  /// 当前正在用的音色 id（智能朗读的音色、或真人讲书的 narrator id）。
  ///
  /// 阅读页「从本页播放」要沿用同一个音色重新起播 —— 之前不传，播放页只能
  /// 拿历史记录或默认音色，于是听着真人讲书点一下就换成了内置 TTS 音色。
  String? toneId;

  /// 跟随开关：按定位键开、手动翻页关。
  bool followArmed = false;

  /// 改跟随开关并广播。
  ///
  /// 迷你栏的图标要跟着变色/变实心，但它挂在 Overlay 上、不随阅读页重建，
  /// 只能靠这条通知刷；阅读页自己退出跟随时也必须发一次，否则按钮会一直
  /// 显示「跟随中」。
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
    ({int startPara, int startOff, int endPara, int endOff, int? elemIndex, int? elemOff})? audioParaRange,
    String? cue,
    int? cueEndsAtMs,
    String? toneId,
    SubtitleTrack? subtitles,
  }) {
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
    notifyListeners();
  }
}
