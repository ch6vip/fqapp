part of 'library_page.dart';

/// Restored from the pre-archive shelf chrome (f329399). Only action wiring and
/// the compact access to newer filters/groups differ from the original UI.
mixin _LibraryClassicChrome on _LibraryShelfViews {
  bool get _classicHasFilters =>
      _activeFilters > 0 ||
      _category != ShelfCategory.all ||
      (_tab == 2 && _collectionFilter != null);

  void _setClassicLayout(BookshelfLayout layout) {
    unawaited(
      _persist(() => _classicLayout.setLayout(layout), message: '布局已更新，但未能保存'),
    );
  }

  Widget _classicTabRow(HomePalette palette) => Padding(
    padding: const EdgeInsets.only(
      top: ShelfTokens.spaceM,
      bottom: 7,
      left: ShelfTokens.screenPadding,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          // The normal-size geometry is the old row; large accessibility text
          // can scroll the tabs without pushing search/more off screen.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              key: const Key('library-tabs'),
              children: [
                for (var index = 0; index < _tabTitles.length; index++) ...[
                  if (index > 0) const SizedBox(width: 20),
                  _ClassicTabButton(
                    label: _tabTitles[index],
                    selected: _tab == index,
                    palette: palette,
                    onTap: () => _selectTab(index),
                  ),
                ],
              ],
            ),
          ),
        ),
        Tooltip(
          message: '搜索',
          child: IconButton(
            key: const Key('library-search-button'),
            onPressed: _openSearch,
            style: IconButton.styleFrom(
              foregroundColor: palette.ink,
              padding: const EdgeInsets.all(8),
              minimumSize: const Size(38, 38),
            ),
            icon: const Icon(LucideIcons.search, size: 21),
          ),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<_ClassicMenuAction>(
          key: const Key('library-more-button'),
          tooltip: '更多',
          color: palette.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: palette.line, width: .6),
          ),
          elevation: 4,
          onSelected: _handleClassicMenu,
          itemBuilder: (context) => [
            for (final action in _ClassicMenuAction.values)
              if (action != _ClassicMenuAction.filter || _tab != 1)
                PopupMenuItem(
                  key: Key('library-menu-${action.name}'),
                  value: action,
                  enabled: action.layout != null
                      ? action.layout != _classicLayout.value
                      : action == _ClassicMenuAction.clearHistory
                      ? _browseHistory.isNotEmpty
                      : action == _ClassicMenuAction.clearFilters
                      ? _classicHasFilters
                      : action == _ClassicMenuAction.edit
                      ? _visibleEntries.isNotEmpty
                      : true,
                  child: Row(
                    children: [
                      Icon(action.icon, size: 16, color: palette.ink),
                      const SizedBox(width: 10),
                      Text(
                        action.label,
                        style: TextStyle(fontSize: 14, color: palette.ink),
                      ),
                    ],
                  ),
                ),
          ],
          child: Padding(
            padding: const EdgeInsets.only(right: ShelfTokens.screenPadding),
            // 48×48 matches the M3 IconButton the search button actually
            // renders as; with the end-aligned row this keeps both glyph
            // centers on the same baseline (a shorter box would sink the
            // dots below it).
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: Icon(LucideIcons.ellipsis, size: 22, color: palette.ink),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  void _handleClassicMenu(_ClassicMenuAction action) {
    final layout = action.layout;
    if (layout != null) {
      _setClassicLayout(layout);
      return;
    }
    switch (action) {
      case _ClassicMenuAction.importBook:
        unawaited(_importLocalBook());
      case _ClassicMenuAction.cachedBooks:
        _openCachedBooks();
      case _ClassicMenuAction.filter:
        unawaited(_openFilterSheet());
      case _ClassicMenuAction.categories:
        unawaited(_openCategorySheet());
      case _ClassicMenuAction.clearFilters:
        unawaited(_clearFilters());
      case _ClassicMenuAction.edit:
        _enterEdit();
      case _ClassicMenuAction.clearHistory:
        unawaited(_confirmClear());
      case _ClassicMenuAction.switchGrid:
      case _ClassicMenuAction.switchDouble:
      case _ClassicMenuAction.switchList:
        break;
    }
  }

  /// L2 工具栏：左「今日已读」胶囊，中间分组筛选胶囊（书架 tab），右侧版式
  /// 分段。分组胶囊把 `_category` 写成胶囊文案，也是分组入口（点开现有分类
  /// 弹层，选择 / 新建 / 重命名 / 删除都在那里）。窄屏或 2x 字号整行会放
  /// 不下，胶囊与「今日已读」一起横向滚动，版式分段固定不动，不出现 overflow。
  Widget _classicToolbar(HomePalette palette) => Padding(
    padding: const EdgeInsets.fromLTRB(
      ShelfTokens.screenPadding,
      ShelfTokens.spaceXS,
      ShelfTokens.screenPadding,
      ShelfTokens.spaceS,
    ),
    child: Row(
      children: [
        Expanded(
          child: _tab == 0
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    final compact =
                        constraints.maxWidth < 260 ||
                        MediaQuery.textScalerOf(context).scale(1) > 1.4;
                    if (compact) {
                      // Narrow or large-text: keep both controls reachable by
                      // scrolling instead of pushing the layout segments off.
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _classicTodayPill(palette),
                            const SizedBox(width: 8),
                            _classicGroupChip(palette),
                          ],
                        ),
                      );
                    }
                    return Row(
                      children: [
                        _classicTodayPill(palette),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: _classicGroupChip(palette),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (value, label) in const [
                        (null, '全部'),
                        ('video', '短剧'),
                        ('manju', '漫剧'),
                      ]) ...[
                        if (value != null) const SizedBox(width: 8),
                        HomeChip(
                          key: Key(
                            'library-collection-filter-${value ?? 'all'}',
                          ),
                          label: label,
                          selected: _collectionFilter == value,
                          onTap: () =>
                              setState(() => _collectionFilter = value),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        const SizedBox(width: 8),
        _ClassicLayoutSegments(
          current: _classicLayout.value,
          palette: palette,
          onChanged: _setClassicLayout,
        ),
      ],
    ),
  );

  Widget _classicTodayPill(HomePalette palette) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: palette.soft,
      borderRadius: BorderRadius.circular(ShelfTokens.radiusChip),
      border: palette.eink ? Border.all(color: palette.line) : null,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          LucideIcons.clock,
          size: ShelfTokens.iconInline,
          color: palette.muted,
        ),
        const SizedBox(width: 5),
        Text(
          '今日已读$_todayMinutes分钟',
          style: TextStyle(
            fontSize: ShelfTokens.subtitle,
            fontWeight: FontWeight.w500,
            color: palette.ink,
          ),
        ),
      ],
    ),
  );

  /// 分组胶囊的宽度上限：长分组名只省略，不把工具栏推出去换行。
  Widget _classicGroupChip(HomePalette palette) {
    final category = _category;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 148),
      child: _ClassicGroupChip(
        key: const Key('shelf-group-chip'),
        label: ShelfGroupStore.instance.nameOf(category),
        active: category != ShelfCategory.all,
        palette: palette,
        onTap: () => unawaited(_openCategorySheet()),
      ),
    );
  }

  /// No permanent archive toolbar. Applied filters must nevertheless never be
  /// invisible, including a category selected while the archive was active.
  Widget _classicFilterStatus(HomePalette palette) => SizedBox(
    // 定高等于 M3 TextButton 默认 40：与 [ShelfTokens.filterStatusHeight]
    // 互为约定，空态锚点按它补偿。
    height: ShelfTokens.filterStatusHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ShelfTokens.screenPadding,
      ),
      // 辅助功能大字号（iOS 可达 ~3x）下 TextButton 标签固有高度
      // （14 × 3 × 1.43 ≈ 60）会超过 40 定高向行外溢出；钳制 1.3 倍
      // （≈26 < 40）保住定高契约，与 dock 入口的钳制做法一致。
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Row(
          key: const Key('classic-shelf-active-filters'),
          children: [
            Icon(Icons.filter_list, size: 13, color: palette.muted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                '已筛选${_category == ShelfCategory.all ? '' : ' · ${ShelfGroupStore.instance.nameOf(_category)}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: ShelfTokens.subtitle,
                  color: palette.muted,
                ),
              ),
            ),
            TextButton(
              key: const Key('classic-shelf-clear-filters'),
              onPressed: _clearFilters,
              child: const Text('清除筛选'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _classicEditBar(HomePalette palette) => Container(
    height: ShelfTokens.editBarHeight,
    padding: const EdgeInsets.symmetric(horizontal: ShelfTokens.spaceS),
    decoration: BoxDecoration(
      color: palette.canvas,
      border: Border(bottom: BorderSide(color: palette.line, width: .5)),
    ),
    child: Row(
      children: [
        TextButton(
          key: const Key('shelf-select-all'),
          onPressed: _toggleSelectAll,
          style: TextButton.styleFrom(foregroundColor: palette.ink),
          child: const Text(
            '全选',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Center(
            child: Text(
              '已选择 ${_selected.length} ${_tab == 2 ? '部' : '本'}',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
        ),
        TextButton(
          key: const Key('shelf-edit-done'),
          onPressed: _exitEdit,
          style: TextButton.styleFrom(foregroundColor: HomePalette.accent),
          child: const Text(
            '完成',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget _classicEditBottomBar(HomePalette palette) {
    final removing = _tab != 1;
    final enabled = _selected.isNotEmpty && !_assigningCategory;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.line, width: .6)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ShelfTokens.spaceL,
            vertical: ShelfTokens.spaceXS,
          ),
          child: Wrap(
            children: [
              _ClassicBottomAction(
                key: const Key('shelf-move-category-action'),
                icon: LucideIcons.folder,
                label: '移至分类',
                color: palette.ink,
                onTap: enabled ? _moveToCategory : null,
              ),
              _ClassicBottomAction(
                key: Key(
                  removing ? 'shelf-remove-action' : 'history-delete-action',
                ),
                icon: removing ? LucideIcons.bookmark_x : LucideIcons.trash,
                label: removing ? '移出书架' : '删除',
                color: removing ? palette.ink : ShelfTokens.deleteRed,
                onTap: !enabled
                    ? null
                    : removing
                    ? _removeFromShelf
                    : _deleteHistory,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
