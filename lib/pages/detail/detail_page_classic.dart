part of '../detail_page.dart';

/// Classic phone detail page (经典主题).
///
/// Restored from fqapp-backup@f329399 `pages/detail_page.dart` (`build` /
/// `_phoneBody` / `_content`): a plain Material AppBar, the hero masthead,
/// 简介, the 目录 preview, 书评, the ID row and the fixed bottom read bar.
///
/// Presentation only. The page keeps one [_DetailPageState]: every entry here
/// calls the same handler the 档案 layout uses (续读/直读, 目录 sheet and
/// volumes, 评论, 入架, 听书, 整本下载/TXT, 重试), so nothing in this file
/// loads, persists or navigates on its own. The Windows desktop workspace
/// (`_desktopBody`) is shared by both styles and stays untouched.
extension _DetailPageClassic on _DetailPageState {
  /// `Scaffold` of the classic phone layout.
  Widget _buildClassicPage(BuildContext context, HomePalette palette) =>
      Scaffold(
        key: const Key('detail_classic_page'),
        backgroundColor: palette.canvas,
        appBar: _classicAppBar(context, palette),
        body: _classicPhoneBody(context, palette),
        bottomNavigationBar: ClassicDetailReadBar(
          label: _readBarLabel,
          opening: _opening,
          enabled: _supported && !_loading && _allChapters.isNotEmpty,
          actionsEnabled: _supported && _isBook,
          onRead: () => unawaited(_openLastPosition()),
          onListen: _isBook ? () => unawaited(_openListening()) : null,
          onDownload: _isBook ? () => unawaited(_showDownloadSheet()) : null,
          download: _isBook ? _downloadProgress : null,
        ),
      );

  /// Old header: back on the left, 本书 AI / 书架 on the right, no glass and no
  /// frosted scroll blur. 听书 and 下载 live in the read bar, as before.
  ///
  /// The old bar carried no text title at all. The kind label (`小说详情` …) is
  /// kept here so the classic phone page still says what it opened, matching
  /// the archive header and the 书旗/author bars; it ellipsizes on narrow
  /// screens instead of pushing the two entries off the row.
  PreferredSizeWidget _classicAppBar(
    BuildContext context,
    HomePalette palette,
  ) => AppBar(
    backgroundColor: palette.canvas,
    surfaceTintColor: Colors.transparent,
    scrolledUnderElevation: 0,
    elevation: 0,
    toolbarHeight: 52,
    leadingWidth: 56,
    leading: Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Center(
        child: IconButton(
          key: const Key('detail_classic_back'),
          tooltip: '返回',
          onPressed: () => Navigator.maybePop(context),
          style: IconButton.styleFrom(
            foregroundColor: palette.ink,
            fixedSize: const Size(36, 36),
            minimumSize: const Size(36, 36),
            padding: EdgeInsets.zero,
          ),
          icon: const Icon(LucideIcons.chevron_left, size: 20),
        ),
      ),
    ),
    titleSpacing: 0,
    title: Text(
      _pageTitle,
      key: const Key('detail_page_title'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: palette.ink,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
    actions: [
      if (_isBook && _allChapters.isNotEmpty)
        IconButton(
          key: const Key('detail_action_ai'),
          tooltip: '本书 AI 阅读优化',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AiBookSettingsPage(
                bookId: _contentId,
                title: widget.item.title,
                chapters: _allChapters,
              ),
            ),
          ),
          icon: const Icon(LucideIcons.sparkles, size: 20),
        ),
      Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: ShelfStore.instance.listenable,
            builder: (context, _, _) => DetailShelfPill(
              inShelf: _inShelf,
              enabled: !_loading && _supported,
              onTap: _toggleShelf,
            ),
          ),
        ),
      ),
    ],
  );

  /// Hero + 简介 / 目录预览 / 书评 / ID, in the old order.
  Widget _classicPhoneBody(BuildContext context, HomePalette palette) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 840),
      // The mockup resets CSS letter-spacing to normal; Material's body styles
      // carry 0.25, which reflows CJK paragraphs by a character per line.
      child: DefaultTextStyle.merge(
        style: const TextStyle(letterSpacing: 0),
        child: RefreshIndicator(
          onRefresh: _load,
          color: palette.eink ? palette.ink : HomePalette.accent,
          backgroundColor: palette.surface,
          child: CustomScrollView(
            key: const Key('detail_scroll'),
            controller: _scroll,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: KeyedSubtree(
                  key: contentAnchorKey('hero'),
                  child: DetailHero(
                    item: widget.item,
                    detail: _bookDetail,
                    onOpenAuthor: _openAuthorAction,
                    lastChapterTitle: _latestChapterTitle,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: !_supported
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: homeGutter,
                        ),
                        child: _stateCard(
                          icon: LucideIcons.file_question_mark,
                          title: '暂不支持此内容类型',
                          message: '可以返回继续发现其他故事。',
                        ),
                      )
                    : _loading
                    ? _loadingView(palette)
                    : _classicContent(palette),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _classicContent(HomePalette palette) {
    final hasReviews =
        _comments.comments.isNotEmpty || _comments.totalCount > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(
          key: contentAnchorKey('synopsis'),
          child: _classicIntroSection(),
        ),
        KeyedSubtree(
          key: contentAnchorKey('directory'),
          child: _classicDirectorySection(),
        ),
        KeyedSubtree(
          key: contentAnchorKey('reviews'),
          child: _reviewsSection(
            palette,
            hasReviews: hasReviews,
            showEmpty: false,
          ),
        ),
        KeyedSubtree(
          key: contentAnchorKey('id'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: DetailIdRow(id: _contentId),
          ),
        ),
      ],
    );
  }

  /// 简介: the summary the 档案 body resolves plus the cast row when the series
  /// payload has one. The expansion flag lives in the page state, so folding or
  /// unfolding survives the classic ⇄ archive swap.
  Widget _classicIntroSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_detailError != null) ...[
          const DetailSectionHeader(title: '简介'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: DetailInlineError(message: _detailError!, onRetry: _load),
          ),
        ] else
          DetailDescription(
            text: _synopsisText,
            expanded: _synopsisExpanded,
            onExpandedChanged: _setSynopsisExpanded,
          ),
        if (_series.cast.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(homeGutter, 18, homeGutter, 0),
            child: DetailCastRow(cast: _series.cast),
          ),
      ],
    );
  }

  /// `完结 共820章 · 全部 ›` — the old preview heading. A single-episode
  /// fallback catalogue must not present its length as the episode count.
  String get _classicDirectoryTrailing {
    if (_allChapters.isEmpty) return '';
    if (_isVideo && !hasCompleteEpisodeCatalogue(_allChapters)) {
      return '完整目录暂不可用';
    }
    final status = _bookDetail?.statusLabel ?? '';
    final count = '共${_allChapters.length}$_chapterUnit';
    return '${status.isEmpty ? '' : '$status '}$count · 全部';
  }

  /// The old 目录 preview: the reader's own slice (current ±1, or the first
  /// three) in catalogue order, with `全部 ›` opening the searchable sheet.
  ///
  /// Catalogue order is deliberately not shared here: 档案's inline catalogue
  /// reads/writes `CatalogueOrderPreferences`, while this preview always keeps
  /// the order the reader stores, and the sheet's own 正序/倒序 only applies to
  /// that visit (reopening it starts at 正序 in both styles).
  Widget _classicDirectorySection() {
    // 全局集号未知时，「已读 N%」的 N 没有意义，不展示进度行。
    final complete = !_isVideo || hasCompleteEpisodeCatalogue(_allChapters);
    return ClassicDetailDirectorySection(
      trailing: _classicDirectoryTrailing,
      preview: _previewChapters(),
      currentIndex: _previewCurrentIndex(),
      resumeIndex: complete ? _resumeIndex : null,
      chapterCount: complete ? _allChapters.length : 0,
      readTimeLabel: _resumeTimeLabel(),
      error: _directoryError,
      onOpenAll: () => unawaited(_openDirectory()),
      onRetry: () => unawaited(_load()),
      onOpenChapter: (chapter) => unawaited(_openChapter(chapter)),
    );
  }

  List<Chapter> _previewChapters() =>
      _classicPreviewChapters(_allChapters, _resumeIndex);

  /// Index of the current chapter inside [_previewChapters], or null.
  int? _previewCurrentIndex() {
    final current = _resumeIndex;
    if (current == null || _allChapters.isEmpty) return null;
    final id = _allChapters[current.clamp(0, _allChapters.length - 1)].itemId;
    final index = _previewChapters().indexWhere(
      (chapter) => chapter.itemId == id,
    );
    return index < 0 ? null : index;
  }
}

/// The chapter rows the classic directory preview shows: current ±1, or the
/// first three when the reader has no saved place.
List<Chapter> _classicPreviewChapters(
  List<Chapter> chapters,
  int? resumeIndex,
) {
  if (chapters.isEmpty) return const [];
  if (resumeIndex == null) {
    return chapters.take(_classicPreviewChapterCount).toList(growable: false);
  }
  final last = chapters.length - 1;
  final start = (resumeIndex.clamp(0, last) - 1).clamp(
    0,
    (chapters.length - _classicPreviewChapterCount).clamp(0, last),
  );
  final end = (start + _classicPreviewChapterCount).clamp(0, chapters.length);
  return chapters.sublist(start, end);
}
