part of '../reader_page.dart';

/// Paragraph ideas (段评) loading and the ideas sheet.
extension _ReaderPageIdeas on _ReaderPageState {
  /// Loads the chapter's paragraph ideas. Decoration only: a failure leaves the
  /// reader fully usable with the段评 action hidden.
  Future<void> _loadIdeas(Chapter chapter, int generation) async {
    if (widget.localOnly) return;
    final loader = widget.ideasLoader;
    if (loader == null && widget.chapterCache != null) {
      // An injected cache means the caller drives its own data; do not reach
      // for the network behind its back.
      return;
    }
    try {
      final ideas = await (loader ?? _defaultIdeas)(chapter.itemId);
      if (!mounted || generation != _loadGeneration) return;
      if (chapter.itemId != widget.chapters[_index].itemId) return;
      _setState(() {
        _ideas = ideas;
        ++_ideasRevision;
      });
      // Note: Old image-aware caches can still lack paragraph ids. Refresh
      // only when ideas need them; never fabricate ids from display order.
      // .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
      if (!_chapterContent.paragraphIdsChecked &&
          ideas.paragraphs.any((paragraph) => paragraph.showsBubble)) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (_) {
      // Keep the section hidden rather than surfacing a failure. Catches Error
      // as well as Exception: ideas are decoration, not a page-level failure.
    }
  }

  /// The in-text paragraph-comment bubble, built during layout so it can be
  /// measured as a placeholder at the end of the paragraph.
  ///
  /// Note: 气泡的门槛与几何规格取自官方客户端 — 见
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Widget _buildParagraphBubble(
    int paraIndex,
    int count,
    ParagraphBubbleVariant variant, {
    Chapter? sourceChapter,
    ChapterIdeas? sourceIdeas,
  }) => ReaderParagraphBubble(
    count: count,
    metrics: ReaderBubbleMetrics.forFontSize(
      MediaQuery.textScalerOf(context).scale(_preferences.fontSize),
      variant: variant,
    ),
    preset: _effectivePreset,
    onTap: () => unawaited(
      _showIdeas(
        focusParaIndex: paraIndex,
        sourceChapter: sourceChapter,
        sourceIdeas: sourceIdeas,
      ),
    ),
  );

  Future<void> _showIdeas({
    int? focusParaIndex,
    Chapter? sourceChapter,
    ChapterIdeas? sourceIdeas,
  }) async {
    final ideaSnapshot = sourceIdeas ?? _ideas;
    if (ideaSnapshot.isEmpty) return;
    _setState(() => _controlsVisible = false);
    final chapter = sourceChapter ?? widget.chapters[_index];
    // Keep immersive on while the sheet is open (#57): the sheet pushes a
    // route, which would otherwise release the system bars. The flag is
    // read by [_syncSystemBars] when the route change lands.
    _ideasSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        backgroundColor: _effectivePreset.isDark
            ? _effectivePreset.panelColor
            : Colors.white,
        // E-ink (#57): a dimmed scrim forces a full-screen gray wash and
        // ghosts on e-ink. Transparent keeps the page readable behind the
        // sheet; tapping outside still dismisses it.
        barrierColor: einkModeNotifier.value
            ? Colors.transparent
            : Colors.black.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        builder: (context) => FractionallySizedBox(
          // Match the supplied official screenshot, keeping the paragraph visible
          // above the comments. Note: 2026-09-11-reader-paragraph-bubble.md.
          heightFactor: 0.69,
          child: ReaderIdeasSheet(
            ideas: ideaSnapshot,
            preset: _effectivePreset,
            // Each bubble opens only that paragraph's comments.
            initialParaIndex: focusParaIndex,
            loadComments: (paragraph, cursor) async {
              final resolver = widget.commentResolver;
              if (resolver != null) {
                return resolver(chapter.itemId, paragraph, cursor);
              }
              return _defaultComments(
                chapter,
                paragraph,
                ideaSnapshot.itemVersion,
                cursor,
              );
            },
            // 回复按需展开（issue #95）。与段评正文同一套「注入即离线」
            // 约定：调用方自己提供数据时不接网络，也就不给可点的回复入口。
            replyLoader: _ideasReplyLoader(),
          ),
        ),
      );
    } finally {
      // The sheet is gone. Release the immersive hold here only if this
      // route is already current again; otherwise didChangeDependencies
      // releases it once the route regains current status (#57). The
      // sheet route stays present until its close animation ends, so an
      // unconditional release here would sync "not immersive" before
      // that notification lands and flash the status bar for a frame.
      // Guard mounted: if the reader was disposed while the sheet was
      // open, dispose already closed the device session and no stale
      // call may follow it.
      if (mounted && _routeCurrent) {
        _ideasSheetOpen = false;
        _syncSystemBars();
      }
      // 墨水屏：段评面板关闭后刷一次，清掉面板残影。
      _maybeEinkRefresh();
    }
  }

  /// Default idea fetch and comment resolution; see [ReaderPage.ideasLoader].
  Future<ChapterIdeas> _defaultIdeas(String itemId) =>
      ApiClient.instance.chapterIdeas(itemId);

  /// Loads one paragraph's comments.
  ///
  /// Note: the upstream wants `server_channel=38` here, not the 43 the official
  /// presenter assigns, and it needs the chapter version — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Future<BookCommentPage> _defaultComments(
    Chapter chapter,
    ParagraphIdeas paragraph,
    String ideaVersion,
    String? cursor,
  ) {
    return ApiClient.instance.paragraphComments(
      widget.bookId,
      chapter.itemId,
      itemVersion: chapter.version.isNotEmpty ? chapter.version : ideaVersion,
      paraIndex: paragraph.paraIndex,
      cursor: cursor,
    );
  }

  /// Loads one comment's replies for the paragraph sheet.
  ///
  /// Null when the caller injected its own comment data or when a chapter
  /// cache was injected (both mark an offline caller), which keeps the reply
  /// counter a plain read-only number for them.
  Future<CommentReplyPage> Function(String commentId)? _ideasReplyLoader() {
    if (widget.commentResolver != null ||
        widget.ideasLoader != null ||
        widget.chapterCache != null) {
      return null;
    }
    if (widget.bookId.isEmpty) return null;
    return (commentId) => ApiClient.instance.commentReplies(
      widget.bookId,
      commentId,
      groupId: widget.bookId,
    );
  }
}
