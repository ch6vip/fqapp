part of '../reader_page.dart';

/// Selection handles and the chapter-end page.
extension _ReaderPageSelectionOverlay on _ReaderPageState {
  /// The selection scope for the current layout: palette from the active
  /// theme, a fresh hit-test registry per layout so a block from the previous
  /// chapter can never answer a drag.
  ReaderSelectionScope _marksScopeFor(
    ReaderThemePreset preset,
    ReaderChapterLayout layout,
  ) {
    // 用户自定义高亮色优先，null 时跟随主题按背景派生。
    final custom = _preferences.narrationHighlightColor;
    // 样式：显式选了就用它，否则墨水屏下划线、其余背景色块。
    final narrationUnderline = _preferences.narrationUnderlineFor(preset);
    // 下划线要看得见：色块用的派生色（背景 + 10% 文字）画线几乎不可见，
    // 这里改成显式色不透明化、自动时直接用正文色（墨水屏即黑线）。
    final narration = switch ((narrationUnderline, custom)) {
      (true, final int? c) =>
        c == null ? preset.textColor : Color(c).withValues(alpha: 1),
      (false, final int? c) =>
        c == null ? preset.narrationHighlightColor : Color(c),
    };
    if (_marksScope == null ||
        !identical(_marksScopeLayout, layout) ||
        _marksScope!.narrationColor != narration ||
        _marksScope!.narrationUnderline != narrationUnderline) {
      _marksScope = ReaderSelectionScope(
        geometry: ReaderSelectionGeometry(),
        washColor: preset.selectionWashColor,
        handleColor: preset.selectionHandleColor,
        underlineColor: preset.selectionUnderlineColor,
        narrationColor: narration,
        narrationUnderline: narrationUnderline,
      );
      _marksScopeLayout = layout;
    }
    return _marksScope!;
  }

  /// The drag handles, floated above the content: handles living inside a
  /// block would fall outside every ancestor's hit-test box whenever a bound
  /// sat at the block edge (first line's top, last line's bottom, page foot).
  /// Positions resolve through the geometry registry after layout.
  List<Widget> _selectionHandles(ReaderSelectionScope scope) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return const [];
    final start = _handleCaretOverlay(isStart: true);
    final end = _handleCaretOverlay(isStart: false);
    if (start == null && end == null) return const [];

    // Ink layout (官方 yd5.j.I()): the 1dp bar runs the selected line's full
    // height; the dot protrudes 6dp beyond the line edge. Start ink hugs the
    // widget top, end ink hugs the bottom — the touch margin sits on the far
    // side of the line.
    Widget handle(bool isStart, ({double x, double top, double bottom}) caret) {
      final lineHeight = caret.bottom - caret.top;
      final widget = ReaderSelectionHandle(
        isStart: isStart,
        color: scope.handleColor,
        lineHeight: lineHeight,
        onDragStart: _onHandleDragStart,
        onDragUpdate: (global) => _onHandleDrag(isStart, global),
        onDragEnd: (global) => _onHandleDragEnd(isStart, global),
      );
      return Positioned(
        key: ValueKey('reader-selection-handle-${isStart ? 'start' : 'end'}'),
        left: caret.x - ReaderSelectionHandle.touchWidth / 2,
        top: isStart
            ? caret.top - ReaderSelectionHandle.dotOverhang
            : caret.top - ReaderSelectionHandle.touchMargin,
        child: widget,
      );
    }

    return [
      if (start != null) handle(true, start),
      if (end != null) handle(false, end),
    ];
  }

  /// Overlay-local caret of one selection bound — the glyph edge x plus the
  /// selected line's vertical extent — or null when the bound's block is not
  /// mounted (an off-screen page).
  ({double x, double top, double bottom})? _handleCaretOverlay({
    required bool isStart,
  }) {
    final selection = _selection;
    final layout = _chapterLayout;
    final scope = _marksScope;
    if (selection == null || layout == null || scope == null) return null;
    final textOffset = isStart ? selection.start : selection.end - 1;
    final block = layout.blockForAnchor(textOffset, isStart: isStart);
    if (block == null) return null;
    final entry = scope.geometry.entryFor(block.index);
    if (entry == null) return null;
    final caret = selectionCaret(
      block: block,
      painter: entry.painter,
      textOffset: _boundOffsetInBlock(textOffset, block, isStart: isStart),
      isStart: isStart,
      columnWidth: layout.spec.width,
    );
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.attached) return null;
    final origin = overlayBox.globalToLocal(
      entry.box.localToGlobal(Offset(caret.x, caret.top)),
    );
    return (
      x: origin.dx,
      top: origin.dy,
      bottom: origin.dy + caret.bottom - caret.top,
    );
  }

  /// [offset] (chapter space) resolved into [block]'s text space, snapping a
  /// separator offset onto the block's first or last real character.
  int _boundOffsetInBlock(
    int offset,
    ReaderContentBlock block, {
    required bool isStart,
  }) {
    return isStart
        ? offset.clamp(block.start, block.end - 1) - block.start
        : (offset + 1 > block.end ? block.end : offset + 1) - 1 - block.start;
  }

  /// Recomputes the handle overlay after the frame that (re)mounted the mark
  /// layers — their registry entries land in a post-frame callback of the
  /// same build, scheduled ahead of this one.
  void _updateHandlePositions() {
    if (_selection == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selection == null) return;
      _setState(() {});
    });
  }

  void _onHandleDragStart() {
    // The bar would sit under the finger; pop it, keep the selection.
    _closeSelectionBar(clearSelection: false);
  }

  /// Reshapes the selection to the character under the finger. The drag
  /// starts on a handle but crosses paragraphs, so the point resolves
  /// through the geometry registry, not the handle's own block.
  // Note: 拖动边界对齐官方（非空不变量、分隔符守卫）—
  // 见 .agents/notes/implemented/bug-fix/2026-09-19-selection-drag-boundary.md
  void _onHandleDrag(bool isStart, Offset global) {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null) return;
    final offset = _marksScope?.geometry.chapterOffsetAt(global);
    if (offset == null) return;
    final range = layout.selectableTextRange;
    if (range == null) return;
    var next = selection.withBound(
      isStart: isStart,
      offset: offset.clamp(range.$1, range.$2),
      textLength: range.$2,
    );
    // A drag can land a bound on the '\n' separator between two blocks; such
    // a range paints nothing, so grow it onto the next real character — the
    // finger must never hold an invisible selection.
    if (next.isValid && next.end < range.$2 && _selectionPaintsNothing(next)) {
      next = next.copyWith(end: next.end + 1);
    }
    if (next == selection) return;
    _setState(() => _selection = next);
  }

  /// True when no text block overlaps [selection] — a range covering only
  /// the separators between blocks.
  bool _selectionPaintsNothing(ReaderTextSelection selection) {
    final layout = _chapterLayout;
    if (layout == null) return true;
    for (final block in layout.blocks) {
      if (block.isTitle || block.isImage) continue;
      if (blockSelectionRange(block, selection.start, selection.end) != null) {
        return false;
      }
    }
    return true;
  }

  void _onHandleDragEnd(bool isStart, Offset global) {
    final selection = _selection;
    if (selection == null || !selection.isValid) {
      _clearSelection();
      return;
    }
    // Whatever the drag did, the range is no longer necessarily the
    // long-pressed paragraph: recompute the flag from the geometry so
    // 从本段听 tracks the real range instead of inheriting the long press.
    _setState(
      () => _selection = selection.copyWith(
        isWholeParagraph: _isWholeParagraphSelection(selection),
      ),
    );
    _openSelectionBar(anchor: global);
  }

  /// True when [selection] covers exactly one non-title text block — the
  /// shape a long press creates. Computed, not inherited: a drag that happens
  /// to land on another whole paragraph deserves the same bar.
  bool _isWholeParagraphSelection(ReaderTextSelection selection) {
    final block = _chapterLayout?.blockAtOffset(selection.start);
    return block != null &&
        !block.isTitle &&
        !block.isImage &&
        selection.start == block.start &&
        selection.end == block.end;
  }

  /// The final chapter keeps a stable completion page. Other chapters go
  /// directly to the next text page; their comments are in the reader toolbar.
  Widget _buildChapterEndPage(ReaderThemePreset preset) {
    final endBucket = _chapterEndParagraph();
    final commentCount = _ideas.total;
    return ColoredBox(
      color: preset.backgroundColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '本章完',
              style: TextStyle(color: preset.mutedTextColor, fontSize: 13),
            ),
            const SizedBox(height: 20),
            if (commentCount > 0 && endBucket != null)
              FilledButton.tonal(
                key: const ValueKey('reader-chapter-comments'),
                onPressed: () =>
                    unawaited(_showIdeas(focusParaIndex: endBucket)),
                child: Text('查看本章评论 · $commentCount'),
              ),
          ],
        ),
      ),
    );
  }

  /// The chapter-end aggregate bucket: the ideas response's greatest paragraph
  /// key (e.g. para 10000), which the official client opens for 章末章评.
  int? _chapterEndParagraph() =>
      _ideas.paragraphs.isEmpty ? null : _ideas.paragraphs.last.paraIndex;

  void _hideControlsOnDrag() {
    _stopAutoTurn();
    _takeOverListening();
    if (_controlsVisible) _setControlsVisible(false);
  }
}
