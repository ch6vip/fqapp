part of '../reader_page.dart';

extension _ReaderJoinedContent on _ReaderPageState {
  bool get _joined =>
      !_paged &&
      _preferences.scrollChapterMode == ReaderScrollChapterMode.joined;
  double _joinedScrollRemainder(ReaderLayoutSpec spec) {
    final previous = _chapterLayout;
    final position = _joinedKey.currentState?.position;
    if (!_joined || previous?.spec != spec || position?.index != _index) {
      return 0;
    }
    return position!.scroll - previous!.scrollForTextOffset(_textOffset);
  }

  void _jumpScroll(double offset) {
    if (_joined && _joinedKey.currentState != null) {
      _joinedKey.currentState!.jumpToChapterOffset(_index, offset);
    } else if (_scrollController.hasClients) {
      _scrollController.jumpTo(
        offset.clamp(0, _scrollController.position.maxScrollExtent),
      );
    }
  }

  Future<JoinedReaderChapter> _loadJoinedChapter(
    int index,
    ReaderLayoutSpec spec,
  ) async {
    final chapter = widget.chapters[index];
    final ideasFuture = _joinedIdeas(chapter);
    final marksFuture = _joinedMarks(chapter);
    final loaded = await _chapterText(chapter);
    final content = ChapterContent.fromCacheText(loaded.text);
    if (content.withoutLeadingTitle(chapter.title).isEmpty) {
      throw ApiException('正文为空');
    }
    await _replacementStore.load();
    final replacement =
        await (widget.replacementEngine ?? TextReplacementEngine.instance)
            .transform(
              source: content,
              chapterTitle: chapter.title,
              snapshot: _replacementStore.snapshot,
            );
    final ideas = await ideasFuture;
    final marks = await marksFuture;
    if (!mounted) throw StateError('Reader disposed');
    final layout = ReaderChapterLayout(
      title: chapter.title,
      content: content,
      replacement: replacement,
      spec: spec,
      paragraphBubbles: _preferences.showParagraphBubbles
          ? ideas.bubbleCounts
          : const {},
      paragraphBubbleVariants: _preferences.showParagraphBubbles
          ? ideas.bubbleVariants
          : const {},
      underlinedParagraphs: marks.ids,
      bubbleBuilder: (paraIndex, count, variant) => ReaderParagraphBubble(
        count: count,
        metrics: ReaderBubbleMetrics.forFontSize(
          spec.textScaler.scale(spec.bodyStyle.fontSize!),
          variant: variant,
        ),
        preset: _effectivePreset,
        onTap: () => unawaited(
          _showIdeas(
            focusParaIndex: paraIndex,
            sourceChapter: chapter,
            sourceIdeas: ideas,
          ),
        ),
      ),
    );
    return JoinedReaderChapter(
      loaded.text,
      content,
      replacement,
      layout,
      ideas: ideas,
      underlines: marks.ids,
      rangeUnderlines: marks.ranges,
    );
  }

  Future<ChapterIdeas> _joinedIdeas(Chapter chapter) async {
    if (widget.localOnly ||
        widget.ideasLoader == null && widget.chapterCache != null) {
      return ChapterIdeas.empty;
    }
    try {
      return await (widget.ideasLoader ?? _defaultIdeas)(chapter.itemId);
    } catch (_) {
      return ChapterIdeas.empty;
    }
  }

  Future<({Set<int> ids, List<ReaderRangeUnderline> ranges})> _joinedMarks(
    Chapter chapter,
  ) async {
    if (widget.underlineStore == null && !ReaderUnderlineStore.hiveReady) {
      return (ids: <int>{}, ranges: <ReaderRangeUnderline>[]);
    }
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    try {
      final saved = await store.load(widget.bookId, chapter.itemId);
      final ranges = await store.loadRanges(widget.bookId, chapter.itemId);
      return (ids: {for (final mark in saved.values) mark.id}, ranges: ranges);
    } catch (_) {
      return (ids: <int>{}, ranges: <ReaderRangeUnderline>[]);
    }
  }

  void _onJoinedPosition(JoinedReaderPosition position) {
    if (!mounted || !_joined || !_progressReady || _changingChapter) return;
    final changed = position.index != _index;
    if (position.index != _index) {
      _settleReadTime();
      _pauseListenFollow();
      _closeSelectionBar(clearSelection: true);
      final chapter = position.chapter;
      _setState(() {
        _index = position.index;
        ++_loadGeneration;
        _content = chapter.text;
        _chapterContent = chapter.content;
        _replacement = chapter.replacement;
        _chapterLayout = chapter.layout;
        _ideas = chapter.ideas;
        _underlines = chapter.underlines;
        _rangeUnderlines = chapter.rangeUnderlines;
        _layoutIdeasRevision = ++_ideasRevision;
        _layoutUnderlineRevision = ++_underlineRevision;
        _narrationRange = null;
      });
      _saveTimer?.cancel();
    }
    _lastPosition = position.scroll;
    _lastMaxScroll = position.chapter.layout.maxScroll;
    _textOffset = position.chapter.layout.textOffsetAtScroll(position.scroll);
    if (changed) unawaited(_persistProgress());
  }

  Widget _buildJoinedContent(
    ReaderChapterLayout layout,
    ReaderSelectionScope scope,
  ) {
    return ReaderJoinedScroll(
      key: _joinedKey,
      controller: _scrollController,
      index: _index,
      chapter: JoinedReaderChapter(
        _content,
        _chapterContent,
        _replacement,
        layout,
        ideas: _ideas,
        underlines: _underlines,
        rangeUnderlines: _rangeUnderlines,
      ),
      chapterCount: widget.chapters.length,
      showParagraphBubbles: _preferences.showParagraphBubbles,
      loader: _loadJoinedChapter,
      onChapterComments: (index, chapter) => unawaited(
        _showIdeas(
          focusParaIndex: chapter.ideas.paragraphs.last.paraIndex,
          sourceChapter: widget.chapters[index],
          sourceIdeas: chapter.ideas,
        ),
      ),
      onPosition: _onJoinedPosition,
      onDragStart: () {
        _closeSelectionBar(clearSelection: true);
        _hideControlsOnDrag();
      },
      blockBuilder: (index, chapterLayout, block) {
        final active = index == _index;
        return ReaderBlockContent(
          block: block,
          spec: chapterLayout.spec,
          imageProviderFactory: widget.imageProviderFactory,
          selectionScope: active ? scope : null,
          selection: active ? _selection : null,
          rangeUnderlines: active ? _displayRangeUnderlines : const [],
          narrationRange: active ? _narrationRange : null,
          onParagraphLongPress: (block, global) {
            if (!active) {
              final state = _joinedKey.currentState;
              final chapter = state?.chapterAt(index);
              if (state == null || chapter == null) return;
              _onJoinedPosition(
                JoinedReaderPosition(
                  index,
                  chapter,
                  (_scrollController.offset - state.chapterStart(index)).clamp(
                    0,
                    double.infinity,
                  ),
                  state.chapterStart(index),
                ),
              );
              if (_index != index) return;
            }
            unawaited(_onParagraphLongPress(block, global));
          },
          onParagraphLongPressMoveUpdate: active
              ? _onParagraphLongPressMoveUpdate
              : null,
          onParagraphLongPressEnd: active ? _onParagraphLongPressEnd : null,
        );
      },
    );
  }
}
