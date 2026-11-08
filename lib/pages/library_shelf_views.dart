part of 'library_page.dart';

/// 书架页的内容区：四模式容器、立体书架头部、条目与空态。
mixin _LibraryShelfViews on _LibraryShelfChrome {
  /// 浏览历史固定纯列表（design §1.1 #1）；书架 / 收藏共用持久化版式。
  BookCollectionMode get _effectiveMode =>
      _tab == 1 ? BookCollectionMode.list : ShelfViewStore.instance.mode;

  Widget _content(BuildContext context) {
    // Register a theme dependency on the page even when collection slivers
    // reuse their cached row delegates; style changes must refresh padding.
    final style = AppStyleTokens.of(context);
    final entries = _visibleEntries;
    final mode = _effectiveMode;
    final view = ShelfViewStore.instance.state;
    // 首屏条目沿用上游的入场序列：数据/筛选批次变化时播一次，滚动重建与
    // 隐藏 tab 不重播（`LoadedContentSequence` 在 TickerMode 关闭时静态化）。
    return LoadedContentSequence(
      generation: ShelfViewStore.instance.isLoaded
          ? (_tab, mode, view.sort, view.filter, view.source, _category)
          : null,
      child: ShelfCollectionView(
        key: ValueKey('shelf-view-${mode.storageValue}'),
        mode: mode,
        density: view.density,
        itemCount: entries.length,
        regionToolbar: _toolbar(entries.length),
        carousel: mode.hasShelf ? _carousel(entries) : null,
        itemBuilder: (context, index) => _tile(entries[index], mode, index),
        emptyBuilder: (context) => _emptyState(context),
        padding: EdgeInsets.fromLTRB(
          style.pageGutter,
          0,
          style.pageGutter,
          DockLayout.scrollPaddingOf(context),
        ),
        storageKey: PageStorageKey('shelf-$_tab'),
        onGridViewport: (viewport) => _gridViewport = viewport,
      ),
    );
  }

  /// 立体书架头部：条目顺序与下方列表一致（followCollection 恒 true），
  /// 只取 `BookShelfPreferences.featuredCount` 本。
  Widget? _carousel(List<_ShelfEntry> entries) {
    final preferences = ShelfViewStore.instance.shelfPreferences;
    final count = preferences.featuredCount(entries.length);
    if (count <= 0) return null;
    if (!_carouselEntrancePlayed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _carouselEntrancePlayed = true;
      });
    }
    return ArchiveFileCarousel(
      key: const ValueKey('archive-shelf-carousel'),
      entries: [for (final entry in entries.take(count)) entry.toArchive()],
      onOpen: (entry) => _tapItem(entry.item),
      onLongPress: (entry) => _longPressItem(entry.item),
      directReading: BookOpenPreferences.instance.shelfDirectReader.value,
      reduceMotion: _reduceMotion,
      animateEntrance: !_carouselEntrancePlayed,
      repeatFill: preferences.repeatFill,
      interactive: !_editing,
      selecting: _editing,
      selected: _selected,
    );
  }

  Widget _tile(_ShelfEntry entry, BookCollectionMode mode, int index) {
    final selected = _selected.contains(entry.selectionKey);
    final tile = mode.isGrid
        ? ShelfBookGridTile(
            key: ValueKey('shelf-grid-book-${entry.contentKey}'),
            item: entry.item,
            badge: entry.badgeText,
            progress: entry.readingText,
            meta: entry.metaText,
            cached: entry.cached,
            fanqieImported: entry.fanqieImported,
            editing: _editing,
            selected: selected,
            onTap: () => _tap(entry),
            onLongPress: () => _longPress(entry),
          )
        : ShelfNovelRow(
            key: ValueKey('shelf-book-${entry.contentKey}'),
            item: entry.item,
            badge: entry.badgeText,
            progress: entry.readingText,
            meta: entry.metaText,
            cached: entry.cached,
            fanqieImported: entry.fanqieImported,
            editing: _editing,
            selected: selected,
            onTap: () => _tap(entry),
            onLongPress: () => _longPress(entry),
          );
    return LoadedContentItem(
      key: ValueKey('shelf-entrance-${entry.contentKey}'),
      index: index,
      placeholder: mode.isGrid
          ? const BookGridSkeleton()
          : const BookRowSkeleton(),
      child: tile,
    );
  }

  /// 空态按 tab 区分：书架为空给「去书城找书 + 查看离线缓存」；筛选后为空
  /// 给「清除筛选」出口；浏览历史沿用官方通用文案；收藏为空按当前类型
  /// 筛选给文案 + 「找短剧」入口。
  Widget _emptyState(BuildContext context) {
    if (_tab == 0) {
      if (_shelf.isEmpty) {
        return ShelfEmptyState(
          onBrowse: widget.onBrowse,
          onCachedBooks: _openCachedBooks,
        );
      }
      return ShelfFilteredEmptyState(
        text: '没有符合筛选的书籍',
        onClearFilters: _clearFilters,
      );
    }
    if (_tab == 2) {
      // 只有类型筛选时沿用官方收藏空态文案（暂无短剧 / 暂无漫剧 / 暂无
      // 收藏内容）；排序 / 阅读状态 / 来源 / 分类把结果筛空时才给
      // 「清除筛选」出口。
      final onlyTypeFilter =
          _activeFilters == 0 && _category == ShelfCategory.all;
      if (_collection.isEmpty || onlyTypeFilter) {
        return ShelfCollectionEmptyState(
          text: switch (_collectionFilter) {
            'video' => '暂无短剧',
            'manju' => '暂无漫剧',
            _ => '暂无收藏内容',
          },
          onFindDrama: widget.onFindDrama,
        );
      }
      return ShelfFilteredEmptyState(
        text: '没有符合筛选的收藏',
        onClearFilters: _clearFilters,
      );
    }
    if (_browseHistory.isEmpty) {
      return const ShelfEmptyHint(text: '未找到相关内容');
    }
    return ShelfFilteredEmptyState(
      text: '没有符合筛选的记录',
      onClearFilters: _clearFilters,
    );
  }
}
