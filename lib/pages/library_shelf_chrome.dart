part of 'library_page.dart';

/// 书架页的页头部分：一级 tab 栏、L2 工具栏 / 收藏筛选行，以及编辑态的
/// 顶栏与底栏。原来都写在 `library_page.dart` 的状态类里，把那个文件推过
/// 了行数预算，按职责挪到这里。
mixin _LibraryShelfChrome on _LibraryPageActions {
  /// 顶部一级 tab（选中 18sp w600，指示条宽度动画）+ 右侧搜索 / 更多。
  Widget _tabRow(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.only(
        top: ShelfTokens.spaceM,
        bottom: 7,
        left: ShelfTokens.screenPadding,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Row(
              children: [
                for (var index = 0; index < _tabTitles.length; index++) ...[
                  if (index > 0) const SizedBox(width: 20),
                  _TabButton(
                    label: _tabTitles[index],
                    selected: _tab == index,
                    palette: palette,
                    onTap: () => _selectTab(index),
                  ),
                ],
              ],
            ),
          ),
          _IconAction(
            key: const Key('library-search-button'),
            tooltip: '搜索',
            icon: LucideIcons.search,
            color: palette.ink,
            onTap: _openSearch,
          ),
          const SizedBox(width: 6),
          PopupMenuButton<_MenuAction>(
            key: const Key('library-more-button'),
            tooltip: '更多',
            color: palette.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: palette.line, width: 0.6),
            ),
            elevation: 4,
            onSelected: _handleMenu,
            itemBuilder: (context) => [
              for (final action in _MenuAction.values)
                PopupMenuItem(
                  key: Key('library-menu-${action.name}'),
                  value: action,
                  // 当前版式选中时不可再点；清空历史没有数据时也不可点。
                  enabled: action.layout != null
                      ? action.layout != _layout
                      : action == _MenuAction.clearHistory
                      ? _browseHistory.isNotEmpty
                      : true,
                  child: Row(
                    children: [
                      Icon(
                        action.icon,
                        size: 16,
                        color: action.layout == _layout
                            ? palette.muted
                            : action == _MenuAction.clearHistory
                            ? ShelfTokens.deleteRed
                            : palette.ink,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: action.layout == _layout
                              ? FontWeight.w400
                              : FontWeight.w500,
                          color: action.layout == _layout
                              ? palette.muted
                              : action == _MenuAction.clearHistory
                              ? ShelfTokens.deleteRed
                              : palette.ink,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.only(
                right: ShelfTokens.screenPadding,
                left: 6,
                bottom: 2,
              ),
              child: Icon(LucideIcons.ellipsis, size: 22, color: palette.ink),
            ),
          ),
        ],
      ),
    );
  }

  /// L2 工具栏（书架 tab）：左今日已读胶囊，右版式分段控件。
  ///
  /// 2026-10-13 按用户要求删掉排序 / 筛选 / 编辑三个入口：排序退回固定「最近
  /// 阅读优先」，类型筛选整个移除，编辑改由卡片长按进入（见 `_longPress`）。
  /// 页头因此少一行；只剩两个控件，[Row] 即可放下，无需再折行。
  Widget _toolbar(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.only(
        top: ShelfTokens.spaceXS,
        bottom: ShelfTokens.spaceS,
        left: ShelfTokens.screenPadding,
        right: ShelfTokens.screenPadding,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(ShelfTokens.radiusChip),
              // 与未选中的 HomeChip 同款：常规外观无描边，墨水屏下用一圈
              // 黑线把白底胶囊从白画布上分出来。
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
          ),
          const Spacer(),
          _LayoutSegments(
            current: _layout,
            palette: palette,
            onChanged: _setLayout,
          ),
        ],
      ),
    );
  }

  /// L2 筛选行（收藏 tab）：全部 / 短剧 / 漫剧胶囊 + 右侧版式分段，
  /// 形态与书架 tab 工具栏同构。
  Widget _collectionToolbar(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.only(
        top: ShelfTokens.spaceXS,
        bottom: ShelfTokens.spaceS,
        left: ShelfTokens.screenPadding,
        right: ShelfTokens.screenPadding,
      ),
      child: Row(
        children: [
          HomeChip(
            key: const Key('library-collection-filter-all'),
            label: '全部',
            selected: _collectionFilter == null,
            onTap: () => setState(() => _collectionFilter = null),
          ),
          const SizedBox(width: 8),
          HomeChip(
            key: const Key('library-collection-filter-video'),
            label: '短剧',
            selected: _collectionFilter == 'video',
            onTap: () => setState(() => _collectionFilter = 'video'),
          ),
          const SizedBox(width: 8),
          HomeChip(
            key: const Key('library-collection-filter-manju'),
            label: '漫剧',
            selected: _collectionFilter == 'manju',
            onTap: () => setState(() => _collectionFilter = 'manju'),
          ),
          const Spacer(),
          _LayoutSegments(
            current: _layout,
            palette: palette,
            onChanged: _setLayout,
          ),
        ],
      ),
    );
  }

  /// 编辑态顶部操作栏（by1.xml）：全选 / 已选择 N 本 / 完成。
  Widget _editBar(HomePalette palette) {
    return Container(
      height: ShelfTokens.editBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: ShelfTokens.spaceS),
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(bottom: BorderSide(color: palette.line, width: 0.5)),
      ),
      child: Row(
        children: [
          TextButton(
            key: const Key('shelf-select-all'),
            onPressed: _toggleSelectAll,
            style: TextButton.styleFrom(
              foregroundColor: palette.ink,
              padding: const EdgeInsets.symmetric(
                horizontal: ShelfTokens.spaceM,
              ),
            ),
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
            style: TextButton.styleFrom(
              foregroundColor: HomePalette.accent,
              padding: const EdgeInsets.symmetric(
                horizontal: ShelfTokens.spaceL,
              ),
            ),
            child: const Text(
              '完成',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 编辑态底功能栏（amb.xml）：每个条目 24dp 图标 + 11sp 文案。
  ///
  /// 官方底栏还有找相似书 / 移动至分组 / 分享为书单 / 加入桌面 / 云同步 /
  /// 导入图书 / 最近删除，这些本地都没有数据源，不伪造入口；
  /// 有数据支撑的只有「移出书架」（书架 / 收藏 tab，可撤销故直接执行）与
  /// 「删除」（浏览历史 tab，不可撤销故保留确认）。
  Widget _editBottomBar(HomePalette palette) {
    final removing = _tab != 1;
    return _SlideUp(
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border(top: BorderSide(color: palette.line, width: 0.6)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: palette.dark ? 0.28 : 0.05,
                ),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ShelfTokens.spaceL,
                vertical: ShelfTokens.spaceXS,
              ),
              child: Row(
                children: [
                  _BottomAction(
                    key: Key(
                      removing
                          ? 'shelf-remove-action'
                          : 'history-delete-action',
                    ),
                    icon: removing ? LucideIcons.bookmark_x : LucideIcons.trash,
                    label: removing ? '移出书架' : '删除',
                    color: removing ? palette.ink : ShelfTokens.deleteRed,
                    onTap: _selected.isEmpty
                        ? null
                        : removing
                        ? _removeFromShelf
                        : _deleteHistory,
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
