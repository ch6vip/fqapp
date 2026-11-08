part of '../shuqi_detail_page.dart';

/// Classic 书旗 detail page (经典主题).
///
/// Restored from fqapp-backup@f329399 `pages/shuqi_detail_page.dart`: a plain
/// Material AppBar carrying the book title, the old header (cover, title,
/// author, meta line, 开始阅读), the clamped intro, the 目录 status row and the
/// chapter list.
///
/// Display only. It reads the same `_book` / `_toc` / loader state as the 档案
/// layout, and the chapter rows stay a lazy `SliverList` so a 400+ chapter 书旗
/// catalogue still builds only what is on screen. Opening a chapter keeps the
/// read-only `shuqi:<id>` namespace and store from `_openChapter`.
extension _ShuqiDetailClassic on _ShuqiDetailPageState {
  Widget _buildClassicPage(BuildContext context, HomePalette palette) {
    return Scaffold(
      key: const Key('shuqi-detail-classic-page'),
      backgroundColor: palette.canvas,
      appBar: AppBar(
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
              key: const Key('shuqi-detail-back'),
              tooltip: '返回',
              onPressed: () => Navigator.maybePop(context),
              style: IconButton.styleFrom(
                foregroundColor: palette.ink,
                fixedSize: const Size(36, 36),
                minimumSize: const Size(36, 36),
                padding: EdgeInsets.zero,
              ),
              icon: const Icon(Icons.chevron_left, size: 22),
            ),
          ),
        ),
        titleSpacing: 0,
        title: Text(
          _title,
          key: const Key('shuqi-detail-appbar-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: _classicBody(context, palette),
    );
  }

  Widget _classicBody(BuildContext context, HomePalette palette) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error,
                key: const Key('shuqi-detail-error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.muted, fontSize: 13),
              ),
              const SizedBox(height: 14),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final book = _book;
    if (book == null) {
      return Center(
        child: Text(
          '没有取到书籍数据',
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
      );
    }
    final toc = _toc;
    final chapters = toc?.chapters ?? const <ShuqiChapter>[];
    final showingChapters = _tocError == null && !_tocLoading && toc != null;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: CustomScrollView(
          key: const Key('shuqi-detail-scroll'),
          controller: _scroll,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: KeyedSubtree(
                key: contentAnchorKey('header'),
                child: _classicHeader(context, palette, book, toc),
              ),
            ),
            SliverToBoxAdapter(child: _classicTocStatus(palette)),
            if (showingChapters)
              SliverList.builder(
                itemCount: chapters.length,
                itemBuilder: (context, index) => _classicChapterRow(
                  context,
                  palette,
                  chapters[index],
                  index,
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + 24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Old header: cover, title, author, meta, 开始阅读, the clamped intro, then
  /// the 目录 row with the chapter count and the 书旗 source note.
  Widget _classicHeader(
    BuildContext context,
    HomePalette palette,
    ShuqiBook book,
    ShuqiToc? toc,
  ) {
    final chapters = toc?.chapters ?? const <ShuqiChapter>[];
    final meta = [
      book.status,
      book.wordCount,
      book.kind,
      '书旗小说',
    ].where((part) => part.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _classicCover(context, palette, book),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.name.isEmpty ? _title : book.name,
                      key: const Key('shuqi-book-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    if (book.author.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        book.author,
                        style: TextStyle(color: palette.muted, fontSize: 12.5),
                      ),
                    ],
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 12.5,
                          height: 1.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    FilledButton(
                      key: const Key('shuqi-read-button'),
                      onPressed: chapters.isEmpty
                          ? null
                          : () => unawaited(_openChapter(0)),
                      style: detailPrimaryButtonStyle(
                        palette,
                        minimumSize: const Size(110, 40),
                      ),
                      child: const Text('开始阅读'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (book.intro.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              book.intro,
              key: const Key('shuqi-intro'),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.ink, fontSize: 13, height: 1.6),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            key: contentAnchorKey('directory'),
            children: [
              Flexible(
                child: Text(
                  toc == null ? '目录未加载' : '共 ${chapters.length} 章',
                  key: const Key('shuqi-toc-count'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (toc != null && !toc.hasRealTitles) ...[
                const SizedBox(width: 8),
                Text(
                  '（章名为占位）',
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ],
              const Spacer(),
              Text(
                '书旗',
                style: TextStyle(color: palette.muted, fontSize: 12.5),
              ),
            ],
          ),
          Divider(height: 20, color: palette.line),
        ],
      ),
    );
  }

  /// 目录 loading / failure row; the book detail above stays visible.
  Widget _classicTocStatus(HomePalette palette) {
    if (_tocError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          children: [
            Text(
              _tocError!,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.muted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('shuqi-toc-retry'),
              onPressed: () => unawaited(_loadToc()),
              style: detailOutlineButtonStyle(
                palette,
                minimumSize: const Size(110, 40),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_tocLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _classicChapterRow(
    BuildContext context,
    HomePalette palette,
    ShuqiChapter chapter,
    int index,
  ) {
    return KeyedSubtree(
      key: contentAnchorKey('directory/chapter:${chapter.chapterId}'),
      child: HomePressable(
        key: ValueKey('shuqi-chapter-$index'),
        semanticLabel: chapter.title,
        onTap: () => unawaited(_openChapter(index)),
        borderRadius: BorderRadius.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
              ),
              if (chapter.isVip) ...[
                const SizedBox(width: 10),
                Text(
                  'VIP',
                  style: TextStyle(
                    color: palette.accentText,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _classicCover(
    BuildContext context,
    HomePalette palette,
    ShuqiBook book,
  ) {
    const width = 68.0;
    const height = 94.0;
    final fallback = Container(
      width: width,
      height: height,
      color: palette.soft,
      child: Icon(Icons.menu_book_outlined, size: 28, color: palette.muted),
    );
    if (book.coverUrl.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        book.coverUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
