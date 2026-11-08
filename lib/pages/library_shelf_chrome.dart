part of 'library_page.dart';

/// 书架页的页头部分：档案 masthead + 搜索 / 导入 / 更多三动作、一级 tab
/// 分段、L2 工具条，以及编辑态的顶栏与底栏。
mixin _LibraryShelfChrome on _LibraryPageActions {
  /// 档案页头：masthead + 搜索 / 导入 / 更多。三个动作在 360dp、1.4x 字号下
  /// 仍与 masthead 同行（masthead 内部 FittedBox 缩放）。
  Widget _header(BuildContext context) => Row(
    children: [
      const Expanded(
        child: ArchiveMasthead(title: '书架', code: '01 / LIBRARY ARCHIVE'),
      ),
      GlassIconButton(
        key: const Key('library-search-button'),
        icon: CupertinoIcons.search,
        label: '搜索',
        onPressed: _openSearch,
      ),
      GlassIconButton(
        key: const Key('library-import-button'),
        icon: CupertinoIcons.arrow_down_doc,
        label: '导入图书',
        onPressed: _importLocalBook,
      ),
      GlassMenuAnchor(
        child: Builder(
          builder: (anchor) => GlassIconButton(
            key: const Key('library-more-button'),
            icon: CupertinoIcons.ellipsis,
            label: '更多',
            onPressed: () => _openMoreMenu(anchor),
          ),
        ),
      ),
    ],
  );

  /// 一级 tab：上游 `WenkuControls.segments` 三段（书架 / 浏览历史 / 收藏）。
  Widget _tabSegments(BuildContext context) => WenkuControls.segments<int>(
    context,
    key: const Key('library-tabs'),
    groupValue: _tab,
    children: const {0: Text('书架'), 1: Text('浏览历史'), 2: Text('收藏')},
    onValueChanged: (value) {
      if (value != null) _selectTab(value);
    },
  );

  /// L2 工具条：分类 / 计数 / 筛选 / 视图。书架 tab 额外带今日已读胶囊；
  /// 浏览历史不排序不筛来源（design #6），只保留分类；收藏 tab 在工具条
  /// 下方加 video/manju 类型筛选。
  Widget _toolbar(int count) => LayoutBuilder(
    builder: (context, constraints) {
      final category = ShelfGroupStore.instance.nameOf(_category);
      final active = _activeFilters;
      if (_tab == 2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShelfToolbar(
              category: category,
              count: count,
              activeFilters: active,
              onCategory: _openCategorySheet,
              onFilter: _openFilterSheet,
              onView: () => _openViewSheet(target: ShelfViewTarget.collection),
              categoryKey: const Key('shelf-category'),
              filterKey: const Key('shelf-filter'),
              viewKey: const Key('shelf-view'),
            ),
            const SizedBox(height: 10),
            _CollectionTypeFilter(
              selected: _collectionFilter,
              onChanged: (value) => setState(() => _collectionFilter = value),
            ),
            _cacheStatus(),
          ],
        );
      }
      // 360dp 下今日已读胶囊 + 分类 + 计数 + 筛选 + 视图放不进一行；把胶囊
      // 移到工具条上方，工具条本身仍保持上游的窄屏计数换行规则。
      final narrow = constraints.maxWidth < 420;
      final toolbar = ShelfToolbar(
        category: category,
        count: count,
        activeFilters: active,
        leading: _tab == 0 && !narrow
            ? ShelfTodayReadingPill(minutes: _todayMinutes)
            : null,
        onCategory: _openCategorySheet,
        onFilter: _tab == 0 ? _openFilterSheet : null,
        onView: _tab == 0 ? () => _openViewSheet() : null,
        showFilter: _tab == 0,
        showView: _tab == 0,
        categoryKey: const Key('shelf-category'),
        filterKey: const Key('shelf-filter'),
        viewKey: const Key('shelf-view'),
      );
      // 浏览历史不筛来源，不需要缓存扫描状态。
      if (_tab != 0) return toolbar;
      if (!narrow) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [toolbar, _cacheStatus()],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ShelfTodayReadingPill(minutes: _todayMinutes),
          ),
          const SizedBox(height: 8),
          toolbar,
          _cacheStatus(),
        ],
      );
    },
  );

  /// 离线缓存扫描状态：完成前提示正在检查，失败时说明筛选暂不可用。
  /// 只有带「来源」筛选的书架 / 收藏 tab 需要它（design §3.5/§7.2）。
  Widget _cacheStatus() {
    if (_cacheScanComplete) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: AppText(
          _cacheScanFailed ? '离线缓存暂不可用' : '正在检查离线缓存…',
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 编辑态顶部操作栏：全选 / 已选择 N 本 / 完成。
  Widget _editBar(BuildContext context) => SizedBox(
    height: 56,
    child: Row(
      children: [
        GlassTextButton(
          key: const Key('shelf-select-all'),
          compact: true,
          onPressed: _toggleSelectAll,
          child: const AppText('全选'),
        ),
        Expanded(
          child: Center(
            child: AppText(
              '已选择 ${_selected.length} ${_tab == 2 ? '部' : '本'}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        GlassTextButton(
          key: const Key('shelf-edit-done'),
          compact: true,
          onPressed: _exitEdit,
          child: const AppText('完成'),
        ),
      ],
    ),
  );

  /// 三个 tab 共用分类归属；移出书架可撤销，删除历史仍需确认。
  Widget _editBottomBar(BuildContext context) {
    final removing = _tab != 1;
    final scheme = Theme.of(context).colorScheme;
    final style = AppStyleTokens.of(context);
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant, width: .6),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: style.pageGutter,
            vertical: 8,
          ),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              GlassTextButton(
                key: const Key('shelf-move-category-action'),
                compact: true,
                onPressed: _selected.isEmpty || _assigningCategory
                    ? null
                    : _moveToCategory,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ArchiveIcon(CupertinoIcons.folder, size: 20),
                    SizedBox(width: 8),
                    AppText('移至分类'),
                  ],
                ),
              ),
              GlassTextButton(
                key: Key(
                  removing ? 'shelf-remove-action' : 'history-delete-action',
                ),
                compact: true,
                onPressed: _selected.isEmpty || _assigningCategory
                    ? null
                    : () {
                        unawaited(
                          removing ? _removeFromShelf() : _deleteHistory(),
                        );
                      },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ArchiveIcon(
                      removing ? CupertinoIcons.bookmark : CupertinoIcons.trash,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    AppText(removing ? '移出书架' : '删除'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
