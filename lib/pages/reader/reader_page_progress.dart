part of '../reader_page.dart';

/// Paging layout, scroll/progress persistence, chapter turns and e-ink refresh
/// bookkeeping.
extension _ReaderPageProgress on _ReaderPageState {
  ReaderChapterLayout _prepareLayout(BoxConstraints constraints) {
    final spec = ReaderLayoutSpec(
      viewport: constraints.biggest,
      textScaler: MediaQuery.textScalerOf(context),
      preferences: _displayPreferences,
      fontFamily:
          _fontFamily ?? Theme.of(context).textTheme.bodyLarge?.fontFamily,
    );
    if (_chapterLayout?.spec == spec &&
        _layoutMode == _preferences.pageMode &&
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision &&
        _layoutBubblesVisible == _preferences.showParagraphBubbles) {
      return _chapterLayout!;
    }
    // Reuse the measured text layout only when nothing that feeds it changed.
    // Switching page mode keeps the same spec and page-insensitive measurements,
    // so it must not re-measure — but bubbles or 划线 must.
    // The bubble switch gates the data itself (not just the builder):
    // the layout reserves placeholder space from bubbleCount, so a null
    // builder alone would leave an empty gap at the paragraph end.
    final bubblesVisible = _preferences.showParagraphBubbles;
    final reusable =
        _chapterLayout?.spec == spec &&
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision &&
        _layoutBubblesVisible == bubblesVisible;
    final layoutChapter = _chapter;
    final layoutIdeas = _ideas;
    final layout = reusable
        ? _chapterLayout!
        : ReaderChapterLayout(
            title: _chapter.title,
            content: _chapterContent,
            replacement: _replacement,
            spec: spec,
            paragraphBubbles: bubblesVisible ? _ideas.bubbleCounts : const {},
            paragraphBubbleVariants: bubblesVisible
                ? _ideas.bubbleVariants
                : const {},
            underlinedParagraphs: _underlines,
            bubbleBuilder: bubblesVisible
                ? (paraIndex, count, variant) => _buildParagraphBubble(
                    paraIndex,
                    count,
                    variant,
                    sourceChapter: layoutChapter,
                    sourceIdeas: layoutIdeas,
                  )
                : null,
          );
    _layoutIdeasRevision = _ideasRevision;
    _layoutUnderlineRevision = _underlineRevision;
    _layoutBubblesVisible = bubblesVisible;
    final initialRestore = _needsRestore;
    // Joined content preserves its visible anchor during layout. Restoring a
    // second time after paint would cancel the user's ongoing drag or fling.
    final joinedAnchor =
        _joined &&
        _joinedKey.currentState != null &&
        !initialRestore &&
        _chapterLayout?.spec == spec;
    final restored = initialRestore
        ? layout.restore(
            _savedPosition,
            chapterId: _chapter.itemId,
            startAtEnd: _requestedStartAtEnd,
            paged: _paged,
          )
        : (
            textOffset: _textOffset,
            scroll:
                layout.scrollForTextOffset(_textOffset) +
                _joinedScrollRemainder(spec),
          );
    _chapterLayout = layout;
    // 阅读页可能在起播之后才打开：会话的结构性通知早于这份排版到达，若只等
    // 下一次通知，高亮（以及「高亮在屏」这条判据）会晚一拍。排版一就位就
    // 直接算一次，构建阶段不能 setState，所以只赋值。
    final narration = _narrationLayoutRange(layout);
    _narrationRange = _preferences.narrationHighlight ? narration : null;
    _layoutMode = _preferences.pageMode;
    _textOffset = restored.textOffset;
    _pageIndex = layout.pageForOffset(_textOffset);
    _needsRestore = false;
    _progressReady = false;
    final revision = ++_layoutRevision;
    final generation = _loadGeneration;
    // Layout and restoration must both finish before a new snapshot may save.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          revision != _layoutRevision ||
          !identical(layout, _chapterLayout)) {
        return;
      }
      if (!_paged && !joinedAnchor) {
        if (!_scrollController.hasClients) return;
        _jumpScroll(restored.scroll);
      }
      _setState(() => _progressReady = true);
      if (_appActive && !_sessionActive) {
        _sessionActive = true;
        _readStart = DateTime.now();
      }
      unawaited(_persistProgress(createHistory: initialRestore));
    });
    return layout;
  }

  void _onScroll() {
    _saveTimer?.cancel();
    if (!_progressReady || _paged) return;
    // 墨水屏滚动模式：按滚动距离累积，每滚够约 3 屏刷一次。
    if (einkModeNotifier.value && _scrollController.hasClients) {
      final offset = _scrollController.offset;
      _einkScrollDistance += (offset - _einkLastScrollOffset).abs();
      _einkLastScrollOffset = offset;
      final viewport = _scrollController.position.viewportDimension;
      if (viewport > 0 && _einkScrollDistance >= viewport * 3) {
        _einkScrollDistance = 0;
        unawaited(EinkRefreshService.instance.requestRefresh());
      }
    }
    _captureScrollProgress(updateTextOffset: true);
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _settleReadTime();
      unawaited(_persistProgress());
    });
  }

  /// Settles the reading-time delta since the last event, legado-style:
  /// the time between this event and the previous one counts as reading.
  void _settleReadTime() {
    if (!_sessionActive || _content.isEmpty) return;
    final now = DateTime.now();
    final delta = now.difference(_readStart).inMilliseconds / 1000;
    if (delta >= 1) {
      unawaited(
        _readerStore
            .accumulateReadTime(widget.bookId, 'book', delta)
            .catchError((_) {}),
      );
    }
    _readStart = now;
  }

  void _captureScrollProgress({bool updateTextOffset = false}) {
    final layout = _chapterLayout;
    if (_paged) {
      if (layout != null) {
        _lastPosition = layout.scrollForTextOffset(_textOffset);
        _lastMaxScroll = layout.maxScroll;
      }
      return;
    }
    if (!_scrollController.hasClients) return;
    _lastPosition = _joined
        ? _joinedKey.currentState?.position?.scroll ?? _lastPosition
        : _scrollController.offset;
    _lastMaxScroll = _joined
        ? layout?.maxScroll ?? 0
        : _scrollController.position.maxScrollExtent;
    if (updateTextOffset && layout != null) {
      _textOffset = layout.textOffsetAtScroll(_lastPosition);
    }
  }

  void _onPageChanged(int page) {
    // Turning the page cancels the selection: the handles belong to the text,
    // the action bar's anchor would be stale. Reselecting is one long press.
    _closeSelectionBar(clearSelection: true);
    if (!_progressReady || _changingChapter || page == _pageIndex) return;
    _setState(() {
      _pageIndex = page;
      _textOffset = _chapterLayout!.pages[page].start;
    });
    _settleReadTime();
    unawaited(_persistProgress());
    // 分页模式的实际翻页：累加墨水屏刷新计数（覆盖音量键/自动翻页/点按翻页）。
    _recordEinkPageTurn();
  }

  /// 墨水屏：弹窗/菜单关闭后刷一次，清掉弹窗残影。非墨水屏不做事。
  ///
  /// 只走厂商全刷接口，绝不走软件白闪回退：关闭弹窗并不改变正文，盖白帧会
  /// 把正文整页闪没（#172）。非海信设备留给下一次真正的内容变化（切章、
  /// 翻页、滚够三屏）去清残影。
  void _maybeEinkRefresh() {
    if (!einkModeNotifier.value) return;
    unawaited(EinkRefreshService.instance.refreshIfSupported());
  }

  /// 墨水屏整屏刷新：翻够 [_preferences.einkRefreshInterval] 页触发一次海信 EPD
  /// 全刷压残影。全局墨水屏未开或间隔为 0 时直接跳过，计数不累加。
  void _recordEinkPageTurn() {
    if (!einkModeNotifier.value) return;
    final interval = _preferences.einkRefreshInterval;
    if (interval <= 0) return;
    _einkPageCounter++;
    if (_einkPageCounter >= interval) {
      _einkPageCounter = 0;
      unawaited(EinkRefreshService.instance.requestRefresh());
    }
  }

  Future<void> _pageBoundary(int direction) async {
    if (!_progressReady || _changingChapter || _loading) return;
    if (direction < 0) {
      if (_index == 0) {
        _showMessage('已是第一页');
      } else {
        await _prev(startAtEnd: true);
      }
    } else {
      await _next();
    }
  }

  /// Captures the page on screen so a chapter boundary can animate. Returns
  /// null when paging is off or the reader is set to turn without animation.
  ReaderChapterTurn? _captureChapterTurn(int direction) {
    if (!_paged || _preferences.pageTurnStyle == ReaderPageTurnStyle.none) {
      return null;
    }
    final layout = _chapterLayout;
    if (layout == null || layout.pages.isEmpty) return null;
    return ReaderChapterTurn(
      direction: direction,
      page: layout.pages[_pageIndex.clamp(0, layout.pages.length - 1)],
      spec: layout.spec,
    );
  }

  /// The boundary slide finished: drop the overlay so the rebuilt pagination
  /// shows through. The chapter switch itself was already committed.
  void _onChapterTurnCompleted() {
    if (!mounted || _chapterTurnRequest == null) return;
    _setState(() => _chapterTurnRequest = null);
  }

  Future<void> _persistProgress({bool createHistory = false}) async {
    if (!_progressReady) return;
    // The scrollable may already be detached when the reader is disposed.
    _captureScrollProgress();
    final joined = _joined ? _joinedKey.currentState?.position : null;
    final index = joined?.index ?? _index;
    final chapterId = widget.chapters[index].itemId;
    final position = _lastPosition;
    final max = joined?.chapter.layout.maxScroll ?? _lastMaxScroll;
    final progress = _chapterProgress(
      position: position,
      maxScroll: max,
      index: index,
    );
    final entry = {
      'id': widget.bookId,
      'kind': 'book',
      'title': widget.title,
      'bookId': widget.bookId,
      'chapterId': chapterId,
      'episode': index,
      // 总章数：书架靠「第 N/M 章」区分「读到末尾」与「全书读完」
      // （issue #110 第 3 条）。官方存的是 itemCounts，见 ChaseUpdateModel。
      'chapterCount': widget.chapters.length,
      'position': position,
      'maxScroll': max,
      'positionVersion': 2,
      'textOffset': joined != null
          ? joined.chapter.layout.sourceOffsetForDisplay(
              joined.chapter.layout.textOffsetAtScroll(joined.scroll),
            )
          : _chapterLayout?.sourceOffsetForDisplay(_textOffset) ?? _textOffset,
      'progress': progress,
      'cover': widget.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    await _history.save(entry, createHistory: createHistory);
  }

  double _chapterProgress({double? position, double? maxScroll, int? index}) {
    if (widget.chapters.isEmpty) return 0;
    if (_joined) {
      position ??= _joinedKey.currentState?.position?.scroll ?? _lastPosition;
      maxScroll ??= _chapterLayout?.maxScroll ?? 0;
    }
    if (_paged) {
      final pageCount = _chapterLayout?.pages.length ?? 1;
      final fraction = pageCount > 1 ? _pageIndex / (pageCount - 1) : 0.0;
      return ((index ?? _index) + fraction) / widget.chapters.length;
    }
    final fraction =
        (maxScroll ??
                (_scrollController.hasClients
                    ? _scrollController.position.maxScrollExtent
                    : 0)) >
            0
        ? (position ??
                  (_scrollController.hasClients
                      ? _scrollController.offset
                      : 0)) /
              (maxScroll ?? _scrollController.position.maxScrollExtent)
        : 0.0;
    return ((index ?? _index) + fraction.clamp(0.0, 1.0)) /
        widget.chapters.length;
  }

  /// Goes to the previous chapter.
  ///
  /// [startAtEnd] exists for the *continuous reading* paths only: paging past
  /// the first page of a chapter, overscrolling at the top, or a tap zone that
  /// means "back one chapter while scrolling". Those land on the previous
  /// chapter's end so reading continues where it left off.
  ///
  /// An explicit「上一章」controls (toolbar button, chapter slider arrow, menu
  /// row) must NOT pass it: the official client addresses chapters as
  /// `Y(chapterId, 0, …)` — always the chapter start — and landing on the last
  /// page while「下一章」lands on the first made the pair feel broken
  /// (issue #110).
  Future<void> _prev({bool startAtEnd = false}) async {
    if (_index <= 0 || _changingChapter) return;
    // 用户主动换章 = 不想被朗读拽回去，否则轮询 100ms 后又跳回正在播的那章。
    _pauseListenFollow();
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      final turn = _captureChapterTurn(-1);
      _setState(() => _index--);
      await _load(startAtEnd: startAtEnd, chapterTurn: turn);
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _next() async {
    if (_changingChapter) return;
    if (_index >= widget.chapters.length - 1) {
      _showMessage('已是最后一章');
      return;
    }
    // 同 [_prev]：主动翻到下一章也要退出跟随。
    _pauseListenFollow();
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      final turn = _captureChapterTurn(1);
      _setState(() => _index++);
      await _load(chapterTurn: turn);
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _jumpToChapter(int index, {bool followListening = false}) async {
    if (!followListening) _pauseListenFollow();
    if (_changingChapter ||
        index == _index ||
        index < 0 ||
        index >= widget.chapters.length) {
      return;
    }
    _changingChapter = true;
    try {
      // 闸门要排在结算/存盘**前面**：被闩锁挡住的这次跟随切章什么都没做，
      // 而在后面的话轮询每 100ms 都会存一次进度。
      if (followListening &&
          (!_routeCurrent ||
              !_appActive ||
              _controlsVisible ||
              !_preferences.listeningFollow ||
              _autoTurnTimer != null ||
              DateTime.now().isBefore(_listenFollowPausedUntil) ||
              !ListeningSession.instance.matches(
                widget.bookId,
                widget.chapters[index].itemId,
              ))) {
        return;
      }
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      _setState(() {
        _index = index;
        _chapterSeekValue = null;
      });
      await _load();
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _turnPage(int direction) async {
    if (_loading || !_progressReady || _changingChapter) return;
    if (_paged) {
      await _pagedKey.currentState?.turnPage(direction);
      return;
    }
    // 滚动模式的离散翻页（音量键/点按边缘/自动翻页）记一次，连续拖拽不计入。
    _recordEinkPageTurn();
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    const boundaryTolerance = 2.0;
    if (direction < 0 &&
        position.pixels <= position.minScrollExtent + boundaryTolerance) {
      await _prev(startAtEnd: true);
      return;
    }
    if (direction > 0 &&
        position.pixels >= position.maxScrollExtent - boundaryTolerance) {
      await _next();
      return;
    }

    final delta = position.viewportDimension * 0.86 * direction;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _desktopScroll(PointerSignalEvent signal) {
    if (!_paged ||
        signal is! PointerScrollEvent ||
        signal.scrollDelta.dy == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      final now = DateTime.now();
      if (now.difference(_desktopWheelAt).inMilliseconds < 180) return;
      _desktopWheelAt = now;
      _takeOverListening();
      unawaited(_turnPage(signal.scrollDelta.dy > 0 ? 1 : -1));
    });
  }
}
