part of '../reader_page.dart';

/// Paragraph selection, the action bar and underlines.
extension _ReaderPageSelection on _ReaderPageState {
  List<ReaderRangeUnderline> get _displayRangeUnderlines {
    final layout = _chapterLayout;
    if (layout == null) return _rangeUnderlines;
    final marks = <ReaderRangeUnderline>[
      for (final mark in _rangeUnderlines)
        if (layout.displayOffsetForSource(
              mark.end,
              bias: TextBoundaryBias.end,
            ) >
            layout.displayOffsetForSource(mark.start))
          ReaderRangeUnderline(
            bookId: mark.bookId,
            chapterId: mark.chapterId,
            start: layout.displayOffsetForSource(mark.start),
            end: layout.displayOffsetForSource(
              mark.end,
              bias: TextBoundaryBias.end,
            ),
            text: mark.text,
            createdAt: mark.createdAt,
            dashed: mark.dashed,
          ),
    ];
    // AI changes are display-only marks, not user underlines. They live in
    // final display coordinates and never enter the underline store.
    final markStyle = AiReadingController.instance.settings
        .resolve(widget.bookId)
        .markStyle;
    final composition = _currentAiView?.composition;
    final spans = composition?.displaySpans.isNotEmpty == true
        ? composition!.displaySpans
        : composition?.applied?.spans ?? const <AiEditSpan>[];
    // AI spans are body-relative; ReaderChapterLayout prepends the chapter
    // title, so shift them to the layout's display coordinates.
    final bodyStart = layout.blocks.length > 1 ? layout.blocks[1].start : 0;
    if (!_aiTemporaryOriginal && markStyle != 'off' && spans.isNotEmpty) {
      for (final span in spans) {
        final range = _minimalChangeRange(
          span,
          layout.textLength - bodyStart,
          bodyStart,
        );
        if (range == null) continue;
        marks.add(
          ReaderRangeUnderline(
            bookId: widget.bookId,
            chapterId: _chapter.itemId,
            start: range.start,
            end: range.end,
            text: span.replacement,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            dashed: markStyle == 'dotted',
            deletion: range.deletion,
            payload: span,
          ),
        );
      }
    }
    return marks;
  }

  Future<void> _onParagraphLongPress(
    ReaderContentBlock block,
    Offset position,
  ) async {
    if (block.isTitle || block.isImage || block.textId == null) return;
    _clearLocationHighlight();
    _longPressDragging = false;
    // 选中文字,暂停自动翻页 — the official selection helper does the same
    // (selection/h.java#a).
    _stopAutoTurn();
    // A second long press replaces the selection; the old bar pops without
    // cancelling — the new selection takes over.
    _closeSelectionBar(clearSelection: false);
    if (!mounted) return;
    // 官方 ke5.a.a 的 SelectTextByRange 分支: long-pressing text that already
    // carries a range underline restores that exact range instead of the
    // whole paragraph.
    ReaderRangeUnderline? hit;
    final pressed = _marksScope?.geometry.chapterOffsetAt(position);
    if (pressed != null) {
      for (final underline in _displayRangeUnderlines) {
        if (underline.start <= pressed && pressed < underline.end) {
          hit = underline;
          break;
        }
      }
    }
    final selection = ReaderTextSelection(
      start: hit?.start ?? block.start,
      end: hit?.end ?? block.end,
    );
    _setState(() {
      _selection = selection.copyWith(
        isWholeParagraph: _isWholeParagraphSelection(selection),
      );
    });
    _updateHandlePositions();
    _openSelectionBar(anchor: position);
  }

  /// 官方的不抬手拖动 (TTMarkingHelper 的 MOVE 分支): 长按选中后手指继续
  /// 移动,选区跟着手指逐字符重算,第一帧起收条;拖哪个点按手指落在选区的
  /// 上半还是下半推断 (D() 的中点规则),不必精确抓到控点。
  void _onParagraphLongPressMoveUpdate(Offset global) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return;
    if (!_longPressDragging) {
      _longPressDragging = true;
      _closeSelectionBar(clearSelection: false);
    }
    _onHandleDrag(_dragIsStartBound(global), global);
  }

  void _onParagraphLongPressEnd(Offset global) {
    if (!_longPressDragging) return;
    _longPressDragging = false;
    _onHandleDragEnd(false, global);
  }

  /// 官方 D(): finger above the selection's vertical midpoint drags the start
  /// bound, below it the end bound.
  bool _dragIsStartBound(Offset global) {
    final startTop = _selectionBoundGlobal(isStart: true)?.dy;
    final endBottom = _selectionBoundGlobal(isStart: false)?.dy;
    if (startTop == null || endBottom == null) return true;
    return global.dy < (startTop + endBottom) / 2;
  }

  /// Global position of one bound's anchor — the start bound's line top or
  /// the end bound's line bottom — or null when its block is not mounted.
  Offset? _selectionBoundGlobal({required bool isStart}) {
    final selection = _selection;
    final layout = _chapterLayout;
    final scope = _marksScope;
    if (selection == null || layout == null || scope == null) return null;
    final textOffset = isStart ? selection.start : selection.end - 1;
    final block = layout.blockForAnchor(textOffset, isStart: isStart);
    if (block == null) return null;
    final entry = scope.geometry.entryFor(block.index);
    if (entry == null) return null;
    final anchor = selectionAnchor(
      block: block,
      painter: entry.painter,
      textOffset: _boundOffsetInBlock(textOffset, block, isStart: isStart),
      isStart: isStart,
      columnWidth: layout.spec.width,
    );
    return entry.box.localToGlobal(anchor);
  }

  /// Opens the action bar for the current selection. The bar lives in the
  /// page's own overlay Stack — non-modal, like the official PopupWindow — so
  /// the drag handles stay touchable while it is up, and a tap outside it
  /// reaches the page surface, which cancels the selection.
  ///
  /// 官方条子锚在整个选区上,绝不遮选区([yd5.j] 的条子几何): y 取选区
  /// 末端行的行底再让开末端圆点,x 跟手指;选区顶端作为翻转参考传下去。
  void _openSelectionBar({required Offset anchor}) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return;
    final bottom = _selectionBoundGlobal(isStart: false);
    final top = _selectionBoundGlobal(isStart: true);
    _setState(() {
      _selectionBarAnchor = Offset(
        anchor.dx,
        bottom == null
            ? anchor.dy
            : bottom.dy + _ReaderPageState._barSelectionClearance,
      );
      _selectionBarTopAnchor = top;
      _selectionBarOpen = true;
    });
  }

  /// Hides the action bar; [clearSelection] also cancels the selection
  /// (outside tap, scroll, page turn — anything but a handle drag).
  void _closeSelectionBar({required bool clearSelection}) {
    if (clearSelection) _clearSelection();
    if (!_selectionBarOpen) return;
    _setState(() => _selectionBarOpen = false);
  }

  /// The action bar overlay, or null while no selection is active. Geometry
  /// re-resolves per build so the bar always clears the system bars and the
  /// reader's own bottom toolbar.
  ///
  // Note: 选区条坐标系、段落时间轴映射与批量审查回退的来龙去脉 —
  // 见 .agents/notes/implemented/bug-fix/2026-09-19-cross-review-batch-fixes.md
  /// [windowPadding] is the *window's* safe area, captured above the reader's
  /// own SafeArea: the anchor is a window coordinate while the bar is
  /// positioned inside the overlay Stack below that SafeArea (and below the
  /// reading-info row), so the anchor is converted into overlay-local space
  /// and the flip/clamp maths run against the overlay's own size. Using the
  /// window geometry directly shifted the bar one status-bar height down on
  /// every device whose top inset is non-zero.
  Widget? _selectionBar(ReaderThemePreset preset, EdgeInsets windowPadding) {
    final selection = _selection;
    if (!_selectionBarOpen || selection == null || !selection.isValid) {
      return null;
    }
    final media = MediaQuery.of(context);
    final underlined = _selectionUnderlined;
    var anchor = _selectionBarAnchor;
    var topAnchor = _selectionBarTopAnchor;
    var view = media.size;
    var safeArea = media.padding;
    var avoidBottom = _controlsVisible
        ? _ReaderPageState._bottomBarHeight
        : 0.0;
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox != null && overlayBox.attached) {
      anchor = overlayBox.globalToLocal(_selectionBarAnchor);
      topAnchor = _selectionBarTopAnchor == null
          ? null
          : overlayBox.globalToLocal(_selectionBarTopAnchor!);
      view = overlayBox.size;
      // The system insets are already consumed by the outer SafeArea, so the
      // overlay only needs a margin of its own; the reader's bottom toolbar
      // height includes the bottom inset, so subtract what SafeArea padded.
      safeArea = EdgeInsets.zero;
      avoidBottom = (avoidBottom - windowPadding.bottom).clamp(
        0.0,
        double.infinity,
      );
      final controls = _bottomControlsKey.currentContext?.findRenderObject();
      if (_controlsVisible &&
          controls is RenderBox &&
          controls.attached &&
          controls.hasSize) {
        final top = overlayBox
            .globalToLocal(controls.localToGlobal(Offset.zero))
            .dy;
        avoidBottom = (view.height - top).clamp(0.0, view.height);
      }
    } else {
      // No overlay box (loading/error fallback): the top anchor would be in a
      // different coordinate space than the bar maths — drop the flip
      // reference rather than flip to a wrong place.
      topAnchor = null;
    }
    // The classic bar has its own item metrics and an arrow that takes layout
    // space; the anchor maths must use the same numbers the bar renders with.
    // Read live so an open selection follows a style switch.
    final (position, below) = ReaderParagraphMenu.resolvePosition(
      anchor: anchor,
      topAnchor: topAnchor,
      paragraphScoped: selection.isWholeParagraph,
      view: view,
      safeArea: safeArea,
      underlined: underlined,
      showListening: true,
      showBookmark: true,
      showAi: _currentAiView?.aiEnabled == true,
      avoidBottom: avoidBottom,
      classic: AppUiScope.isClassic(context),
    );
    return Positioned(
      key: const ValueKey('reader-selection-bar'),
      left: position.dx,
      top: position.dy,
      child: ReaderParagraphMenu(
        underlined: underlined,
        paragraphScoped: selection.isWholeParagraph,
        showListening: true,
        showBookmark: true,
        maxWidth: (view.width - 20).clamp(0.0, double.infinity),
        showAi: _currentAiView?.aiEnabled == true,
        isDark: preset.isDark,
        belowAnchor: below,
        onAction: (action) {
          unawaited(() async {
            await _applySelectionAction(action);
            // Every action consumes the selection, like the official bar.
            if (mounted) _closeSelectionBar(clearSelection: true);
          }());
        },
      ),
    );
  }

  void _clearSelection() {
    _longPressDragging = false;
    if (_selection == null) return;
    _setState(() => _selection = null);
  }

  bool _markMatchesSelection(
    ReaderRangeUnderline mark,
    ReaderTextSelection selection,
  ) {
    final layout = _chapterLayout;
    return layout != null &&
        layout.displayOffsetForSource(mark.start) == selection.start &&
        layout.displayOffsetForSource(mark.end, bias: TextBoundaryBias.end) ==
            selection.end;
  }

  bool get _selectionUnderlined {
    final selection = _selection;
    if (selection == null) return false;
    if (selection.isWholeParagraph) {
      final textId = _chapterLayout?.blockAtOffset(selection.start)?.textId;
      if (textId != null && _underlines.contains(textId)) return true;
    }
    // A range record spanning exactly this selection outranks the paragraph
    // identity: a whole-paragraph drag can produce one, and only the range
    // store can ever remove it again.
    return _rangeUnderlines.any(
      (underline) => _markMatchesSelection(underline, selection),
    );
  }

  Future<void> _applySelectionAction(ReaderParagraphAction action) async {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null || !selection.isValid) return;
    switch (action) {
      case ReaderParagraphAction.copy:
        await Clipboard.setData(
          ClipboardData(
            text: layout.textInRange(selection.start, selection.end),
          ),
        );
        if (mounted) _showMessage('已复制');
      case ReaderParagraphAction.listen:
        final block = layout.blockAtOffset(selection.start);
        final textId = block?.textId;
        if (block == null || textId == null) return;
        await _openListening(fromMs: block.startMs, textId: textId);
      case ReaderParagraphAction.bookmark:
        try {
          final bookmark = await _addBookmark(selection: selection);
          if (mounted) _showMessage(bookmark == null ? '阅读位置尚未就绪' : '已保存书签');
        } catch (_) {
          if (mounted) _showMessage('书签保存失败，请重试');
        }
      case ReaderParagraphAction.underline:
      case ReaderParagraphAction.removeUnderline:
        await _toggleSelectionUnderline(
          add: action == ReaderParagraphAction.underline,
        );
      case ReaderParagraphAction.missedChange:
        await _markMissedSelection();
    }
  }

  Future<void> _markMissedSelection() async {
    final selection = _selection;
    final layout = _chapterLayout;
    final snapshot = _currentAiView?.snapshot;
    if (selection == null || layout == null || snapshot == null) return;
    final startLocation = layout.snapshotLocationForDisplayOffset(
      selection.start,
      snapshot,
      bias: TextBoundaryBias.start,
    );
    final endLocation = layout.snapshotLocationForDisplayOffset(
      selection.end,
      snapshot,
      bias: TextBoundaryBias.end,
    );
    if (startLocation == null ||
        endLocation == null ||
        startLocation.paragraph != endLocation.paragraph) {
      _showMessage('漏改了只能标在单个段落内');
      return;
    }
    final start = startLocation.offset;
    final end = endLocation.offset;
    final paragraph = startLocation.paragraph;
    if (end <= start || end > snapshot.paragraphEnd(paragraph)) {
      _showMessage('漏改了只能标在单个段落内');
      return;
    }
    final created = await showAiMissedSheet(
      context,
      bookId: widget.bookId,
      chapterId: _chapter.itemId,
      snapshot: snapshot,
      sourceStart: start,
      sourceEnd: end,
      onChanged: () {
        _aiRevision = -1;
        unawaited(_onAiChanged());
      },
    );
    if (created && mounted) _showMessage('已记录漏改了');
  }

  /// 划线 on the current selection. A whole-paragraph selection keeps the
  /// paragraph-identity store (the pre-selection model, still how saved
  /// marks render); a dragged character range saves a range record.
  Future<void> _toggleSelectionUnderline({required bool add}) async {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null || !selection.isValid) return;
    if (selection.isWholeParagraph) {
      final block = layout.blockAtOffset(selection.start);
      // A range record exactly spanning the paragraph (a whole-paragraph
      // drag) must be toggled in the range store — routing to the
      // paragraph-identity store here would strand it, unreachable for
      // 删除划线 forever.
      final hasExactRange = _rangeUnderlines.any(
        (underline) => _markMatchesSelection(underline, selection),
      );
      if (block != null && !hasExactRange) {
        await _toggleUnderline(block, add: add);
        return;
      }
    }
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    final chapterId = _chapter.itemId;
    final loadGeneration = _loadGeneration;
    final existing = _rangeUnderlines
        .where((underline) => _markMatchesSelection(underline, selection))
        .toList();
    if (!add && existing.isEmpty) return;
    final record = ReaderRangeUnderline(
      bookId: widget.bookId,
      chapterId: chapterId,
      start: layout.sourceOffsetForDisplay(selection.start),
      end: layout.sourceOffsetForDisplay(
        selection.end,
        bias: TextBoundaryBias.end,
      ),
      text: layout.sourceTextInRange(
        layout.sourceOffsetForDisplay(selection.start),
        layout.sourceOffsetForDisplay(
          selection.end,
          bias: TextBoundaryBias.end,
        ),
      ),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      if (add) {
        await store.addRange(record);
      } else {
        for (final mark in existing) {
          await store.remove(mark.key);
        }
      }
    } catch (_) {
      if (mounted) _showMessage(add ? '划线保存失败，请重试' : '删除划线失败，请重试');
      return;
    }
    // The await can span a chapter switch; appending a record that belongs to
    // the previous chapter would paint it onto the new one (the same guard
    // _loadUnderlines applies to its reads).
    if (!mounted ||
        loadGeneration != _loadGeneration ||
        chapterId != _chapter.itemId) {
      return;
    }
    _setState(() {
      if (add) {
        _rangeUnderlines = [..._rangeUnderlines, record]
          ..sort((a, b) => a.start.compareTo(b.start));
      } else {
        _rangeUnderlines = _rangeUnderlines
            .where(
              (underline) => !existing.any((mark) => mark.key == underline.key),
            )
            .toList();
      }
    });
    _showMessage(add ? '已划线' : '已删除划线');
  }

  Future<void> _toggleUnderline(
    ReaderContentBlock block, {
    required bool add,
  }) async {
    final textId = block.textId;
    if (textId == null) return;
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    final blockIndex = block.index - 1;
    final chapterId = _chapter.itemId;
    final loadGeneration = _loadGeneration;
    try {
      if (add) {
        await store.add(
          ReaderUnderline(
            bookId: widget.bookId,
            chapterId: chapterId,
            paraIndex: block.paraIndex,
            blockIndex: blockIndex,
            text: _chapterLayout!.sourceTextInRange(
              _chapterLayout!.sourceOffsetForDisplay(block.start),
              _chapterLayout!.sourceOffsetForDisplay(
                block.end,
                bias: TextBoundaryBias.end,
              ),
            ),
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else {
        await store.remove(
          ReaderUnderlineStore.keyFor(
            bookId: widget.bookId,
            chapterId: chapterId,
            paraIndex: block.paraIndex,
            blockIndex: blockIndex,
          ),
        );
      }
    } catch (_) {
      if (mounted) _showMessage(add ? '划线保存失败，请重试' : '取消划线失败，请重试');
      return;
    }
    // The await can span a chapter switch; the ids belong to the chapter the
    // underline was toggled in (same guard as _loadUnderlines).
    if (!mounted ||
        loadGeneration != _loadGeneration ||
        chapterId != _chapter.itemId) {
      return;
    }
    _setState(() {
      final next = Set<int>.of(_underlines);
      if (add) {
        next.add(textId);
      } else {
        next.remove(textId);
      }
      _underlines = next;
      ++_underlineRevision;
    });
    _showMessage(add ? '已划线' : '已取消划线');
  }

  /// Loads the saved 划线 of this chapter: paragraph ids for the layout and
  /// range records for the mark painter.
  Future<void> _loadUnderlines() async {
    final generation = _loadGeneration;
    final chapterId = _chapter.itemId;
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    Set<int> ids;
    List<ReaderRangeUnderline> ranges;
    try {
      final saved = await store.load(widget.bookId, chapterId);
      ids = {for (final entry in saved.values) entry.id};
      ranges = await store.loadRanges(widget.bookId, chapterId);
    } catch (_) {
      ids = const {};
      ranges = const [];
    }
    if (!mounted || generation != _loadGeneration) return;
    if (chapterId != _chapter.itemId) return;
    final cacheKey = '${widget.bookId}\u0000$chapterId';
    final previous = _underlineCache[cacheKey];
    _underlineCache[cacheKey] = (
      version: _chapter.version,
      ids: ids,
      ranges: ranges,
    );
    while (_underlineCache.length > 12) {
      _underlineCache.remove(_underlineCache.keys.first);
    }
    final unchanged =
        previous?.version == _chapter.version &&
        setEquals(previous!.ids, ids) &&
        _sameRangeUnderlines(previous.ranges, ranges);
    if (unchanged) return;
    _setState(() {
      _underlines = ids;
      _rangeUnderlines = ranges;
      ++_underlineRevision;
    });
  }
}

/// Returns the changed sub-range in final display coordinates. Prefix/suffix
/// common to the original and replacement are not marked, so a one-character
/// typo fix does not paint the whole paragraph.
({int start, int end, bool deletion})? _minimalChangeRange(
  AiEditSpan span,
  int displayLength,
  int offset,
) {
  if (span.displayEnd < span.displayStart) return null;
  final displayStart = span.displayStart + offset;
  final displayEnd = span.displayEnd + offset;
  if (span.replacement.isEmpty) {
    // Deletion has no glyph to underline. Keep a zero-width caret position so
    // the painter can draw a small vertical mark at the real deletion point.
    final position = displayStart.clamp(0, displayLength);
    return (start: position, end: position, deletion: true);
  }
  var prefix = 0;
  final maxPrefix = math.min(span.original.length, span.replacement.length);
  while (prefix < maxPrefix &&
      span.original.codeUnitAt(prefix) == span.replacement.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  final maxSuffix = math.min(
    span.original.length - prefix,
    span.replacement.length - prefix,
  );
  while (suffix < maxSuffix &&
      span.original.codeUnitAt(span.original.length - 1 - suffix) ==
          span.replacement.codeUnitAt(span.replacement.length - 1 - suffix)) {
    suffix++;
  }
  final start = (displayStart + prefix).clamp(0, displayLength);
  final end = (displayEnd - suffix).clamp(start, displayLength);
  if (end <= start) {
    if (displayLength <= 0) return null;
    final fallback = start.clamp(0, displayLength - 1);
    return (
      start: fallback,
      end: (fallback + 1).clamp(fallback + 1, displayLength),
      deletion: false,
    );
  }
  return (start: start, end: end, deletion: false);
}

/// Compares the actual ranges, not only their count. Deleting one underline
/// and adding another elsewhere keeps the count unchanged but must still
/// repaint the chapter.
bool _sameRangeUnderlines(
  List<ReaderRangeUnderline> left,
  List<ReaderRangeUnderline> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    final a = left[i];
    final b = right[i];
    if (a.bookId != b.bookId ||
        a.chapterId != b.chapterId ||
        a.start != b.start ||
        a.end != b.end ||
        a.text != b.text ||
        a.createdAt != b.createdAt ||
        a.dashed != b.dashed ||
        a.deletion != b.deletion) {
      return false;
    }
  }
  return true;
}
