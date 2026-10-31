part of 'library_page.dart';

/// 书架页的动作部分：页头、更多菜单、编辑栏共用的动作，以及打开书籍与
/// 移出书架 / 删除历史。原来都写在 `library_page.dart` 的状态类里，把那个
/// 文件推过了行数预算，按职责挪到这里。
mixin _LibraryPageActions on _LibraryPageStateBase {
  void _selectTab(int tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      // 编辑态与选中集合属于当前 tab，切 tab 时回到浏览态。
      _editing = false;
      _selected.clear();
      _entered.clear();
    });
    if (tab == 0) unawaited(_refreshUpdates());
  }

  Future<void> _setLayout(BookshelfLayout layout) async {
    if (layout == _layout) return;
    final generation = ++_layoutGeneration;
    setState(() {
      _layout = layout;
      // 版式切换后入场动画重播一次（新视图首屏），滚动回看仍不重放。
      _entered.clear();
    });
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setInt(_bookshelfLayoutPreference, layout.index)) {
        throw StateError('Bookshelf layout was not saved');
      }
    } catch (_) {
      if (mounted && generation == _layoutGeneration) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('布局已更新，但未能保存')));
      }
    }
  }

  void _handleMenu(_MenuAction action) {
    final layout = action.layout;
    if (layout != null) {
      _setLayout(layout);
      return;
    }
    if (action == _MenuAction.importBook) {
      _importLocalBook();
      return;
    }
    if (action == _MenuAction.clearHistory) {
      _confirmClear();
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CachedBooksPage()),
      );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入《${book.title}》')));
    } catch (e) {
      if (mounted) {
        final message = e is FormatException ? e.message : '请重试';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败：$message')));
      }
    } finally {
      if (mounted) setState(() => _importingBook = false);
    }
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  /// 优先用缓存续读；未命中时保留离线阅读与详情页加载入口。
  Future<void> _open(MediaItem item, {bool importedResume = false}) async {
    if (ImportedBookStore.isLocalBookId(item.id)) {
      await _openLocalBook(item);
      return;
    }
    final preferences = BookOpenPreferences.instance;
    await preferences.load();
    if (!mounted) return;
    if ((importedResume || preferences.shelfDirectReader.value) &&
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
    if (await _openCached(item)) return;
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地书籍文件不可用')));
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

  /// 离线直读：只有小说有章节缓存，且必须在无网时才抢在详情页前面。
  Future<bool> _openCached(MediaItem item) async {
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

  List<_ShelfEntry> get _visibleEntries => switch (_tab) {
    1 => _browseHistory,
    2 => _sortShelf([
      for (final entry in _collection)
        if (_collectionFilter == null ||
            entry.item.kind == _collectionFilter)
          entry,
    ]),
    _ => _sortShelf(_shelf),
  };

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
    HapticFeedback.mediumImpact();
    _enterEdit(entry);
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
    final localBooks = [
      for (final entry in selected)
        if (ImportedBookStore.isLocalBookId(entry.item.id)) entry.item.id,
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
      for (final id in localBooks) {
        try {
          await ImportedBookStore.instance.deleteBook(id);
        } catch (_) {}
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('移出书架失败，请重试')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('撤销失败，请重新添加')));
        // 恢复失败意味着乐观列表可能与磁盘不一致：回真。
        _load();
      }
    }
  }

  /// 浏览历史 tab 的「删除」：按选中条目单条删除
  /// （[LibraryStore.removeHistoryEntries]，短剧页已在用的同一 API）。
  ///
  /// 决策：不可逆操作必拦——历史删除没有撤销窗口，保留确认对话框。
  Future<void> _deleteHistory() async {
    final selected = [
      for (final entry in _browseHistory)
        if (_selected.contains(entry.selectionKey)) entry,
    ];
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除历史记录'),
        content: Text('确定删除选中的 ${selected.length} 条记录吗？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              foregroundColor: ShelfTokens.deleteRed,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
        _load();
      }
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定清空全部阅读历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await LibraryStore.instance.clearHistory();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清空失败，请重试')));
      }
    }
  }
}
