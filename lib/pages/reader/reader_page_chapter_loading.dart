part of '../reader_page.dart';

/// Chapter text loading, caching and text replacement.
extension _ReaderPageChapterLoading on _ReaderPageState {
  TextReplacementStore get _replacementStore =>
      widget.replacementStore ?? TextReplacementStore.instance;

  AiChapterView? get _currentAiView {
    final view = _aiView;
    if (_loading ||
        view == null ||
        widget.chapters.isEmpty ||
        view.bookId != widget.bookId ||
        view.chapterId != _chapter.itemId ||
        !identical(view.composition.replacement.source, _chapterContent)) {
      return null;
    }
    return view;
  }

  Future<TextReplacementResult> _replaceContent(
    ChapterContent content,
    String title,
  ) async {
    _replacementCancellation?.cancel();
    final cancellation = _replacementCancellation =
        TextReplacementCancellation();
    final chapterId = _chapter.itemId;
    final generation = _loadGeneration;
    await _replacementStore.load();
    final controller = AiReadingController.instance;
    while (true) {
      final snapshot = _replacementStore.snapshot;
      final view = await controller.viewFor(
        bookId: widget.bookId,
        chapterId: chapterId,
        chapterTitle: title,
        content: content,
        customSnapshot: snapshot,
        temporaryOriginal: _aiTemporaryOriginal,
        previewSourceStart: _aiPreviewSourceStart,
        previewSourceEnd: _aiPreviewSourceEnd,
        replacementEngine: widget.replacementEngine,
      );
      if (cancellation.cancelled ||
          !mounted ||
          generation != _loadGeneration ||
          chapterId != _chapter.itemId) {
        return view.composition.replacement;
      }
      if (snapshot.revision != _replacementStore.snapshot.revision) continue;
      _aiView = view;
      _aiRevision = view.composition.displayRevision;
      _maybeAutoRequestAi(content, title, view);
      return view.composition.replacement;
    }
  }

  void _maybeAutoRequestAi(
    ChapterContent content,
    String title,
    AiChapterView view,
  ) {
    if (view.composition.formal != null) return;
    if (!view.aiEnabled || !view.consent) return;
    if (view.mode != AiDisplayMode.aiOptimized) return;
    final key =
        '${widget.bookId}|${_chapter.itemId}|${view.snapshot.canonicalHash}';
    if (_aiAutoRequestedKey == key) return;
    _aiAutoRequestedKey = key;
    unawaited(_requestAi(content, title, showBudgetPrompt: false));
  }

  Future<AiTaskResult?> _requestAi(
    ChapterContent content,
    String title, {
    bool forceRefresh = false,
    bool showBudgetPrompt = true,
    bool notifyErrors = true,
  }) async {
    final controller = AiReadingController.instance;
    final result = await controller.requestChapter(
      bookId: widget.bookId,
      chapterId: _chapter.itemId,
      chapterTitle: title,
      content: content,
      chapterVersion: _chapter.version,
      forceRefresh: forceRefresh,
    );
    if (!mounted) return null;
    if (result?.needsBudgetConfirmation == true) {
      if (!showBudgetPrompt) {
        _showMessage('预算已达上限，打开 AI 校对面板可确认本次请求');
        return result;
      }
      final confirmed = await showAiBudgetDialog(
        context,
        result?.budgetMessage ?? '本次请求将超出预算',
      );
      if (!mounted || !confirmed) return null;
      return controller.requestChapter(
        bookId: widget.bookId,
        chapterId: _chapter.itemId,
        chapterTitle: title,
        content: content,
        chapterVersion: _chapter.version,
        forceRefresh: forceRefresh,
        confirmedOverBudget: true,
      );
    }
    if (notifyErrors && result != null && !result.ok && result.error != null) {
      _showMessage(result.error!);
    }
    return result;
  }

  void _openAiEditDetails(AiEditSpan span) {
    final snapshot = _currentAiView?.snapshot;
    if (snapshot == null) return;
    unawaited(
      showAiEditDetailSheet(
        context,
        bookId: widget.bookId,
        chapterId: _chapter.itemId,
        snapshot: snapshot,
        span: span,
        preset: _effectivePreset,
        onChanged: () {
          _aiRevision = -1;
          unawaited(_onAiChanged());
        },
      ),
    );
  }

  Future<void> _showAiPanel() async {
    final view = _currentAiView;
    if (view == null) {
      _showMessage('本章还在加载，稍后再打开 AI 校对');
      return;
    }
    await showAiReaderSheet(
      context,
      controller: AiReadingController.instance,
      view: view,
      preset: _effectivePreset,
      bookId: widget.bookId,
      bookTitle: widget.title,
      chapterId: _chapter.itemId,
      chapterTitle: _chapter.title,
      temporaryOriginal: _aiTemporaryOriginal,
      onPreviewBlocked: (blocked) {
        Navigator.pop(context);
        _setState(() {
          _aiPreviewSourceStart = blocked.span.sourceStart;
          _aiPreviewSourceEnd = blocked.span.sourceEnd;
          _aiRevision = -1;
        });
        unawaited(_onAiChanged());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(days: 1),
            content: const Text('正在临时预览被拦截的 AI 修改'),
            action: SnackBarAction(
              label: '退出预览',
              onPressed: () {
                _aiPreviewSourceStart = null;
                _aiPreviewSourceEnd = null;
                _aiRevision = -1;
                unawaited(_onAiChanged());
              },
            ),
          ),
        );
      },
      onRefresh: (forceRefresh) => _requestAi(
        _chapterContent,
        _chapter.title,
        forceRefresh: forceRefresh,
        notifyErrors: false,
      ),
      onModeChanged: (mode) async {
        _aiTemporaryOriginal = false;
        await AiReadingController.instance.setBookDisplayMode(
          widget.bookId,
          mode,
        );
        _aiRevision = -1;
        await _onAiChanged();
      },
      onTemporaryOriginalChanged: (value) async {
        _aiTemporaryOriginal = value;
        _aiRevision = -1;
        await _onAiChanged();
      },
      onOpenEdit: _openAiEditDetails,
    );
  }

  Future<void> _onAiChanged() async {
    if (_aiChangeRunning) {
      _aiChangeQueued = true;
      return;
    }
    _aiChangeRunning = true;
    try {
      do {
        _aiChangeQueued = false;
        await _runAiChangedOnce();
      } while (_aiChangeQueued && mounted);
    } finally {
      _aiChangeRunning = false;
    }
  }

  void _scheduleAiRetry(Duration delay) {
    _aiDeferTimer?.cancel();
    _aiDeferTimer = Timer(delay, () {
      if (mounted) unawaited(_onAiChanged());
    });
  }

  int _aiAnchorOffset() {
    final fromLayout = _chapterLayout?.sourceOffsetForDisplay(
      _textOffset,
      bias: TextBoundaryBias.start,
    );
    if (fromLayout != null) return fromLayout;
    final saved = _savedPosition?['textOffset'];
    if (saved is int) return saved;
    return _textOffset;
  }

  Future<void> _runAiChangedOnce() async {
    if (!mounted || _loading || _error != null) return;
    final controller = AiReadingController.instance;
    final liveStatus = controller.statusFor(widget.bookId, _chapter.itemId);
    final view = _currentAiView;
    final needsStatusRefresh =
        (liveStatus.running && view?.status != '校对中') ||
        (liveStatus.error != null && view?.lastError != liveStatus.error);
    final known = controller.knownDisplayRevision(
      widget.bookId,
      _chapter.itemId,
      view?.snapshot.canonicalHash,
    );
    if (!needsStatusRefresh && known != null && known == _aiRevision) {
      // No composition change for this chapter. A prefetch status for another
      // chapter still gets the joined-window refresh below.
      _scheduleJoinedAiRefresh();
      return;
    }
    final previousRevision = _aiRevision;
    if (_selection != null || _narrationRange != null) {
      _aiRefreshTimer?.cancel();
      _aiRefreshTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) unawaited(_onAiChanged());
      });
      return;
    }
    // Do not replace the page under a PageView animation. The turn callback
    // commits the new page first; only then is it safe to read its anchor.
    if (_paged && (_pagedKey.currentState?.isTurning ?? false)) {
      _scheduleAiRetry(const Duration(milliseconds: 260));
      return;
    }
    // System TTS keeps an audio queue built from the old display text. Applying
    // a new layout mid-sentence would make the wash point at shifted text.
    // Hold the visual update until playback stops or pauses.
    final listening = ListeningSession.instance;
    if (listening.matchesBook(widget.bookId) &&
        listening.matchesChapter(_chapter.itemId)) {
      if (listening.playing) {
        _aiDeferredForListening = true;
        _scheduleAiRetry(const Duration(milliseconds: 600));
        return;
      }
      // Paused TTS still owns an audio queue built from the old text. Stop it
      // before replacing the page; resuming would otherwise read stale text.
      await AudioPlaybackScope.stopSystemTtsForBook(context, widget.bookId);
      if (!mounted) return;
    }
    final beforeAnchor = _aiAnchorOffset();
    final result = await _replaceContent(_chapterContent, _chapter.title);
    if (!mounted || _loading || _error != null) return;
    // A chapter switch may have landed while composing.
    if (result.source != _chapterContent) return;
    // Composition exposes a content-derived display revision. Prefetch status,
    // stream progress, or another chapter's bookkeeping must not clear the
    // reader layout: only a different final display does.
    if (_aiRevision == previousRevision && previousRevision != -1) {
      _aiDeferredForListening = false;
      _scheduleJoinedAiRefresh();
      return;
    }
    // The user may have turned a page while composing. Anchor on the page
    // currently on screen, not the page that was current when composition
    // started. When the previous pass already tore down the layout, fall back
    // to the saved source offset so a queued AI revision cannot reset to 0.
    final anchor = _chapterLayout == null
        ? (_savedPosition?['textOffset'] as int?) ?? beforeAnchor
        : _aiAnchorOffset();
    _setState(() {
      _replacement = result;
      _chapterLayout = null;
      _layoutDisplayRevision = _aiRevision;
      _savedPosition = <String, dynamic>{
        'chapterId': _chapter.itemId,
        'positionVersion': 2,
        'textOffset': anchor.clamp(0, result.source.legacyText.length),
      };
      _needsRestore = true;
      _textOffset = anchor;
      _progressReady = false;
      // The old narration range points into the pre-AI text. Keep the wash
      // off until the next listening tick remaps it.
      _narrationRange = null;
    });
    if (result.error != null) {
      _showMessage('本章替换失败，已显示原文：${result.error}');
    }
    _aiDeferredForListening = false;
    _scheduleJoinedAiRefresh();
  }

  Chapter get _chapter => widget.chapters[_index];

  ChapterCache get _diskCache =>
      widget.chapterCache ?? ChapterCacheStore.instance;
  CachedBook get _cachedBook => CachedBook(
    id: widget.bookId,
    title: widget.title,
    cover: widget.cover,
    chapters: widget.chapters,
  );

  Future<void> _load({
    bool startAtEnd = false,
    ReaderChapterTurn? chapterTurn,
  }) async {
    if (widget.chapters.isEmpty) return;
    _cancelVideoOpen();
    _locationHighlightTimer?.cancel();
    _locationHighlight = null;
    _progressPreviewActive = false;
    _pendingChapterPreview = null;
    _chapterPreviewFraction = null;
    AiReadingController.instance.cancelPrefetch();
    _aiPreviewSourceStart = null;
    _aiPreviewSourceEnd = null;
    final generation = ++_loadGeneration;
    _replacementCancellation?.cancel();
    ++_replacementGeneration;
    final chapter = _chapter;
    _saveTimer?.cancel();
    _setState(() {
      _loading = true;
      _progressReady = false;
      _error = null;
      _content = '';
      _replacement = null;
      _aiView = null;
      _aiRevision = -1;
      _chapterContent = ChapterContent(blocks: const []);
      _chapterLayout = null;
      _layoutMode = null;
      _textOffset = 0;
      _pageIndex = 0;
      _needsRestore = true;
      _requestedStartAtEnd = startAtEnd;
      _sessionActive = false;
      _chapterTurnRequest = chapterTurn;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    try {
      final loaded = await _chapterText(chapter);
      await _preferencesFuture;
      if (!mounted || generation != _loadGeneration) return;
      Map<String, dynamic>? saved;
      try {
        saved = await _history.load(widget.bookId);
        if (saved?['kind'] != null && saved?['kind'] != 'book') saved = null;
      } catch (_) {
        // History storage must not prevent an available chapter from opening.
      }
      if (!mounted || generation != _loadGeneration) return;
      // Cache updates may arrive while preferences/history are being read.
      final text = _chapterCache[chapter.itemId] ?? loaded.text;
      final content = ChapterContent.fromCacheText(text);
      if (content.withoutLeadingTitle(chapter.title).isEmpty) {
        throw const ApiException('本章暂无可显示正文，可切换下一章或从目录选择其他章节');
      }
      final replacement = await _replaceContent(content, chapter.title);
      if (!mounted || generation != _loadGeneration) return;
      if (_chapterCache[chapter.itemId] != null &&
          _chapterCache[chapter.itemId] != text) {
        await _load(startAtEnd: startAtEnd, chapterTurn: chapterTurn);
        return;
      }
      final cacheKey = '${widget.bookId}\u0000${chapter.itemId}';
      final cachedIdeas = _ideasCache[cacheKey];
      final cachedUnderlines = _underlineCache[cacheKey];
      final ideas = cachedIdeas?.version == chapter.version
          ? cachedIdeas!.ideas
          : ChapterIdeas.empty;
      final underlines = cachedUnderlines?.version == chapter.version
          ? cachedUnderlines
          : null;
      _setState(() {
        _replacement = replacement;
        _content = text;
        _chapterContent = content;
        _savedPosition = saved;
        _loading = false;
        _keepChapterEndAnchor = startAtEnd;
        // Reuse the last known decorations when the same chapter version is
        // opened again. This keeps the first layout identical to the final one;
        // refetching below may still update them if the data changed.
        _ideas = ideas;
        _underlines = underlines?.ids ?? const {};
        _rangeUnderlines = underlines?.ranges ?? const [];
        if (cachedIdeas != null) ++_ideasRevision;
        if (underlines != null) ++_underlineRevision;
        _selection = null;
        _selectionBarOpen = false;
      });
      // 墨水屏切章刷一次：弹窗/翻页之外的残影来源。首章打开不闪
      // （_lastEinkRefreshChapterId 在 initState 已记为首章）。
      if (einkModeNotifier.value &&
          _lastEinkRefreshChapterId != chapter.itemId) {
        _lastEinkRefreshChapterId = chapter.itemId;
        unawaited(EinkRefreshService.instance.requestRefresh());
      }
      if (replacement.error != null) {
        _showMessage('本章替换失败，已显示原文：${replacement.error}');
      }
      unawaited(_prefetchAround(_index));
      unawaited(_loadIdeas(chapter, generation));
      unawaited(_loadUnderlines());
      if (!loaded.fetched && content.needsRefresh()) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      _setState(() {
        _error = '$e';
        _loading = false;
        _chapterTurnRequest = null;
      });
    }
  }

  Future<_LoadedChapter> _chapterText(Chapter chapter) async {
    final id = chapter.itemId;
    final cached = _chapterCache.remove(id);
    if (cached != null) {
      _chapterCache[id] = cached;
      return (text: cached, fetched: false);
    }
    final pending = _chapterRequests[id];
    if (pending != null) return pending;

    final request = _loadChapterText(chapter);
    _chapterRequests[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_chapterRequests[id], request)) {
        _chapterRequests.remove(id);
      }
    }
  }

  Future<String> _fetchChapter(Chapter chapter) async {
    final loader = widget.chapterLoader;
    final ChapterContent content;
    if (loader == null) {
      final request = _chapterRequestHandles.start(chapter.itemId);
      try {
        content = await ApiClient.instance.withCancellation(
          request,
          () => ApiClient.instance.chapterContent(chapter.itemId),
        );
      } finally {
        _chapterRequestHandles.finish(chapter.itemId, request);
      }
    } else {
      final text = await loader(chapter);
      content = ChapterContent.isStructuredCache(text)
          ? ChapterContent.fromCacheText(text)
          : ChapterContent.fromPlainText(text, illustrationsChecked: true);
    }
    if (content.withoutLeadingTitle(chapter.title).isEmpty) {
      throw const ApiException('本章暂无可显示正文，可切换下一章或从目录选择其他章节');
    }
    return content.toCacheText();
  }

  Future<void> _refreshCachedChapter(Chapter chapter) async {
    if (widget.localOnly) return;
    final pending = _chapterRefreshes[chapter.itemId];
    if (pending != null) return pending;
    final request = _upgradeChapter(chapter);
    _chapterRefreshes[chapter.itemId] = request;
    try {
      await request;
    } finally {
      if (identical(_chapterRefreshes[chapter.itemId], request)) {
        _chapterRefreshes.remove(chapter.itemId);
      }
    }
  }

  Future<void> _upgradeChapter(Chapter chapter) async {
    final revision = _chapterCacheRevisions[chapter.itemId] ?? 0;
    try {
      final text = await _fetchChapter(chapter);
      if (!mounted ||
          revision != (_chapterCacheRevisions[chapter.itemId] ?? 0)) {
        return;
      }
      final content = ChapterContent.fromCacheText(text);
      // This request only refreshes an existing cache, even if its memory
      // entry was evicted while fetching. Partial content cannot improve it.
      if (!content.illustrationsChecked) return;
      var catalogReady = true;
      try {
        await _ensureCatalog();
      } catch (_) {
        catalogReady = false;
      }
      if (!mounted ||
          revision != (_chapterCacheRevisions[chapter.itemId] ?? 0)) {
        return;
      }
      final update = _onChapterContentAvailable(chapter, text);
      // The callback publishes its raw cache revision synchronously before
      // awaiting conversion. A newer batch may supersede it during that await.
      final publishedRevision = _chapterCacheRevisions[chapter.itemId] ?? 0;
      await update;
      if (!catalogReady ||
          !mounted ||
          publishedRevision != (_chapterCacheRevisions[chapter.itemId] ?? 0) ||
          _chapterCache[chapter.itemId] != text) {
        return;
      }
      try {
        await _diskCache.write(
          bookId: widget.bookId,
          chapterId: chapter.itemId,
          title: chapter.title,
          text: text,
        );
      } catch (_) {
        // A disk failure does not hide newly fetched illustrations.
      }
    } catch (_) {
      // Legacy text remains immediately readable, including while offline.
    }
  }

  void _rememberChapter(String id, String text) {
    _chapterCache.remove(id);
    _chapterCache[id] = text;
    while (_chapterCache.length > 5) {
      _chapterCache.remove(
        _chapterCache.keys.firstWhere((id) => id != _chapter.itemId),
      );
    }
  }

  // Note: 批量补图与预取共享缓存版本，迟到旧结果不能覆盖新图文；见
  // .agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md
  Future<void> _onChapterContentAvailable(Chapter chapter, String text) async {
    // A cache hit must not invalidate an in-flight signature refresh.
    if (!mounted || _chapterCache[chapter.itemId] == text) return;
    final fetched = ChapterContent.fromCacheText(text);
    final cached = _chapterCache[chapter.itemId];
    final previous = cached == null
        ? null
        : ChapterContent.fromCacheText(cached);
    final content = fetched.preferCompleteCache(previous);
    if (!identical(content, fetched)) return;
    _chapterCacheRevisions.update(
      chapter.itemId,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    _rememberChapter(chapter.itemId, text);
    // The same chapter may have been left and reopened while this one
    // deduplicated refresh was pending. Its identity still makes it current.
    if (_loading || chapter.itemId != _chapter.itemId || text == _content) {
      return;
    }
    final generation = ++_replacementGeneration;
    final loadGeneration = _loadGeneration;
    final replacement = await _replaceContent(content, chapter.title);
    if (!mounted ||
        generation != _replacementGeneration ||
        loadGeneration != _loadGeneration ||
        chapter.itemId != _chapter.itemId ||
        _chapterCache[chapter.itemId] != text) {
      return;
    }
    final hasImages = _chapterContent.hasImages;
    final restoring = _needsRestore;
    final offset = hasImages
        ? _chapterLayout?.sourceOffsetForDisplay(_textOffset) ?? _textOffset
        : _chapterLayout?.legacyOffsetForText(_textOffset) ?? _textOffset;
    _setState(() {
      if (restoring) {
        // A fast refresh may finish before the old cache's first layout.
        // Preserve the history/start-at-end request until it is restored.
        if (!hasImages && _savedPosition?['positionVersion'] == 2) {
          _savedPosition = {...?_savedPosition, 'positionVersion': 1};
        }
      } else {
        _savedPosition = {
          'chapterId': chapter.itemId,
          'positionVersion': hasImages ? 2 : 1,
          'textOffset': offset,
        };
        _requestedStartAtEnd = false;
      }
      _content = text;
      _chapterContent = content;
      _replacement = replacement;
      _selection = null;
      _chapterLayout = null;
      _layoutMode = null;
      _needsRestore = true;
      _progressReady = false;
    });
  }

  Future<void> _ensureCatalog() => _catalogFuture ??= _diskCache
      .saveBook(_cachedBook)
      .catchError((Object error) {
        _catalogFuture = null;
        throw error;
      });

  Future<_LoadedChapter> _loadChapterText(Chapter chapter) async {
    final revision = _chapterCacheRevisions[chapter.itemId] ?? 0;
    bool superseded() =>
        revision != (_chapterCacheRevisions[chapter.itemId] ?? 0);
    String? text;
    if (!widget.localOnly) {
      try {
        final cached = await _diskCache.read(
          bookId: widget.bookId,
          chapterId: chapter.itemId,
        );
        if (cached != null &&
            cached.trim().isNotEmpty &&
            !ChapterContent.fromCacheText(
              cached,
            ).withoutLeadingTitle(chapter.title).isEmpty) {
          text = cached;
        }
      } catch (_) {
        // A storage failure must not prevent online reading.
      }
    }
    if (superseded()) return _latestChapterText(chapter);
    final fetched = text == null;
    if (fetched) {
      try {
        text = await _fetchChapter(chapter);
      } catch (_) {
        if (superseded()) return _latestChapterText(chapter);
        rethrow;
      }
      if (superseded()) return _latestChapterText(chapter);
      var chapterSuperseded = false;
      if (mounted && !widget.localOnly) {
        try {
          await _ensureCatalog();
          if (superseded()) {
            chapterSuperseded = true;
          } else if (mounted) {
            await _diskCache.write(
              bookId: widget.bookId,
              chapterId: chapter.itemId,
              title: chapter.title,
              text: text,
            );
          }
        } catch (_) {
          // Cache management reports storage errors; keep the fetched text usable.
        }
      }
      if (chapterSuperseded) return _latestChapterText(chapter);
    }
    if (superseded()) return _latestChapterText(chapter);
    if (mounted) _rememberChapter(chapter.itemId, text);
    return (text: text, fetched: fetched);
  }

  Future<_LoadedChapter> _latestChapterText(Chapter chapter) async {
    final cached = _chapterCache[chapter.itemId];
    return cached == null
        ? _loadChapterText(chapter)
        : (text: cached, fetched: false);
  }

  Future<void> _prefetchAround(int index) async {
    final nearby = <Chapter>[
      if (index > 0) widget.chapters[index - 1],
      if (index + 1 < widget.chapters.length) widget.chapters[index + 1],
    ];
    await Future.wait(
      nearby.map((chapter) async {
        try {
          await _chapterText(chapter);
        } catch (_) {
          // Prefetch is opportunistic; the foreground load still reports a
          // useful error and offers retry if this chapter is opened later.
        }
      }),
    );
  }
}
