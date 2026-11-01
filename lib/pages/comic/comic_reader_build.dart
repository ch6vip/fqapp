part of '../comic_reader_page.dart';

/// 漫画阅读器的 scaffold / 顶栏 / 底栏与空错态。
///
/// 顶栏与底栏的按钮本身在 `widgets/comic/`，这里只负责把状态接上。
extension _ComicReaderBuild on _ComicReaderPageState {
  Widget _buildSurface(BuildContext context) {
    final empty = widget.chapters.isEmpty;
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        foregroundColor: palette.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: const HomeBackButton(),
        title: Text(
          empty ? widget.title : _chapter.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.ink),
        ),
        actions: empty
            ? null
            : [
                ComicReaderToolbar(
                  pagedMode: _pagedMode,
                  enabled: !_loading,
                  onTogglePagedMode: _togglePagedMode,
                  onReload: _reloadChapter,
                  onDirectory: _showDirectory,
                  shelfAction: ValueListenableBuilder<int>(
                    valueListenable: ShelfStore.instance.listenable,
                    builder: (context, _, _) {
                      final inShelfNow = inShelf(_shelfEntry);
                      return ComicChromeButton(
                        key: const Key('comic_reader_shelf_button'),
                        tooltip: inShelfNow ? '已在书架' : '加入书架',
                        icon: inShelfNow
                            ? LucideIcons.bookmark_check
                            : LucideIcons.bookmark_plus,
                        onPressed: () =>
                            unawaited(toggleShelf(context, _shelfEntry)),
                      );
                    },
                  ),
                ),
              ],
      ),
      bottomNavigationBar: empty
          ? null
          : ComicChapterBar(
              chapterIndex: _chapterIndex,
              chapterCount: widget.chapters.length,
              visiblePage: _visiblePage,
              pageCount: _images.length,
              onPrevious: _chapterIndex == 0
                  ? null
                  : () => _changeChapter(_chapterIndex - 1),
              onNext: _chapterIndex + 1 >= widget.chapters.length
                  ? null
                  : () => _changeChapter(_chapterIndex + 1),
            ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _buildBody(palette, empty),
      ),
    );
  }

  Widget _buildBody(HomePalette palette, bool empty) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: palette.ink));
    }
    if (_error != null) {
      return _errorView(canRetry: !empty);
    }
    return ComicReaderViewport(
      images: _images,
      generation: _loadGeneration,
      pagedMode: _pagedMode,
      pageController: _pageController,
      ensurePageController: _ensurePageController,
      scrollController: _scroll,
      layoutFor: _layoutFor,
      onPageChanged: _onPageChanged,
      onImageReady: _updateImageSizeForGeneration,
      onImageFailed: _imageFailedForGeneration,
      onOpenImage: _showImage,
      providerFactory: widget.imageProviderFactory,
    );
  }

  Widget _errorView({required bool canRetry}) => HomeStateView(
    icon: canRetry ? LucideIcons.circle_alert : LucideIcons.inbox,
    title: canRetry ? '加载失败' : '暂无内容',
    message: _error,
    actionLabel: canRetry ? '重新加载本章' : null,
    actionIcon: canRetry ? LucideIcons.rotate_ccw : null,
    onAction: canRetry ? _reloadChapter : null,
    padding: const EdgeInsets.all(24),
    scrollable: true,
  );
}
