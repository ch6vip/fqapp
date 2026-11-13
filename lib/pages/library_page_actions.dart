part of 'library_page.dart';

/// 书架页的动作部分：页头、更多菜单、编辑栏共用的动作，以及打开书籍与
/// 移出书架 / 删除历史。原来都写在 `library_page.dart` 的状态类里，把那个
/// 文件推过了行数预算，按职责挪到这里。
mixin _LibraryPageActions on _LibraryPageStateBase {
  ShelfTabScope get _scope => _scopeForTab(_tab);

  ShelfTabScope _scopeForTab(int tab) => switch (tab) {
    1 => ShelfTabScope.history,
    2 => ShelfTabScope.collection,
    _ => ShelfTabScope.shelf,
  };

  /// 当前 tab 持久化的分类原值；只给分类弹层的选中态用。
  String get _rawCategory => ShelfViewStore.instance.categoryOf(_scope);

  /// 当前 tab 实际参与过滤的分类。分组未就绪时 [ShelfGroupStore.resolveCategory]
  /// 返回 null：此时必须降级成「全部」，否则持久化的组 id 在
  /// [ShelfGroupStore.matchesKey] 里永远匹配不到（未就绪时 `groupOfKey` 恒为
  /// `_unfiled`），书架 / 收藏 / 历史会整页为空（design D-M4）。
  String get _category => _categoryForTab(_tab);

  String _categoryForTab(int tab) =>
      ShelfGroupStore.instance.resolveCategory(
        ShelfViewStore.instance.categoryOf(_scopeForTab(tab)),
      ) ??
      ShelfCategory.all;

  /// 分类弹层的选中值：就绪时用解析后的分类（已删除的组回落到全部），
  /// 未就绪时保留原值，弹层自己显示只读提示。
  String get _categoryForSheet =>
      ShelfGroupStore.instance.resolveCategory(_rawCategory) ?? _rawCategory;

  int get _activeFilters => _activeFiltersForTab(_tab);

  int _activeFiltersForTab(int tab) {
    if (tab == 1) return 0;
    final state = ShelfViewStore.instance.state;
    return (state.sort != ShelfSort.recentRead ? 1 : 0) +
        (state.filter != ShelfReadingFilter.all ? 1 : 0) +
        (state.source != ShelfSourceFilter.all ? 1 : 0);
  }

  void _selectTab(int tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      // 编辑态与选中集合属于当前 tab，切 tab 时回到浏览态。
      _editing = false;
      _selected.clear();
    });
    if (tab == 0) unawaited(_refreshUpdates());
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _persist(
    Future<void> Function() action, {
    String message = '设置已更新，但未能保存',
  }) async {
    try {
      await action();
    } catch (_) {
      _showSnack(message);
    }
  }

  Future<void> _openViewSheet({
    ShelfViewTarget target = ShelfViewTarget.all,
  }) async {
    final view = ShelfViewStore.instance;
    await showJellySheet<void>(
      context: context,
      reduceMotion: _reduceMotion,
      heightFactor: .86,
      builder: (sheet) => ListenableBuilder(
        listenable: view,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: ShelfViewOptions(
            target: target,
            mode: view.mode,
            onModeChanged: (mode) =>
                _persist(() => view.setMode(mode), message: '布局已更新，但未能保存'),
            density: view.state.density,
            onDensityChanged: (density) =>
                _persist(() => view.setGridDensity(density)),
            preferences: view.shelfPreferences,
            onPreferencesChanged: (preferences) =>
                _persist(() => view.setShelfPreferences(preferences)),
            gridViewport: _gridViewport,
            onShowLayoutOptions: target == ShelfViewTarget.collection
                ? () {
                    Navigator.pop(sheet);
                    unawaited(_openViewSheet());
                  }
                : null,
          ),
        ),
      ),
    );
  }

  Future<void> _openFilterSheet() async {
    final view = ShelfViewStore.instance;
    await showJellySheet<void>(
      context: context,
      reduceMotion: _reduceMotion,
      heightFactor: .82,
      builder: (sheet) => ListenableBuilder(
        listenable: view,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: ShelfFilterOptions(
            sort: view.state.sort,
            reading: view.state.filter,
            source: view.state.source,
            cachedAvailable: _cacheScanComplete,
            onSort: (value) => _persist(() => view.setSort(value)),
            onReading: (value) => _persist(() => view.setFilter(value)),
            onSource: (value) => _persist(() => view.setSource(value)),
          ),
        ),
      ),
    );
  }

  Future<void> _openCategorySheet() async {
    final store = ShelfGroupStore.instance;
    final scope = _scope;
    final items = [for (final entry in _entriesForScope(scope)) entry.item];
    final result = await showShelfGroupsSheet(
      context,
      store: store,
      selected: _categoryForSheet,
      reduceMotion: _reduceMotion,
      items: items,
    );
    if (!mounted || result == null || !store.isReady) return;
    await _persist(
      () => ShelfViewStore.instance.setCategoryOf(scope, result),
      message: '分类已更新，但未能保存',
    );
  }

  Future<void> _clearFilters() async {
    final view = ShelfViewStore.instance;
    await _persist(() => view.setSort(ShelfSort.recentRead));
    await _persist(() => view.setFilter(ShelfReadingFilter.all));
    await _persist(() => view.setSource(ShelfSourceFilter.all));
    await _persist(() => view.setCategoryOf(_scope, ShelfCategory.all));
    if (mounted && _tab == 2) setState(() => _collectionFilter = null);
  }

  Future<void> _openMoreMenu(BuildContext anchor) async {
    final action = await showGlassMenu<_MenuAction>(
      context: anchor,
      reduceMotion: _reduceMotion,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in _MenuAction.values)
            GlassMenuItem(
              key: Key('library-menu-${value.name}'),
              label: value.label,
              icon: value.icon,
              order: value.index,
              enabled:
                  value != _MenuAction.clearHistory ||
                  _browseHistory.isNotEmpty,
              onPressed: () => Navigator.pop(menu, value),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MenuAction.importBook:
        await _importLocalBook();
      case _MenuAction.cachedBooks:
        _openCachedBooks();
      case _MenuAction.clearHistory:
        await _confirmClear();
    }
  }

  Future<void> _importLocalBook() async {
    if (_importingBook) return;
    setState(() => _importingBook = true);
    try {
      final book = await ImportedBookStore.instance.pickAndImport();
      if (book == null || !mounted) return;
      await ShelfStore.instance.add(book.toMediaItem());
      if (!mounted) return;
      _load();
      _showSnack('已导入《${book.title}》');
    } catch (e) {
      if (mounted) {
        final message = e is FormatException ? e.message : '请重试';
        _showSnack('导入失败：$message');
      }
    } finally {
      if (mounted) setState(() => _importingBook = false);
    }
  }

  void _openSearch() {
    Navigator.push(
      context,
      SearchRoute.open<void>(context, builder: (_) => const SearchPage()),
    );
  }

  /// 优先用缓存续读；未命中时保留离线阅读与详情页加载入口。
  ///
  /// 书旗条目第一行分流到自己的详情页：它的 bookId 是另一套命名空间，
  /// 番茄的续读 / 缓存 / 更新检测都不能碰它（design D-M5）。
  Future<void> _open(MediaItem item, {bool importedResume = false}) async {
    if (isShuqiItem(item)) {
      await openBookDetail(context, item, entry: BookOpenEntry.shelf);
      return;
    }
    if (ImportedBookStore.isLocalBookId(item.id)) {
      await _openLocalBook(item);
      return;
    }
    final preferences = BookOpenPreferences.instance;
    await preferences.load();
    if (!mounted) return;
    if (item.source == ShelfIdentity.fanqie &&
        (importedResume || preferences.shelfDirectReader.value) &&
        await openRecentBook(
          context,
          item,
          cache: widget.cacheStore,
          readerStore: widget.readerStore,
          directoryLoader: widget.directoryLoader,
        )) {
      return;
    }
    if (!mounted) return;
    if (item.source == ShelfIdentity.fanqie && await _openCached(item)) return;
    if (!mounted) return;
    if (importedResume) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => DetailPage(
            item: item,
            readerStore: widget.readerStore,
            autoOpenReader: true,
          ),
        ),
      );
      return;
    }
    await openBookDetail(context, item, entry: BookOpenEntry.shelf);
  }

  Future<void> _openLocalBook(MediaItem item) async {
    final store = ImportedBookStore.instance;
    final book = await store.book(item.id);
    if (!mounted) return;
    if (book == null || book.chapters.isEmpty) {
      _showSnack('本地书籍文件不可用');
      return;
    }
    final readerStore = widget.readerStore ?? LibraryStore.instance;
    Map<String, dynamic>? saved;
    try {
      saved = await ReaderHistory(readerStore).load(book.id);
    } catch (_) {}
    if (!mounted) return;
    var startIndex = book.chapters.indexWhere(
      (chapter) => chapter.itemId == saved?['chapterId']?.toString(),
    );
    if (startIndex < 0) {
      final episode = num.tryParse(saved?['episode']?.toString() ?? '');
      startIndex = episode != null && episode.isFinite
          ? episode.toInt().clamp(0, book.chapters.length - 1).toInt()
          : 0;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: book.id,
          title: book.title,
          chapters: book.chapters,
          startIndex: startIndex,
          localOnly: true,
          readerStore: readerStore,
          chapterLoader: (chapter) =>
              store.chapterText(book.id, chapter.itemId),
        ),
      ),
    );
  }

  /// 离线直读：只有番茄小说有章节缓存，且必须在无网时才抢在详情页前面。
  Future<bool> _openCached(MediaItem item) async {
    if (item.source != ShelfIdentity.fanqie) return false;
    final cache = widget.cacheStore ?? ChapterCacheStore.instance;
    final book = await cachedBookForOfflineOpen(
      item,
      cache: cache,
      connectivity: await (widget.connectivity ?? currentConnectivity)(),
    );
    if (book == null || !mounted) return false;
    return openCachedBook(
      context,
      book: book,
      cache: cache,
      readerStore: widget.readerStore,
    );
  }

  /// 空书架上的「查看离线缓存」入口：书架空不等于本地没内容。
  void _openCachedBooks() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const CachedBooksPage()),
  );

  List<_ShelfEntry> _entriesForScope(ShelfTabScope scope) => switch (scope) {
    ShelfTabScope.history => _browseHistory,
    ShelfTabScope.collection => _collection,
    ShelfTabScope.shelf => _shelf,
  };

  /// 当前 tab 的可见条目：历史只按分类过滤、保持时间倒序；书架与收藏走
  /// 同一套排序 / 阅读状态 / 来源 / 分类投影（收藏先按 video/manju 过滤）。
  List<_ShelfEntry> get _visibleEntries => _visibleEntriesForTab(_tab);

  /// 邻页预览只读取目标 tab 的投影，不提前切换当前索引或触发副作用。
  List<_ShelfEntry> _visibleEntriesForTab(int tab) {
    final category = _categoryForTab(tab);
    final view = ShelfViewStore.instance.state;
    final facts = ShelfFilterFacts(
      cachedContentKeys: _cachedContentKeys,
      cacheScanComplete: _cacheScanComplete,
    );
    final store = ShelfGroupStore.instance;
    switch (tab) {
      case 1:
        return [
          for (final entry in _browseHistory)
            if (store.matchesKey(entry.contentKey, entry.author, category))
              entry,
        ];
      case 2:
        final rows = [
          for (final entry in _collection)
            if (_collectionFilter == null || entry.kind == _collectionFilter)
              entry,
        ];
        return ShelfProjection.apply(
          rows,
          sort: view.sort,
          reading: view.filter,
          source: view.source,
          category: category,
          facts: facts,
          categories: store,
        );
      default:
        return ShelfProjection.apply(
          _shelf,
          sort: view.sort,
          reading: view.filter,
          source: view.source,
          category: category,
          facts: facts,
          categories: store,
        );
    }
  }

  bool get _allSelected {
    final entries = _visibleEntries;
    return entries.isNotEmpty &&
        entries.every((entry) => _selected.contains(entry.selectionKey));
  }

  void _toggleSelected(_ShelfEntry entry) {
    setState(() {
      if (!_selected.add(entry.selectionKey)) {
        _selected.remove(entry.selectionKey);
      }
    });
  }

  void _toggleSelectAll() {
    final entries = _visibleEntries;
    final keys = [for (final entry in entries) entry.selectionKey];
    final allSelected = _allSelected;
    setState(() {
      // 取消只作用于当前可见条目：筛选态下不悄悄清掉看不见的选择。
      if (allSelected) {
        _selected.removeAll(keys);
      } else {
        _selected.addAll(keys);
      }
    });
  }

  void _enterEdit([_ShelfEntry? entry]) {
    setState(() {
      _editing = true;
      if (entry != null) _selected.add(entry.selectionKey);
    });
  }

  void _exitEdit() {
    setState(() {
      _editing = false;
      _selected.clear();
    });
  }

  /// 非编辑态长按条目：触感反馈后进编辑态并选中该项。
  void _longPress(_ShelfEntry entry) {
    if (HapticPreferences.instance.value) {
      HapticFeedback.mediumImpact();
    }
    _enterEdit(entry);
  }

  _ShelfEntry? _entryForItem(MediaItem item) {
    final key = ShelfIdentity.contentKeyOf(item);
    for (final entry in _visibleEntries) {
      if (entry.contentKey == key) return entry;
    }
    return null;
  }

  void _tap(_ShelfEntry entry) {
    if (_editing) {
      _toggleSelected(entry);
    } else {
      _open(entry.item, importedResume: entry.importedResume);
    }
  }

  void _tapItem(MediaItem item) {
    final entry = _entryForItem(item);
    if (entry != null) _tap(entry);
  }

  void _longPressItem(MediaItem item) {
    final entry = _entryForItem(item);
    if (entry != null) _longPress(entry);
  }

  Future<void> _moveToCategory() async {
    if (_assigningCategory) return;
    final scope = _scope;
    final keys = {
      for (final entry in _entriesForScope(scope))
        if (_selected.contains(entry.selectionKey)) entry.contentKey,
    };
    if (keys.isEmpty) return;
    final store = ShelfGroupStore.instance;
    if (!store.isReady) {
      _showSnack('分类暂不可用，请稍后再试');
      return;
    }
    final groups = {for (final key in keys) store.groupOfKey(key)};
    setState(() => _assigningCategory = true);
    try {
      final category = await chooseShelfCategory(
        context,
        store: store,
        selected: groups.length == 1 ? groups.single : ShelfCategory.all,
        reduceMotion: _reduceMotion,
      );
      if (!mounted || category == null || _scope != scope || !_editing) return;
      await store.assignKeys(keys, category);
      if (!mounted) return;
      // A completed write must not dismiss a newer selection or another tab.
      if (_scope == scope && _editing && setEquals(_selected, keys)) {
        _exitEdit();
      }
      _showSnack('已移至「${store.nameOf(category)}」');
    } catch (error, stack) {
      AppLog.w('shelf', '移动分类失败', error: error, stack: stack);
      _showSnack(error is FormatException ? error.message : '移动分类失败，请重试');
    } finally {
      if (mounted) setState(() => _assigningCategory = false);
    }
  }

  /// 书架 / 收藏 tab 的「移出书架」：只把条目移出本地收藏库，阅读
  /// 历史保留。
  ///
  /// 决策：可逆操作勿扰——移出书架有 4s 撤销窗口，直接执行，不再弹确认
  /// 对话框（原对话框的「阅读记录会保留」说明挪进 SnackBar 语义里）。
  Future<void> _removeFromShelf() async {
    final fromCollection = _tab == 2;
    final selected = [
      for (final entry in fromCollection ? _collection : _shelf)
        if (_selected.contains(entry.selectionKey)) entry,
    ];
    if (selected.isEmpty) return;
    // 撤销要按原 addedAt 恢复：移出前把 ShelfRecord 快照留在闭包里。
    final records = [
      for (final entry in selected)
        ShelfRecord(
          item: entry.item,
          addedAt: DateTime.fromMillisecondsSinceEpoch(entry.addedAt),
        ),
    ];
    final keys = [for (final entry in selected) ShelfStore.keyOf(entry.item)];
    final localEntries = [
      for (final entry in selected)
        if (entry.isLocal) entry,
    ];
    final removed = {for (final entry in selected) entry.selectionKey};
    // The list is updated before the write lands: leaving the selection on
    // screen until the disk round trip finishes reads as a dead button.
    _exitEdit();
    setState(() {
      if (fromCollection) {
        _collection = [
          for (final entry in _collection)
            if (!removed.contains(entry.selectionKey)) entry,
        ];
      } else {
        _shelf = [
          for (final entry in _shelf)
            if (!removed.contains(entry.selectionKey)) entry,
        ];
      }
    });
    try {
      await ShelfStore.instance.removeKeys(keys);
      if (localEntries.isNotEmpty) {
        // Clean every removed identity before slow or unavailable file I/O.
        try {
          await ShelfGroupStore.instance.removeAssignments(
            localEntries.map((entry) => entry.contentKey),
          );
        } catch (error, stack) {
          AppLog.w('shelf', '清理本地书分组失败', error: error, stack: stack);
        }
      }
      for (final entry in localEntries) {
        try {
          await ImportedBookStore.instance.deleteBook(entry.item.id);
        } catch (_) {}
      }
    } catch (_) {
      if (mounted) {
        _showSnack('移出书架失败，请重试');
        // A failed write means the optimistic list was wrong: reload it.
        _load();
      }
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已移出 ${selected.length} ${fromCollection ? '部' : '本'}，阅读记录会保留',
        ),
        duration: const Duration(seconds: 4),
        // 带 action 的 SnackBar 默认 persist，duration 不生效，撤销条会挂在根
        // messenger 上跨页常驻（#211）；读屏时仍保留，好让用户够得到撤销。
        persist: MediaQuery.accessibleNavigationOf(context),
        action: SnackBarAction(
          key: const Key('shelf-undo-button'),
          label: '撤销',
          onPressed: () => _undoRemove(records),
        ),
      ),
    );
  }

  /// 撤销移出：按原 addedAt 写回。仅内存级——进程死亡即失效（SnackBar 已
  /// 过期），诚实不做伪恢复。
  Future<void> _undoRemove(List<ShelfRecord> records) async {
    try {
      await ShelfStore.instance.restoreAll(records);
    } catch (_) {
      if (mounted) {
        _showSnack('撤销失败，请重新添加');
        // 恢复失败意味着乐观列表可能与磁盘不一致：回真。
        _load();
      }
    }
  }

  /// 浏览历史 tab 的「删除」：按选中条目单条删除
  /// （[LibraryStore.removeHistoryEntries]，短剧页已在用的同一 API）。
  ///
  /// 决策：不可逆操作必拦——历史删除没有撤销窗口，保留确认（上游果冻
  /// 确认，只有显式确认才返回 true）。
  Future<void> _deleteHistory() async {
    final selected = [
      for (final entry in _browseHistory)
        if (_selected.contains(entry.selectionKey)) entry,
    ];
    if (selected.isEmpty) return;
    final confirmed = await confirmArchiveAction(
      context,
      title: '删除历史记录',
      message: '确定删除选中的 ${selected.length} 条记录吗？此操作无法撤销。',
      confirmLabel: '删除',
      reduceMotion: _reduceMotion,
      destructive: true,
      confirmKey: const Key('history-delete-confirm'),
      cancelKey: const Key('history-delete-cancel'),
    );
    if (!confirmed || !mounted) return;
    final targets = [
      for (final entry in selected)
        (contentId: entry.contentId, kind: entry.item.kind),
    ];
    final removed = {for (final entry in selected) entry.selectionKey};
    // Same optimistic update as 移出书架: the rows leave the screen now, and a
    // failed write reloads the snapshot instead of leaving a lie behind.
    _exitEdit();
    setState(() {
      _browseHistory = [
        for (final entry in _browseHistory)
          if (!removed.contains(entry.selectionKey)) entry,
      ];
    });
    try {
      await LibraryStore.instance.removeHistoryEntries(targets);
    } catch (_) {
      if (mounted) {
        _showSnack('删除失败，请重试');
        _load();
      }
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await confirmArchiveAction(
      context,
      title: '清空历史',
      message: '确定清空全部阅读历史吗？',
      confirmLabel: '清空',
      reduceMotion: _reduceMotion,
      destructive: false,
      confirmKey: const Key('clear-history-confirm'),
      cancelKey: const Key('clear-history-cancel'),
    );
    if (!confirmed || !mounted) return;
    try {
      await LibraryStore.instance.clearHistory();
    } catch (_) {
      if (mounted) _showSnack('清空失败，请重试');
    }
  }
}
