part of '../reader_page.dart';

/// Listening follow: cue/narration sync, auto turn and the 10Hz follow poll.
extension _ReaderPageListening on _ReaderPageState {
  void _toggleAutoTurn() {
    if (_autoTurnTimer != null) {
      _stopAutoTurn();
      return;
    }
    _controlsVisible = false;
    _autoTurnTimer = Timer.periodic(
      Duration(seconds: _preferences.autoTurnSeconds),
      (_) => _autoTurnStep(),
    );
    if (mounted) _setState(() {});
  }

  void _stopAutoTurn() {
    _autoTurnTimer?.cancel();
    _autoTurnTimer = null;
    if (mounted) _setState(() {});
  }

  void _pauseListenFollow() {
    _listenFollowPausedUntil = DateTime.now().add(const Duration(seconds: 15));
    // 用户自己翻页 = 不想被拽回去，直接退出跟随。以前只暂停 15 秒，按钮还
    // 显示「跟随中」，看着像坏了。
    ListeningSession.instance.setFollowArmed(false);
  }

  /// 手动翻页 = 接管播放：退出跟随并暂停朗读。
  ///
  /// 官方 `handlePlayWhenPageChange`（`AudioSyncReaderController.java:1242-1295`）
  /// 在同章翻页时 `pausePlayer()`，然后亮出「原进度 / 从本页听」。换章
  /// （目录、上一章/下一章）不走这里：官方那条分支只置 `C`，不暂停播放。
  void _takeOverListening() {
    _pauseListenFollow();
    AudioPlaybackScope.pauseIfPlaying(context, widget.bookId);
  }

  bool get _listenDoubleTapArmed =>
      _narrationRange != null ||
      ListeningSession.instance.matchesBook(widget.bookId);

  /// 本章该用哪条字幕轨：正在播的就是本章时用会话里的，否则用补取的。
  SubtitleTrack? _cueTrackFor(String chapterId) {
    final session = ListeningSession.instance;
    if (session.matchesChapter(chapterId)) return session.subtitles;
    return _cueTracks[chapterId];
  }

  void _ensureCueIndex(ReaderChapterLayout layout) {
    final track = _cueTrackFor(_chapter.itemId);
    if (identical(_cueIndexLayout, layout) &&
        identical(_cueIndexTrack, track)) {
      return;
    }
    _cueIndexLayout = layout;
    _cueIndexTrack = track;
    _cueIndex = track == null || track.isEmpty
        ? CueIndex.empty
        : CueIndex.build(layout: layout, track: track);
  }

  /// 取本章字幕，取到就缓存。跨章跳读用；同章直接返回会话里的那条。
  Future<SubtitleTrack?> _fetchCueTrack() async {
    final chapterId = _chapter.itemId;
    final session = ListeningSession.instance;
    if (session.matchesChapter(chapterId)) return session.subtitles;
    final cached = _cueTracks[chapterId];
    if (cached != null) return cached;
    final pending = _cueTrackRequests[chapterId];
    if (pending != null) return pending;
    final future = AudioPlaybackScope.timelineForChapter(context, chapterId);
    _cueTrackRequests[chapterId] = future;
    try {
      final track = await future;
      if (track.isNotEmpty) _cueTracks[chapterId] = track;
      return track;
    } catch (_) {
      return null;
    } finally {
      _cueTrackRequests.remove(chapterId);
    }
  }

  /// The passage being narrated, in layout coordinates, or null when this
  /// chapter is not the one on the voice.
  ///
  /// Two sources, two coordinate systems. System TTS reports offsets into the
  /// TTS text blob; 听书 reports the backend's (paragraph, offset) timeline.
  /// Each is translated by its own mapper so neither can smear the highlight
  /// onto the wrong paragraph.
  (int, int)? _narrationLayoutRange(ReaderChapterLayout layout) {
    final session = ListeningSession.instance;
    if (!session.matches(widget.bookId, _chapter.itemId)) return null;
    final audioRange = session.audioParaRange;
    if (audioRange != null) {
      final translated = audioTimePointLayoutRange(
        layout,
        audioRange.startPara,
        audioRange.startOff,
        audioRange.endPara,
        // The upstream end offset is inclusive (official
        // `toTargetTextBlock` passes `endParaOff + 1`); this side is
        // half-open, so the +1 belongs here.
        audioRange.endOff + 1,
        startElementIndex: audioRange.elemIndex,
        startElementOffset: audioRange.elemOff,
      );
      // 官方时间点译不出来时不能直接返回 null：下面那条字幕兜底本来就是为
      // 这种章节写的（多源项章节会重置时间轴），提前返回等于把它跳过。
      if (translated != null) return (translated.start, translated.end);
    }
    final ttsRange = session.sentenceRange;
    if (ttsRange != null &&
        session.textReplacementRevision ==
            (_replacement?.snapshotRevision ?? 0)) {
      final translated = narrationLayoutRange(layout, ttsRange);
      if (translated != null) return (translated.start, translated.end);
    }
    // 官方时间点在多源项章节会重置时间轴（`para 0` 可能从 198 秒才开始），
    // TTS 那条又不适用于音频朗读；这时按播放位置到字幕里查当前句。字幕是
    // 逐句连续的，位置也对得上。
    _ensureCueIndex(layout);
    final span = _cueIndex.spanAtPositionMs(session.position.inMilliseconds);
    if (span != null) return (span.start, span.end);
    // 逐句搜索兜底：句尾落到下一页这类跨页情形索引对不上，但正文里能找到。
    return _locateCue(layout, session.cue);
  }

  void _syncNarrationHighlight((int, int)? narration) {
    if (!mounted) return;
    // 还在读本章、只是这一拍没匹配上（字幕与正文偶有标点差异）时保留上一拍
    // 的区间：清空会让整页突然变黑，观感比「晚半拍」差得多。确实不在读本章
    // 才清。
    //
    // 暂停也保留：官方暂停时朗读标记仍留在正文上（`AudioSyncReaderController`
    // `onPlayPause` 只改播放态，不停同步服务），阅读页据此继续显示「继续播放」。
    final session = ListeningSession.instance;
    final active =
        session.matchesBook(widget.bookId) &&
        session.matchesChapter(_chapter.itemId);
    final held = narration ?? (active ? _narrationRange : null);
    // The follow anchor still uses [narration] when the wash is switched off;
    // only painting depends on the preference.
    final next = _preferences.narrationHighlight ? held : null;
    if (next != _narrationRange) {
      _setState(() => _narrationRange = next);
    }
  }

  /// 把字幕的当前句映射到本章正文的字符区间（布局坐标）。
  ///
  /// 先整句精确匹配；失败后把两边的标点空白都剥掉再匹配，并把命中位置换算
  /// 回原串下标。两次都找不到返回 null —— 宁可这一拍没有高亮，也不留下上一
  /// 句的错位底色。
  (int, int)? _locateCue(ReaderChapterLayout layout, String? rawCue) {
    final cue = rawCue?.trim();
    if (cue == null || cue.isEmpty) return null;
    for (var i = 1; i < layout.blocks.length; i++) {
      final block = layout.blocks[i];
      if (block.isImage || block.text.isEmpty) continue;
      final at = block.text.indexOf(cue);
      if (at >= 0) return (block.start + at, block.start + at + cue.length);
    }
    final needle = cue.replaceAll(_ReaderPageState._cueNoise, '');
    if (needle.isEmpty) return null;
    for (var i = 1; i < layout.blocks.length; i++) {
      final block = layout.blocks[i];
      if (block.isImage || block.text.isEmpty) continue;
      final hit = _ReaderPageState._strippedIndex(block.text, needle);
      if (hit != null) {
        return (block.start + hit.start, block.start + hit.end);
      }
    }
    // 跨页兜底：一句从页尾起头、后半句落到下一页时，新页里只有这句的尾巴
    // （甚至只剩一两个字），整句匹配必然失败，高亮就整段消失。这里改用句尾
    // 若干字逐个尝试，能对上多少就亮多少——亮一两个字也好过全页无高亮。
    //
    // 只看前几个块：残余部分一定落在新页开头，没必要全页扫一遍。
    for (var take = 2; take <= 8; take++) {
      if (take >= needle.length) break;
      final tail = needle.substring(needle.length - take);
      for (var i = 1; i < layout.blocks.length && i <= 3; i++) {
        final block = layout.blocks[i];
        if (block.isImage || block.text.isEmpty) continue;
        final hit = _ReaderPageState._strippedIndex(block.text, tail);
        if (hit != null) {
          return (block.start + hit.start, block.start + hit.end);
        }
      }
    }
    return null;
  }

  void _autoTurnStep() {
    if (!mounted) return _stopAutoTurn();
    if (_loading || !_progressReady || _changingChapter) return;
    if (_index == widget.chapters.length - 1) {
      final atEnd = _paged
          ? _pagedKey.currentState?.isAtEndPage == true
          : _scrollController.hasClients &&
                _scrollController.position.pixels >=
                    _scrollController.position.maxScrollExtent - 2;
      if (atEnd) return _stopAutoTurn();
    }
    // Share the manual page-turn path so scrolling also crosses chapters.
    unawaited(_turnPage(1));
  }

  /// Long press on a paragraph: select it whole and open the action bar.
  ///
  /// Identity comes from [ReaderContentBlock.textId], which falls back to the
  /// paragraph's ordinal when the markup carried no `idx` (the plain-text
  /// `/api/content` path). Requiring `idx` here is what used to make a long
  /// press do literally nothing on those chapters.
  ///
  /// Note: .agents/notes/implemented/feature/2026-09-18-reader-paragraph-actions.md
  /// 迷你听书栏的「跳到播放位置」：把页面跳到正在读的那一句。
  ///
  /// 与跟随走同一条寻址链（对照表 → 句内插值 → 第几页），区别只是它是用户
  /// 主动按的，所以不受「跟随开关」和「用户接管闩锁」限制。
  /// 10Hz 跟随轮询：正在听本章、且用户没在主动翻页时，把页面挪到正在读的字。
  ///
  /// 走 [_addressToPlayback]，与迷你栏的定位键**同一段代码**。闸门只留「什么
  /// 时候不该抢」那几条：跟随关着、工具条展开、自动翻页进行中、用户刚手动
  /// 翻过页。
  void _followPollTick() {
    if (!mounted || !_routeCurrent || !_appActive) return;
    // 跟随开关由迷你栏那个按钮管：关着就是自由翻页，什么都不做。
    if (!ListeningSession.instance.followArmed) return;
    // 设置里的「跟随翻页」是总闸，关掉就永不跟。
    if (!_preferences.listeningFollow) return;
    // 工具条展开时不翻页（用户正在操作页面），自动翻页进行时也不抢。
    if (_controlsVisible || _autoTurnTimer != null) return;
    final session = ListeningSession.instance;
    if (!session.playing) return;
    if (!session.matchesBook(widget.bookId)) return;
    if (_loading || _changingChapter || _error != null) return;
    // 用户刚手动翻过页：15 秒内不抢，之后再跟上。这一条必须在「换章」分支
    // 前面 —— 否则被闩锁挡住的那次切章每 100ms 还会走一遍结算+存盘。
    if (DateTime.now().isBefore(_listenFollowPausedUntil)) return;
    // 朗读已经读完本章、进了下一章：跟随就该把页面带过去。原来这里直接
    // return，于是跟着跟着停在旧章不动了（用户报的「读完一章不翻章」）。
    if (!session.matchesChapter(_chapter.itemId)) {
      // 别名书（真人讲书 ↔ 原著）的章节 id 不同，按阅读页 id 找目标章。
      final next = widget.chapters.indexWhere(
        (c) => c.itemId == session.readerChapterId,
      );
      if (next >= 0) unawaited(_jumpToChapter(next, followListening: true));
      return;
    }
    // 跟随每 20 拍（≈2s）补一次落盘：跟随期间滚动防抖永远等不到。
    if (_addressToPlayback(quiet: true) && _followPoll.saveDue()) {
      _settleReadTime();
      unawaited(_persistProgress());
    }
  }

  /// 把页面寻址到正在读的那个字。返回 false 表示这次没法定位。
  ///
  /// 迷你栏的定位键和 10Hz 跟随轮询**共用这一个函数**——按键每次都准、跟随
  /// 却不准，说明差别不在定位而在跟随那条路上的闸门，所以两条路必须走同一段
  /// 代码。[quiet] 为 true 时（轮询）不弹提示。
  bool _addressToPlayback({bool quiet = false}) {
    if (!mounted) return false;
    final layout = _chapterLayout;
    if (layout == null) return false;
    final session = ListeningSession.instance;
    if (!session.matchesBook(widget.bookId)) {
      if (!quiet) _showMessage('没在听这本书');
      return false;
    }
    // 正在听别的章：先把本页切到那一章再说，切章后轮询会接手。
    if (!session.matchesChapter(_chapter.itemId)) {
      if (quiet) return false;
      final next = widget.chapters.indexWhere(
        (c) => c.itemId == session.readerChapterId,
      );
      if (next >= 0) {
        unawaited(_jumpToChapter(next, followListening: true));
      } else {
        _showMessage('正在播放别的章节');
      }
      return true;
    }
    _ensureCueIndex(layout);
    final positionMs = session.position.inMilliseconds;
    final span = _cueIndex.spanAtPositionMs(positionMs);
    // [_narrationRange] 是**显示**状态：某一拍没匹配上时故意留着不清，好让
    // 高亮晚半拍而不是整页变黑。它绝不能当导航锚点 —— 字幕第一句从 3 秒才
    // 开始（`[3025, 0]`）时，位置 0 查不到句，用它寻址会把页面停到本章最后
    // 一句上，而且再也回不来。只有整章没有字幕表（官方时间点是唯一锚点）时
    // 才退回它。
    final offset =
        span?.spokenOffset(positionMs) ??
        (_cueIndex.isEmpty ? _narrationRange?.$1 : null);
    if (offset == null) {
      if (!quiet) _showMessage('找不到当前朗读句');
      return false;
    }
    if (_paged) {
      _pagedKey.currentState?.followOffset(offset);
    } else if (_scrollController.hasClients) {
      final max = _scrollController.position.maxScrollExtent;
      final length = layout.textLength;
      if (max > 0) {
        final ratio = length > 0
            ? (offset / length).clamp(0.0, 1.0)
            : session.progress;
        _scrollController.jumpTo(ratio * max);
      }
    }
    return true;
  }

  /// 同步胶囊「原进度」：回到朗读处并重新跟随。
  ///
  /// 官方 `AudioSyncReaderController.K()`（:768）：手动翻页后点它，重启同步
  /// 服务并回到正在播的进度。手动翻页在这里已经关掉跟随，所以先开回来。
  void _returnToOriginalProgress() {
    ListeningSession.instance.setFollowArmed(true);
    _jumpToPlaybackPosition();
  }

  /// 双击正文：把朗读跳到手指所指的那一句，可以跨章。
  ///
  /// 全局坐标换算成正文字符下标交给选区几何的 `chapterOffsetAt` —— 它已经在
  /// 处理行内折行、标题占位这些偏移修正，没必要再实现一遍；拿到字符下标后去
  /// 对照表里查出这句的起点时间，再让播放器跳过去。听的是同一本书的别的章时，
  /// 播放器会先切到本章再按位置起播。
  Future<void> _seekToTappedSentence(Offset globalPosition) async {
    final layout = _chapterLayout;
    if (layout == null) return;
    final session = ListeningSession.instance;
    if (session.bookId == null) {
      _showMessage('先开始听书，再双击跳读');
      return;
    }
    if (!session.matchesBook(widget.bookId)) {
      _showMessage('正在听别的书');
      return;
    }
    final offset = _marksScope?.geometry.chapterOffsetAt(globalPosition);
    if (offset == null) return;
    _ensureCueIndex(layout);
    if (_cueIndex.isEmpty) {
      // 跨章时手里的字幕轨是「正在播那一章」的，对不上本章正文。现场取本章
      // 字幕再跳 —— 否则用户得先手动切到播放中的那章，再翻回来点。
      final track = await _fetchCueTrack();
      if (!mounted || !identical(_chapterLayout, layout)) return;
      if (track == null || track.isEmpty) {
        _showMessage('本章没有逐句字幕，无法跳读');
        return;
      }
      _ensureCueIndex(layout);
      if (_cueIndex.isEmpty) {
        // 字幕取到了，但一句都没对上正文（章节文本被改过，或语音文本不是原文）。
        _showMessage('本章字幕和正文对不上，无法跳读');
        return;
      }
    }
    final span = _cueIndex.spanAtChar(offset);
    if (span == null) {
      _showMessage('这一点没有对应字幕，换一句试试');
      return;
    }
    if (!AudioPlaybackScope.jumpToChapter(
      context,
      _chapter.itemId,
      span.startPosition,
    )) {
      _showMessage('朗读还没准备好，稍后再试');
      return;
    }
    HapticFeedback.selectionClick();
    // 立刻把高亮移到这句：下一次 tick 要等 200ms，等待期间旧句子还亮着，
    // 看上去像点错了。跨章时本章本来没高亮，这条跳过即可。
    if (kReaderHighlightWash &&
        mounted &&
        (span.start, span.end) != _narrationRange) {
      _setState(() => _narrationRange = (span.start, span.end));
    }
  }
}
