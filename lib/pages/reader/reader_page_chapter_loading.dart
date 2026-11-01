part of '../reader_page.dart';

/// Chapter text loading, caching and text replacement.
extension _ReaderPageChapterLoading on _ReaderPageState {
  TextReplacementStore get _replacementStore =>
      widget.replacementStore ?? TextReplacementStore.instance;

  Future<TextReplacementResult> _replaceContent(
    ChapterContent content,
    String title,
  ) async {
    _replacementCancellation?.cancel();
    final cancellation = _replacementCancellation =
        TextReplacementCancellation();
    await _replacementStore.load();
    while (true) {
      final snapshot = _replacementStore.snapshot;
      final result =
          await (widget.replacementEngine ?? TextReplacementEngine.instance)
              .transform(
                source: content,
                chapterTitle: title,
                snapshot: snapshot,
                cancellation: cancellation,
              );
      if (cancellation.cancelled ||
          snapshot.revision == _replacementStore.snapshot.revision) {
        return result;
      }
    }
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
        throw ApiException('正文为空');
      }
      final replacement = await _replaceContent(content, chapter.title);
      if (!mounted || generation != _loadGeneration) return;
      if (_chapterCache[chapter.itemId] != null &&
          _chapterCache[chapter.itemId] != text) {
        await _load(startAtEnd: startAtEnd, chapterTurn: chapterTurn);
        return;
      }
      _setState(() {
        _replacement = replacement;
        _content = text;
        _chapterContent = content;
        _savedPosition = saved;
        _loading = false;
        // Ideas and 划线 belong to the chapter, so they are dropped on every
        // load and fetched again; a stale entry would point at another chapter.
        _ideas = ChapterIdeas.empty;
        _underlines = const {};
        _rangeUnderlines = const [];
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
      throw const ApiException('正文为空');
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
      if (mounted && !widget.localOnly) {
        try {
          await _ensureCatalog();
          if (superseded()) return _latestChapterText(chapter);
          if (mounted) {
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
