part of 'library_page.dart';

/// Old three-layout presentation, sharing the current page's entries, actions
/// and edit state. No archive mode/density/3D preference participates here.
mixin _LibraryClassicViews on _LibraryClassicChrome {
  Widget _classicPage(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (_editing)
              _classicEditBar(palette)
            else
              // The sliding underline needs the measured tab centres, which
              // only exist after the layout.
              Builder(
                builder: (context) {
                  _scheduleClassicMeasure();
                  return _classicTabRow(palette);
                },
              ),
            Expanded(
              child: TabSwipeArea.pages(
                index: _tab,
                count: _tabTitles.length,
                onSelect: _selectTab,
                onProgress: (value) {
                  if (_tabProgress.value != value) {
                    _tabProgress.value = value;
                  }
                },
                enabled: !_editing,
                pageBuilder: (context, target) =>
                    _classicTabBody(context, target),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _editing ? _classicEditBottomBar(palette) : null,
    );
  }

  /// 工具栏与内容作为同一张邻页滑动，切历史时不再改变滑动视口高度。
  Widget _classicTabBody(BuildContext context, int tab) {
    final palette = HomePalette.of(context);
    return Column(
      children: [
        if (!_editing && tab != 1) _classicToolbar(palette, tab),
        if (_classicHasFiltersForTab(tab)) _classicFilterStatus(palette, tab),
        if (tab != 1 &&
            ShelfViewStore.instance.state.source == ShelfSourceFilter.cached)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ShelfTokens.screenPadding,
            ),
            child: _cacheStatus(),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _refreshUpdates(force: true),
            child: _classicContent(context, tab),
          ),
        ),
      ],
    );
  }

  Widget _classicContent(BuildContext context, int tab) {
    final entries = _visibleEntriesForTab(tab);
    if (entries.isEmpty) {
      // Keep pull-to-refresh working even when a filter hides every entry.
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _classicEmptyState(tab),
          ),
        ],
      );
    }
    // All three old-style tabs share this independent three-layout choice.
    // The archive's fixed history list and four-mode setting are untouched.
    final layout = _classicLayout.value;
    return switch (layout) {
      BookshelfLayout.grid => _classicGrid(entries, tab),
      BookshelfLayout.doubleColumn => _classicDoubleGrid(entries, tab),
      BookshelfLayout.list => _classicList(entries, tab),
    };
  }

  /// 空态锚点补偿用的动态头部总高：筛选状态栏定高（行内文字已钳制
  /// 1.3 倍内，定高恒成立）；缓存扫描行只在扫描未完成时占高（完成后
  /// 是 SizedBox.shrink），高度随 textScaler 与实际渲染同源计算。
  double _classicDynamicHeaderHeight(int tab) {
    var height = 0.0;
    if (_classicHasFiltersForTab(tab)) height += ShelfTokens.filterStatusHeight;
    if (tab != 1 &&
        ShelfViewStore.instance.state.source == ShelfSourceFilter.cached &&
        !_cacheScanComplete) {
      height += shelfCacheStatusHeight(context);
    }
    return height;
  }

  Widget _classicEmptyState(int tab) {
    final headerHeight = _classicDynamicHeaderHeight(tab);
    final category = tab == 0 ? _categoryForTab(tab) : ShelfCategory.all;
    // A selected group is empty only when no shelf entry belongs to it at all.
    // Other active filters must keep the generic "没有符合筛选" copy: the
    // group itself still has books, they are just hidden by source/reading.
    final groupEmpty =
        tab == 0 &&
        category != ShelfCategory.all &&
        !_shelf.any(
          (entry) => ShelfGroupStore.instance.matchesKey(
            entry.contentKey,
            entry.author,
            category,
          ),
        );
    if (tab == 0 && _shelf.isEmpty && !groupEmpty) {
      return _ClassicEmptyNotice(
        icon: LucideIcons.book_open,
        title: '书架暂无书籍',
        message: '去书城发现海量故事，随时随地畅读',
        actionLabel: '去书城找书',
        actionKey: const Key('shelf-browse-button'),
        onAction: widget.onBrowse,
        onCachedBooks: _openCachedBooks,
        headerHeight: headerHeight,
      );
    }
    if (tab == 2 &&
        (_collection.isEmpty ||
            (_activeFiltersForTab(tab) == 0 &&
                _categoryForTab(tab) == ShelfCategory.all))) {
      return _ClassicEmptyNotice(
        icon: LucideIcons.clapperboard,
        title: switch (_collectionFilter) {
          'video' => '暂无短剧',
          'manju' => '暂无漫剧',
          _ => '暂无收藏内容',
        },
        actionLabel: _collectionFilter == 'manju' ? '找漫剧' : '找短剧',
        actionKey: const Key('collection-find-drama-button'),
        onAction: widget.onFindDrama,
        headerHeight: headerHeight,
      );
    }
    final filtered = _classicHasFiltersForTab(tab);
    final groupEmptyTitle = groupEmpty
        ? '「${ShelfGroupStore.instance.nameOf(category)}」暂无书籍'
        : null;
    return _ClassicEmptyNotice(
      icon: LucideIcons.search_x,
      title:
          groupEmptyTitle ??
          (!filtered
              ? '未找到相关内容'
              : switch (tab) {
                  0 => '没有符合筛选的书籍',
                  2 => '没有符合筛选的收藏',
                  _ => '没有符合筛选的记录',
                }),
      actionLabel: filtered ? '清除筛选' : null,
      actionKey: const Key('shelf-clear-filters'),
      onAction: _clearFilters,
      headerHeight: headerHeight,
    );
  }

  Widget _classicGrid(List<_ShelfEntry> entries, int tab) => LayoutBuilder(
    builder: (context, constraints) => GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      key: PageStorageKey('classic-shelf-grid-$tab'),
      padding: const EdgeInsets.fromLTRB(
        ShelfTokens.screenPadding,
        ShelfTokens.spaceXS,
        ShelfTokens.screenPadding,
        ShelfTokens.contentBottomInset,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: ShelfTokens.gridColumns,
        crossAxisSpacing: ShelfTokens.gridSpacing,
        mainAxisSpacing: ShelfTokens.gridRunSpacing,
        childAspectRatio: shelfGridChildAspectRatio(
          context,
          availableWidth: constraints.maxWidth,
        ),
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return BookshelfGridCard(
          key: ValueKey('shelf-grid-${entry.selectionKey}'),
          item: entry.item,
          badgeText: entry.badgeText,
          infoText: entry.infoText,
          editing: _editing,
          selected: _selected.contains(entry.selectionKey),
          onTap: () => _tap(entry),
          onLongPress: () => _longPress(entry),
        );
      },
    ),
  );

  Widget _classicDoubleGrid(List<_ShelfEntry> entries, int tab) =>
      LayoutBuilder(
        builder: (context, constraints) => GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          key: PageStorageKey('classic-shelf-double-$tab'),
          padding: const EdgeInsets.fromLTRB(
            ShelfTokens.screenPadding,
            ShelfTokens.spaceXS,
            ShelfTokens.screenPadding,
            ShelfTokens.contentBottomInset,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: ShelfTokens.gridSpacing,
            mainAxisSpacing: ShelfTokens.gridSpacing,
            childAspectRatio: shelfDoubleChildAspectRatio(
              context,
              availableWidth: constraints.maxWidth,
            ),
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return BookshelfDoubleCard(
              key: ValueKey('shelf-double-${entry.selectionKey}'),
              item: entry.item,
              badgeText: entry.badgeText,
              subtitleText: entry.subtitleText,
              editing: _editing,
              selected: _selected.contains(entry.selectionKey),
              onTap: () => _tap(entry),
              onLongPress: () => _longPress(entry),
            );
          },
        ),
      );

  Widget _classicList(List<_ShelfEntry> entries, int tab) => ListView.separated(
    physics: const AlwaysScrollableScrollPhysics(),
    key: PageStorageKey('classic-shelf-list-$tab'),
    padding: const EdgeInsets.only(
      top: ShelfTokens.spaceXS,
      bottom: ShelfTokens.contentBottomInset,
    ),
    itemCount: entries.length,
    separatorBuilder: (context, index) =>
        Divider(height: .5, thickness: .5, color: HomePalette.of(context).line),
    itemBuilder: (context, index) {
      final entry = entries[index];
      return BookshelfListCard(
        key: ValueKey('shelf-list-${entry.selectionKey}'),
        item: entry.item,
        progressText: entry.readingText,
        metaText: entry.metaText,
        progress: entry.progress,
        editing: _editing,
        selected: _selected.contains(entry.selectionKey),
        onTap: () => _tap(entry),
        onLongPress: () => _longPress(entry),
      );
    },
  );
}
