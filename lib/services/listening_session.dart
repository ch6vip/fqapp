import 'package:flutter/foundation.dart';

/// Listening state shared between the audio page and the reader, so the
/// reader can follow the narration while 听书跟随翻页 is on — the official
/// 「听书进度支持自动翻页」 behaviour. The audio page publishes; the reader
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

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether this session is narrating the given chapter right now.
  bool matches(String bookId, String chapterId) =>
      playing && this.bookId == bookId && this.chapterId == chapterId;

  /// Estimated progress through the chapter (0..1) — our narration is one
  /// audio file per chapter, so page following can only be proportional.
  double get progress => duration > Duration.zero
      ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : 0;

  /// Publishes a state change. Position updates arrive far more often than the
  /// reader needs, so notifications are throttled to one per second unless
  /// something structural changed (chapter, playing).
  void update({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required Duration position,
    required Duration duration,
    required bool playing,
  }) {
    final structural = this.bookId != bookId ||
        this.chapterId != chapterId ||
        this.playing != playing;
    this.bookId = bookId;
    this.chapterId = chapterId;
    this.chapterTitle = chapterTitle;
    this.position = position;
    this.duration = duration;
    this.playing = playing;
    final now = DateTime.now();
    if (structural ||
        now.difference(_lastNotify) >= const Duration(seconds: 1)) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  /// The audio page stopped or left; the reader must not keep following.
  void clear() {
    if (!playing && bookId == null && chapterId == null) return;
    bookId = null;
    chapterId = null;
    chapterTitle = null;
    position = Duration.zero;
    duration = Duration.zero;
    playing = false;
    notifyListeners();
  }
}
