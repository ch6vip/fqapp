import 'package:flutter/foundation.dart';

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
  /// which has no text positions.

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
  ({int start, int end})? sentenceRange;

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
  }) {
    final structural =
        this.bookId != bookId ||
        this.chapterId != chapterId ||
        this.playing != playing ||
        this.sentenceRange != sentenceRange;
    this.bookId = bookId;
    this.chapterId = chapterId;
    this.chapterTitle = chapterTitle;
    this.position = position;
    this.duration = duration;
    this.playing = playing;
    this.textProgress = textProgress;
    this.textReplacementRevision = textReplacementRevision;
    this.sentenceRange = sentenceRange;
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
    notifyListeners();
  }
}
