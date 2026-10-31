part of 'library_page.dart';

/// 书架页的内容区：空态、宫格 / 双列 / 列表三档版式与点按分发。原来都
/// 写在 `library_page.dart` 的状态类里，把那个文件推过了行数预算，按职责
/// 挪到这里。
mixin _LibraryShelfViews on _LibraryPageActions {
  Widget _content(HomePalette palette) {
    final entries = _visibleEntries;
    if (entries.isEmpty) {
      // 空态按 tab 区分：书架为空给「去书城找书 + 查看离线缓存」（筛选已
      // 移除，故这已是书架 tab 唯一的空态）；浏览历史为空沿用官方通用
      // 文案；收藏为空按当前筛选给文案 + 「找短剧」入口（官方空态形态）。
      if (_tab == 0 && _shelf.isEmpty) {
        return ShelfEmptyState(
          onBrowse: widget.onBrowse,
          onCachedBooks: _openCachedBooks,
        );
      }
      if (_tab == 2) {
        return ShelfCollectionEmptyState(
          text: switch (_collectionFilter) {
            'video' => '暂无短剧',
            'manju' => '暂无漫剧',
            _ => '暂无收藏内容',
          },
          onFindDrama: widget.onFindDrama,
        );
      }
      return const ShelfEmptyHint(text: '未找到相关内容');
    }
    final body = switch (_layout) {
      BookshelfLayout.grid => _grid(entries),
      BookshelfLayout.doubleColumn => _doubleGrid(entries),
      BookshelfLayout.list => _list(entries),
    };
    // 版式切换：fade+scale 220ms（无障碍关闭动画时瞬时）。
    return AnimatedSwitcher(
      duration: _motionDuration(context, 220),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey('shelf-content-${_layout.name}'),
        child: body,
      ),
    );
  }

  Widget _grid(List<_ShelfEntry> entries) {
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        key: const Key('shelf-grid-view'),
        padding: const EdgeInsets.fromLTRB(
          ShelfTokens.screenPadding,
          ShelfTokens.spaceXS,
          ShelfTokens.screenPadding,
          ShelfTokens.contentBottomInset,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: isWindowsDesktop
              ? (constraints.maxWidth / 170).floor().clamp(3, 10)
              : ShelfTokens.gridColumns,
          crossAxisSpacing: ShelfTokens.gridSpacing,
          mainAxisSpacing: ShelfTokens.gridRunSpacing,
          childAspectRatio: shelfGridChildAspectRatio(
            context,
            availableWidth: constraints.maxWidth,
            columns: isWindowsDesktop
                ? (constraints.maxWidth / 170).floor().clamp(3, 10)
                : ShelfTokens.gridColumns,
          ),
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return HomeEntrance(
            index: index,
            animate: index < 6 && _entered.add(index),
            child: BookshelfGridCard(
              key: ValueKey('shelf-grid-${entry.selectionKey}'),
              item: entry.item,
              badgeText: entry.badgeText,
              infoText: entry.infoText,
              editing: _editing,
              selected: _selected.contains(entry.selectionKey),
              onTap: () => _tap(entry),
              onLongPress: () => _longPress(entry),
            ),
          );
        },
      ),
    );
  }

  Widget _doubleGrid(List<_ShelfEntry> entries) {
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        key: const Key('shelf-double-view'),
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
          return HomeEntrance(
            index: index,
            animate: index < 6 && _entered.add(index),
            child: BookshelfDoubleCard(
              key: ValueKey('shelf-double-${entry.selectionKey}'),
              item: entry.item,
              badgeText: entry.badgeText,
              subtitleText: entry.subtitleText,
              editing: _editing,
              selected: _selected.contains(entry.selectionKey),
              onTap: () => _tap(entry),
              onLongPress: () => _longPress(entry),
            ),
          );
        },
      ),
    );
  }

  Widget _list(List<_ShelfEntry> entries) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      key: const Key('shelf-list-view'),
      padding: const EdgeInsets.only(
        top: ShelfTokens.spaceXS,
        bottom: ShelfTokens.contentBottomInset,
      ),
      itemCount: entries.length,
      separatorBuilder: (context, index) => Divider(
        height: 0.5,
        thickness: 0.5,
        color: HomePalette.of(context).line,
      ),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return HomeEntrance(
          index: index,
          animate: index < 6 && _entered.add(index),
          child: BookshelfListCard(
            key: ValueKey('shelf-list-${entry.selectionKey}'),
            item: entry.item,
            progressText: entry.readingText,
            metaText: entry.metaText,
            progress: entry.progress,
            editing: _editing,
            selected: _selected.contains(entry.selectionKey),
            onTap: () => _tap(entry),
            onLongPress: () => _longPress(entry),
          ),
        );
      },
    );
  }

  void _tap(_ShelfEntry entry) {
    if (_editing) {
      _toggleSelected(entry);
    } else {
      _open(entry.item, importedResume: entry.importedResume);
    }
  }
}
