part of '../reader_page.dart';

extension _ReaderBookPanel on _ReaderPageState {
  bool get _readerBookIsImported =>
      ImportedBookStore.isLocalBookId(widget.bookId) ||
      ImportedBookStore.isLocalBookId(_shelfEntry.id);

  bool get _canOpenReaderDetails =>
      !_readerBookIsImported &&
      (_shelfEntry.source == 'fanqie' || isShuqiItem(_shelfEntry));

  // AuthorPage uses the Fanqie author API; other sources have no matching route.
  bool get _canOpenReaderAuthor =>
      !_readerBookIsImported && _shelfEntry.source == 'fanqie';

  Future<BookDetail> _loadReaderBookDetail() async {
    final supplied = widget.bookDetail;
    if (supplied != null) return supplied;
    final loader = widget.bookDetailLoader;
    if (_readerBookIsImported ||
        (loader == null && (widget.localOnly || isShuqiItem(_shelfEntry)))) {
      final book = _shelfEntry;
      return BookDetail(
        bookId: book.id,
        title: book.title,
        cover: book.cover,
        author: BookAuthor(name: book.author),
        abstract: book.intro,
        tags: book.categories,
        creationStatus: book.creationStatus,
        wordNumber: book.wordNumber,
        source: book.source,
      );
    }
    try {
      return await (_readerBookDetailFuture ??= loader != null
          ? loader()
          : ApiClient().bookDetail(widget.bookId));
    } catch (_) {
      _readerBookDetailFuture = null;
      rethrow;
    }
  }

  Future<void> _refreshPageBookmarks() async {
    final generation = ++_pageBookmarksGeneration;
    try {
      final records = await _bookmarkStore.loadBook(widget.bookId);
      if (mounted && generation == _pageBookmarksGeneration) {
        _setState(() => _pageBookmarks = records);
      }
    } catch (_) {
      // The notes panel exposes retryable storage errors; a decorative ribbon
      // must not fabricate an empty state or interrupt reading.
    }
  }

  Set<int> _bookmarkedPagesFor(ReaderChapterLayout layout) => {
    for (final mark in _pageBookmarks)
      if (mark.chapterId == _chapter.itemId)
        layout.pageForOffset(layout.displayOffsetForSource(mark.sourceOffset)),
  };

  List<ReaderBookmark> get _visiblePageBookmarks {
    final layout = _chapterLayout;
    if (layout == null || !_progressReady || _loading) return const [];
    return _pageBookmarks
        .where((mark) {
          if (mark.chapterId != _chapter.itemId) return false;
          final offset = layout.displayOffsetForSource(mark.sourceOffset);
          if (_paged) return layout.pageForOffset(offset) == _pageIndex;
          final block = layout.blockAtOffset(offset);
          if (block == null) return false;
          final current =
              _joinedKey.currentState?.position?.scroll ??
              (_scrollController.hasClients ? _scrollController.offset : 0.0);
          final local = offset - block.start;
          ReaderTextLine? line;
          for (final candidate in block.lines) {
            if (candidate.start > local) break;
            line = candidate;
          }
          final top =
              layout.spec.verticalPadding + block.top + (line?.top ?? 0);
          final bottom = top + (line?.height ?? block.height);
          return bottom > current &&
              top < current + layout.spec.viewport.height;
        })
        .toList(growable: false);
  }

  bool get _currentPageBookmarked => _visiblePageBookmarks.isNotEmpty;

  Future<void> _removeVisiblePageBookmarks() async {
    // Capture the exact records before any await. A later page turn cannot
    // redirect deletion to a different page or erase that chapter's bookmarks.
    final records = _visiblePageBookmarks;
    if (records.isEmpty) return;
    final chapterId = _chapter.itemId;
    try {
      for (final record in records) {
        await _bookmarkStore.remove(record.key);
      }
      await _refreshPageBookmarks();
      if (mounted && chapterId == _chapter.itemId) _showMessage('删除书签成功');
    } catch (_) {
      await _refreshPageBookmarks();
      if (mounted) _showMessage('书签删除失败，请重试');
    }
  }

  Future<void> _openReaderAuthor(BookAuthor author) async {
    if (!mounted || !_canOpenReaderAuthor || author.id.trim().isEmpty) return;
    _setControlsVisible(false);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AuthorPage(authorId: author.id, fallbackName: author.name),
      ),
    );
  }

  Future<void> _openReaderDetails() async {
    if (!mounted || !_canOpenReaderDetails) return;
    _setControlsVisible(false);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => isShuqiItem(_shelfEntry)
            ? ShuqiDetailPage(
                bookId: _shelfEntry.id,
                initialTitle: widget.title,
                initialCover: widget.cover,
              )
            : DetailPage(item: _shelfEntry, autoOpenReader: false),
      ),
    );
  }

  Future<void> _showClassicBookPanel() async {
    _readerPanelOpen = true;
    _stopAutoTurn();
    _setControlsVisible(false);
    final generation = ++_readerNavigationGeneration;
    Set<String> cachedIds = {};
    try {
      cachedIds = await _diskCache.cachedChapterIds(widget.bookId);
    } catch (_) {}
    var aiStatuses = const <AiChapterCheckStatus>[];
    try {
      if (AiReadingController.instance.isReady) {
        aiStatuses = await AiReadingController.instance.chapterStatuses(
          widget.bookId,
        );
      }
    } catch (_) {}
    if (!mounted || generation != _readerNavigationGeneration) return;
    final preset = _effectivePreset;
    final selected = await showModalBottomSheet<Object>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 720),
      sheetAnimationStyle: _reduceReaderMotion
          ? AnimationStyle.noAnimation
          : null,
      builder: (sheetContext) => _readerOverlay(
        preset,
        Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: .92,
            child: ReaderBookPanel(
              book: _shelfEntry,
              preset: preset,
              loadDetail: _loadReaderBookDetail,
              directory: ReaderDirectorySheet(
                chapters: widget.chapters,
                currentIndex: _index,
                cachedIds: cachedIds,
                bookId: widget.bookId,
                aiStatuses: aiStatuses,
                aiController: AiReadingController.instance,
                preset: preset,
                embedded: true,
                currentProgress: _chapterProgress(),
              ),
              notes: ReaderBookNotes(
                bookId: widget.bookId,
                chapters: widget.chapters,
                preset: preset,
                bookmarkStore: _bookmarkStore,
                underlineStore:
                    widget.underlineStore ?? ReaderUnderlineStore.instance,
                onBookmark: (mark) => Navigator.pop(sheetContext, mark),
                onUnderline: (mark) => Navigator.pop(sheetContext, mark),
                onRangeUnderline: (mark) => Navigator.pop(sheetContext, mark),
              ),
              onDetails: _canOpenReaderDetails
                  ? () => Navigator.pop(sheetContext, 'details')
                  : null,
              onAuthor: _canOpenReaderAuthor
                  ? (author) => Navigator.pop(sheetContext, author)
                  : null,
              onSearch: () => Navigator.pop(sheetContext, 'search'),
              onNight: () => Navigator.pop(sheetContext, 'night'),
              onSettings: () => Navigator.pop(sheetContext, 'settings'),
              onAi: _currentAiView != null
                  ? () => Navigator.pop(sheetContext, 'ai')
                  : null,
              aiLabel: _currentAiView?.hasCache == true ? 'AI 已校对' : 'AI 校对',
            ),
          ),
        ),
      ),
    );
    if (!mounted || generation != _readerNavigationGeneration) return;
    _maybeEinkRefresh();
    // Notes can delete marks from any chapter. Refresh the current chapter's
    // painter before returning to text; source records remain unchanged.
    if (!_loading && widget.chapters.isNotEmpty) unawaited(_loadUnderlines());
    if (!mounted || generation != _readerNavigationGeneration) return;
    switch (selected) {
      case int index:
        await _jumpToChapter(index);
      case BookAuthor author:
        await _openReaderAuthor(author);
      case ReaderBookmark mark:
        await _runBookNoteNavigation(
          mark.chapterId,
          generation,
          () => _navigateBookmark(mark, generation),
        );
      case ReaderUnderline mark:
        await _runBookNoteNavigation(mark.chapterId, generation, () async {
          final layout = _chapterLayout;
          if (layout == null) return;
          ReaderContentBlock? target;
          for (final block in layout.blocks) {
            if (block.isTitle || block.isImage) continue;
            if (mark.paraIndex != null
                ? block.paraIndex == mark.paraIndex
                : block.index == mark.blockIndex + 1) {
              target = block;
              break;
            }
          }
          if (target == null ||
              layout
                      .sourceTextInRange(
                        layout.sourceOffsetForDisplay(target.start),
                        layout.sourceOffsetForDisplay(
                          target.end,
                          bias: TextBoundaryBias.end,
                        ),
                      )
                      .trim() !=
                  mark.text.trim()) {
            _showMessage('原文段落已变化，无法定位这条划线');
            return;
          }
          await _landAtOffset(target.start, end: target.end);
        });
      case ReaderRangeUnderline mark:
        await _runBookNoteNavigation(mark.chapterId, generation, () async {
          final layout = _chapterLayout;
          if (layout == null) return;
          if (layout.sourceTextInRange(mark.start, mark.end).trim() !=
              mark.text.trim()) {
            _showMessage('原文已变化，无法定位这条划线');
            return;
          }
          await _landAtOffset(
            layout.displayOffsetForSource(mark.start),
            end: layout.displayOffsetForSource(
              mark.end,
              bias: TextBoundaryBias.end,
            ),
          );
        });
      case 'details':
        await _openReaderDetails();
      case 'search':
        await _showFullSearch();
      case 'night':
        _toggleNightTheme();
      case 'settings':
        await _showAppearanceSettings();
      case 'ai':
        await _showAiPanel();
    }
  }

  Future<void> _runBookNoteNavigation(
    String chapterId,
    int generation,
    Future<void> Function() land,
  ) async {
    final previous = _bookmarkNavigationTask;
    final task = () async {
      try {
        await previous;
      } catch (_) {}
      if (!mounted || generation != _readerNavigationGeneration) return;
      final target = widget.chapters.indexWhere((c) => c.itemId == chapterId);
      if (target < 0) {
        _showMessage('目录中已找不到这条记录的章节');
        return;
      }
      if (target != _index) {
        await _jumpToChapter(target, navigationGeneration: generation);
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          generation != _readerNavigationGeneration ||
          _chapter.itemId != chapterId ||
          _error != null) {
        return;
      }
      await land();
    }();
    _bookmarkNavigationTask = task;
    try {
      await task;
    } catch (_) {
      if (mounted && generation == _readerNavigationGeneration) {
        _showMessage('记录暂时无法打开，请重试');
      }
    } finally {
      if (identical(task, _bookmarkNavigationTask)) {
        _bookmarkNavigationTask = null;
      }
    }
  }
}
