part of '../reader_page.dart';

/// Wenku8 navigation UI adapted to fqapp's measured chapter and source offsets.
/// Preview never loads another chapter or saves each intermediate slider stop.
extension _ReaderPageNavigation on _ReaderPageState {
  ReaderTextSelection? get _paintedSelection =>
      _selection ?? _locationHighlight;

  double? get _chapterLocalFraction {
    if (_loading || !_progressReady || _chapterLayout == null) return null;
    if (_chapterPreviewFraction != null) return _chapterPreviewFraction;
    if (_paged) {
      final count = _chapterLayout!.pages.length;
      return count <= 1 ? 0 : (_pageIndex / (count - 1)).clamp(0.0, 1.0);
    }
    if (!_scrollController.hasClients) return null;
    final max = _joined
        ? _chapterLayout!.maxScroll
        : _scrollController.position.maxScrollExtent;
    final offset = _joined
        ? _joinedKey.currentState?.position?.scroll ?? _lastPosition
        : _scrollController.offset;
    return max <= 0 ? 0 : (offset / max).clamp(0.0, 1.0);
  }

  void _setChapterPreview(bool active) {
    if (!mounted) return;
    if (!active) {
      _finishChapterPreview();
      return;
    }
    if (_chapterLocalFraction == null) return;
    _stopAutoTurn();
    _takeOverListening();
    _closeSelectionBar(clearSelection: true);
    _clearLocationHighlight();
    _saveTimer?.cancel();
    _setState(() {
      _progressPreviewActive = true;
      _previewLoadGeneration = _loadGeneration;
    });
  }

  void _previewChapterFraction(double value) {
    if (!_progressPreviewActive) _setChapterPreview(true);
    if (!_progressPreviewActive) return;
    _pendingChapterPreview = value.clamp(0.0, 1.0);
    if (_chapterPreviewScheduled) return;
    _chapterPreviewScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chapterPreviewScheduled = false;
      if (!mounted || !_progressPreviewActive) return;
      final pending = _pendingChapterPreview;
      _pendingChapterPreview = null;
      if (pending != null && _previewLoadGeneration == _loadGeneration) {
        _applyChapterFraction(pending);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _applyChapterFraction(double value) {
    final layout = _chapterLayout;
    if (layout == null || _loading || !_progressReady) return;
    final fraction = value.clamp(0.0, 1.0);
    if (_paged) {
      if (layout.pages.isEmpty) return;
      _pagedKey.currentState?.followPage(
        (fraction * (layout.pages.length - 1)).round(),
      );
    } else {
      if (!_scrollController.hasClients) return;
      final max = _joined
          ? layout.maxScroll
          : _scrollController.position.maxScrollExtent;
      _jumpScroll(max * fraction);
      _captureScrollProgress(updateTextOffset: true);
    }
    _setState(() => _chapterPreviewFraction = fraction);
  }

  void _commitChapterFraction(double value) {
    if (!mounted || _loading || !_progressReady) return;
    // Semantic increments do not send a pointer-start callback.
    if (!_progressPreviewActive) _setChapterPreview(true);
    _pendingChapterPreview = value.clamp(0.0, 1.0);
    _finishChapterPreview();
  }

  void _finishChapterPreview() {
    if (!_progressPreviewActive) return;
    final generation = _previewLoadGeneration;
    final pending = _pendingChapterPreview;
    _pendingChapterPreview = null;
    if (mounted && pending != null && generation == _loadGeneration) {
      _applyChapterFraction(pending);
    }
    if (!mounted) return;
    _setState(() {
      _progressPreviewActive = false;
      _chapterPreviewFraction = null;
      _previewLoadGeneration = null;
    });
    // Joined scroll reports its actual chapter position after layout. Save that
    // position, not an old frame's cached value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _loadGeneration) return;
      _captureScrollProgress(updateTextOffset: true);
      _settleReadTime();
      unawaited(_persistProgress());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showFind() async {
    ++_readerNavigationGeneration;
    final layout = _chapterLayout;
    if (_loading || !_progressReady || layout == null) return;
    final chapterId = _chapter.itemId;
    final replacement = _replacement;
    _readerPanelOpen = true;
    _setControlsVisible(false);
    final preset = _effectivePreset;
    final match = await showJellySheet<ReaderFindMatch>(
      context: context,
      reduceMotion: _reduceReaderMotion,
      surfaceWrapper: (child) => _readerOverlay(preset, child),
      builder: (_) => ReaderFindPanel(
        paragraphs: [
          for (final block in layout.blocks)
            if (!block.isTitle && !block.isImage)
              ReaderFindParagraph(start: block.start, text: block.text),
        ],
        preset: preset,
      ),
    );
    if (!mounted || match == null || _chapter.itemId != chapterId) return;
    // Geometry changes do not change display-text offsets. Mapping a match
    // through source offsets would expand a hit inside a replacement to the
    // entire replacement, so retain its exact range while the text is stable.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _chapter.itemId != chapterId) return;
    final current = _chapterLayout;
    if (current == null || !identical(replacement, _replacement)) {
      _showMessage('正文已更新，请重新查找');
      return;
    }
    await _landAtOffset(match.start, end: match.end);
  }

  Future<ReaderBookmark?> _addBookmark({ReaderTextSelection? selection}) async {
    final layout = _chapterLayout;
    if (_loading || !_progressReady || layout == null) return null;
    _captureScrollProgress(updateTextOffset: true);
    final offset = selection?.start ?? _textOffset;
    final block = layout.blockAtOffset(offset);
    // The chapter top is the title block, so excerpting from the current
    // offset alone would store the chapter title instead of body text. Keep
    // the saved position and take the excerpt from the first body paragraph.
    ReaderContentBlock? excerptBlock;
    if (selection == null && (block?.isTitle ?? false)) {
      for (final candidate in layout.blocks) {
        if (candidate.start < offset ||
            candidate.isTitle ||
            candidate.isImage ||
            candidate.lines.isEmpty) {
          continue;
        }
        excerptBlock = candidate;
        break;
      }
    }
    final start = excerptBlock?.start ?? offset;
    final end = selection?.end ?? excerptBlock?.end ?? block?.end ?? offset;
    final excerpt = layout.textInRange(start, end).trim();
    final bookmark = ReaderBookmark(
      bookId: widget.bookId,
      chapterId: _chapter.itemId,
      title: _chapter.title,
      text: excerpt.length > 240 ? excerpt.substring(0, 240) : excerpt,
      sourceOffset: layout.sourceOffsetForDisplay(offset),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _bookmarkStore.add(bookmark);
    return bookmark;
  }

  Future<void> _showBookmarks() async {
    final generation = ++_readerNavigationGeneration;
    _stopAutoTurn();
    _readerPanelOpen = true;
    _setControlsVisible(false);
    final preset = _effectivePreset;
    final mark = await showJellySheet<ReaderBookmark>(
      context: context,
      reduceMotion: _reduceReaderMotion,
      surfaceWrapper: (child) => _readerOverlay(preset, child),
      builder: (_) => ReaderBookmarksPanel(
        bookId: widget.bookId,
        preset: preset,
        store: _bookmarkStore,
        onAdd: _addBookmark,
      ),
    );
    if (!mounted || mark == null || generation != _readerNavigationGeneration) {
      return;
    }
    final previous = _bookmarkNavigationTask;
    final task = () async {
      try {
        await previous;
      } catch (_) {
        // A failed earlier navigation must not poison the latest request.
      }
      if (!mounted || generation != _readerNavigationGeneration) return;
      await _navigateBookmark(mark, generation);
    }();
    _bookmarkNavigationTask = task;
    try {
      await task;
    } catch (_) {
      if (mounted && generation == _readerNavigationGeneration) {
        _showMessage('书签暂时无法打开，请重试');
      }
    } finally {
      if (identical(task, _bookmarkNavigationTask)) {
        _bookmarkNavigationTask = null;
      }
    }
  }

  Future<void> _navigateBookmark(ReaderBookmark mark, int generation) async {
    final target = widget.chapters.indexWhere(
      (c) => c.itemId == mark.chapterId,
    );
    if (target < 0) {
      _showMessage('目录中已找不到这条书签的章节');
      return;
    }
    _takeOverListening();
    if (target != _index) {
      await _jumpToChapter(target, navigationGeneration: generation);
    }
    if (!mounted ||
        generation != _readerNavigationGeneration ||
        _chapter.itemId != mark.chapterId ||
        _error != null) {
      return;
    }
    // Chapter loading completes before the layout's restore callback. Wait for
    // that actual frame, otherwise its restore would overwrite the bookmark.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        generation != _readerNavigationGeneration ||
        _chapter.itemId != mark.chapterId) {
      return;
    }
    final layout = _chapterLayout;
    if (layout == null || !_progressReady) {
      _showMessage('正文尚未就绪，请稍后打开书签');
      return;
    }
    final offset = layout.displayOffsetForSource(mark.sourceOffset);
    final block = layout.blockAtOffset(offset);
    await _landAtOffset(offset, end: block?.end);
  }

  Future<void> _landAtOffset(int offset, {int? end}) async {
    final layout = _chapterLayout;
    if (layout == null || !_progressReady || _loading) return;
    _takeOverListening();
    _closeSelectionBar(clearSelection: true);
    final start = offset.clamp(0, layout.textLength);
    if (_paged) {
      _pagedKey.currentState?.followPage(layout.pageForOffset(start));
    } else {
      _jumpScroll(layout.scrollForTextOffset(start));
    }
    // Reuse the non-layout-affecting selection paint, not its handles/menu.
    _locationHighlightTimer?.cancel();
    _setState(() {
      final stop = (end ?? start + 1).clamp(start, layout.textLength);
      _locationHighlight = stop > start
          ? ReaderTextSelection(start: start, end: stop)
          : null;
    });
    _locationHighlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _clearLocationHighlight();
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !identical(_chapterLayout, layout)) return;
    _captureScrollProgress(updateTextOffset: true);
    await _persistProgress();
  }

  Widget _readerOverlay(ReaderThemePreset preset, Widget child) => Theme(
    data: preset.theme(Theme.of(context)),
    child: PerformanceScope(
      preferences: preset.isEink
          ? const PerformancePreferences(enabled: true)
          : PerformanceScope.of(context),
      explicitReduceMotion: _reduceReaderMotion,
      child: child,
    ),
  );

  void _clearLocationHighlight() {
    _locationHighlightTimer?.cancel();
    if (_locationHighlight != null) {
      _setState(() => _locationHighlight = null);
    }
  }
}
