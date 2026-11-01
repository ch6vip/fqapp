part of '../audio_page.dart';

/// 阅读页需要的会话操作：别名匹配、跨章字幕、跳章/跳段、复用听书页。
///
/// 放在单独的 part 里，`audio_playback_scope.dart` 只保留会话生命周期与
/// 播放控制；阅读页专属的寻址逻辑不再把那个文件顶到行数上限。
extension _AudioReaderActions on _AudioPlaybackScopeState {
  /// 阅读页的书 id 是否属于这个会话：音频书自己的 id，或时间轴别名到的
  /// 原著（真人讲书的「边听边读」打开原著后仍要能控制播放）。
  bool sessionBookMatches(String bookId) {
    final session = _session;
    if (session == null || session._closed) return false;
    return session._bookId == bookId || session._linkedNovelBookId == bookId;
  }

  /// 把阅读页的章节 id 解析成播放器使用的音频章节 id。
  ///
  /// 智能朗读两边相同，直接命中；真人讲书的阅读页传的是原著章节 id，只有
  /// 时间轴映射到的当前集才能换回音频章节。其它原著章节没有反查表，返回
  /// null —— 宁可不跳，也不串到别的音频章。
  String? audioChapterIdFor(String readerChapterId) {
    final session = _session;
    if (session == null || session._closed || readerChapterId.isEmpty) {
      return null;
    }
    if (session._chapters.any((c) => c.itemId == readerChapterId)) {
      return readerChapterId;
    }
    if (session._timeTrack.novelItemId != readerChapterId) return null;
    if (session._index < 0 || session._index >= session._chapters.length) {
      return null;
    }
    return session._chapters[session._index].itemId;
  }

  /// 见 [AudioPlaybackScope.timelineForChapter]。
  Future<SubtitleTrack> timelineForChapter(String chapterId) {
    final session = _session;
    if (session == null || session._closed) {
      return Future.value(SubtitleTrack.empty);
    }
    final audioChapterId = audioChapterIdFor(chapterId);
    if (audioChapterId == null) return Future.value(SubtitleTrack.empty);
    final index = session._chapters.indexWhere(
      (c) => c.itemId == audioChapterId,
    );
    if (index < 0) return Future.value(SubtitleTrack.empty);
    // 正在播的就是这一章：会话里的轨最新，直接给。
    if (index == session._index && session._subtitles.isNotEmpty) {
      return Future.value(session._subtitles);
    }
    final key = '${session._toneId}|$audioChapterId';
    final cached = _timelineCache[key];
    if (cached != null) return Future.value(cached);
    final pending = _timelinePending[key];
    if (pending != null) return pending;
    final future = _loadTimeline(
      key,
      session._loadSubtitles(audioChapterId, session._toneId),
    );
    _timelinePending[key] = future;
    return future;
  }

  Future<SubtitleTrack> _loadTimeline(
    String key,
    Future<SubtitleTrack> load,
  ) async {
    try {
      final track = await load;
      // 命中不了的章不再重复请求；超过 8 条就丢最旧的一条。
      if (_timelineCache.length >= 8) {
        _timelineCache.remove(_timelineCache.keys.first);
      }
      _timelineCache[key] = track;
      return track;
    } finally {
      _timelinePending.remove(key);
    }
  }

  /// 见 [AudioPlaybackScope.jumpToChapter]。
  bool jumpToChapter(String chapterId, Duration position) {
    final session = _session;
    if (session == null || session._closed) return false;
    final audioChapterId = audioChapterIdFor(chapterId);
    if (audioChapterId == null) return false;
    final index = session._chapters.indexWhere(
      (c) => c.itemId == audioChapterId,
    );
    if (index < 0) return false;
    if (index == session._index) {
      if (!session._ready) return false;
      unawaited(session._seekTo(position));
    } else {
      unawaited(session._openChapter(index, position: position));
    }
    return true;
  }

  /// 见 [AudioPlaybackScope.jumpToParagraph]。
  bool jumpToParagraph(
    String chapterId, {
    required int? paraIndex,
    required int ordinal,
  }) {
    final session = _session;
    if (session == null || session._closed) return false;
    final audioChapterId = audioChapterIdFor(chapterId);
    if (audioChapterId == null) return false;
    final index = session._chapters.indexWhere(
      (c) => c.itemId == audioChapterId,
    );
    if (index < 0) return false;
    unawaited(
      session._openChapter(
        index,
        paragraph: (paraIndex: paraIndex, ordinal: ordinal),
      ),
    );
    return true;
  }

  /// 见 [AudioPlaybackScope.openAudioPage]。
  void openAudioPage(String bookId) {
    final session = _session;
    if (session == null || session._closed) return;
    if (!sessionBookMatches(bookId)) return;
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AudioPage(
            bookId: session._bookId,
            title: session._title,
            cover: session._cover,
            chapters: session._chapters,
            startIndex: session._index,
            resumeSession: true,
          ),
        ),
      ),
    );
  }
}
