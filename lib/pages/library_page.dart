// Note: 这是官方番茄免费小说 7.0.9.32 书架形态的本地复刻（双 tab + 页头 +
// 三档版式 + 编辑态）；被砍掉的官方能力（分组/云同步/导入图书/最近删除/
// 连载更新提醒）与版式偏好 key 的语义迁移见
// .agents/notes/implemented/feature/2026-09-20-official-bookshelf.md
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/shelf_store.dart';
import '../widgets/bookshelf_card.dart';
import '../widgets/home/home_design.dart';
import 'cached_books_page.dart';
import 'detail_page.dart';
import 'search_page.dart';

/// 版式偏好：0 宫格 / 1 双列 / 2 列表，与 [BookshelfLayout] 的枚举下标一致。
/// 6.0 以前的版本在这里存的是列数 (2..6)，读取时迁移成宫格。
const _bookshelfLayoutPreference = 'bookshelf_layout';

/// 底栏删除的官方色 `skin_color_red_delete_light`。
const _deleteRed = Color(0xFFF43207);

/// 顶栏一级 tab 的官方文案（amg.xml 的 SlidingTabLayout）。
const _tabTitles = ['书架', '浏览历史'];

enum _MenuAction {
  switchGrid('切换为宫格', BookshelfLayout.grid),
  switchDouble('切换为双列', BookshelfLayout.doubleColumn),
  switchList('切换为列表', BookshelfLayout.list),
  clearHistory('清空历史', null),
  cachedBooks('离线缓存', null);

  const _MenuAction(this.label, this.layout);

  final String label;
  final BookshelfLayout? layout;
}

/// 书架页：顶部「书架 / 浏览历史」双 tab + 搜索 / 更多，书架 tab 带今日已读、
/// 筛选与编辑；列表数据分别来自 [ShelfStore]（本地加入书架集合）与
/// [LibraryStore]（阅读历史）。
class LibraryPage extends StatefulWidget {
  /// 空书架上的「去书城找书」要切到首页 tab；由 RootShell 注入，测试里可以为
  /// 空，此时按钮不响应。
  final VoidCallback? onBrowse;

  const LibraryPage({super.key, this.onBrowse});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int _tab = 0;
  BookshelfLayout _layout = BookshelfLayout.grid;
  int _layoutGeneration = 0;
  bool _filterOpen = false;
  String? _kindFilter;
  bool _editing = false;
  final Set<String> _selected = {};
  int _todayMinutes = 0;
  List<_ShelfEntry> _shelf = const [];
  List<_ShelfEntry> _browseHistory = const [];
  bool _visible = false;
  late final Listenable _historyChanges;
  late final Listenable _readTimeChanges;
  late final ValueListenable<int> _shelfChanges;

  @override
  void initState() {
    super.initState();
    _historyChanges = LibraryStore.instance.historyListenable
      ..addListener(_storeChanged);
    _readTimeChanges = LibraryStore.instance.readTimeListenable
      ..addListener(_storeChanged);
    _shelfChanges = ShelfStore.instance.listenable..addListener(_storeChanged);
    _loadLayoutPreference();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible == visible) return;
    _visible = visible;
    // Catch up once when returning from another tab or an opaque route.
    if (visible) _load();
  }

  /// Retained pages stay off the rebuild path while hidden: a write only marks
  /// them dirty and the snapshot is reloaded on the next visit.
  void _storeChanged() {
    if (_visible) _load();
  }

  void _load() {
    if (!mounted) return;
    final history = LibraryStore.instance.historySnapshot();
    setState(() {
      _shelf = _shelfEntries(ShelfStore.instance.records(), history);
      _browseHistory = [
        for (final entry in history) _ShelfEntry.fromHistory(entry),
      ];
      _todayMinutes = _todayReadMinutes();
    });
  }

  /// 官方排序：最近阅读优先，没有阅读记录的按加入时间降序。
  List<_ShelfEntry> _shelfEntries(
    List<ShelfRecord> records,
    List<Map<String, dynamic>> history,
  ) {
    final byIdentity = <String, Map<String, dynamic>>{
      for (final entry in history)
        '${entry['kind'] ?? 'book'}:${historyContentId(entry)}': entry,
    };
    final entries = [
      for (final record in records)
        _ShelfEntry.fromRecord(
          record,
          byIdentity['${record.item.kind}:${record.item.seriesId ?? record.item.id}'],
        ),
    ];
    entries.sort((a, b) {
      final left = a.readTime ?? 0;
      final right = b.readTime ?? 0;
      if (left != right) return right.compareTo(left);
      return b.addedAt.compareTo(a.addedAt);
    });
    return entries;
  }

  int _todayReadMinutes() {
    final now = DateTime.now();
    final key = '${now.year}-${now.month}-${now.day}';
    var seconds = 0.0;
    for (final days in LibraryStore.instance.readTimeSnapshot().values) {
      seconds += days[key] ?? 0;
    }
    return seconds ~/ 60;
  }

  Future<void> _loadLayoutPreference() async {
    final generation = _layoutGeneration;
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.get(_bookshelfLayoutPreference);
      if (!mounted ||
          generation != _layoutGeneration ||
          saved is! int ||
          saved < 0) {
        return;
      }
      if (saved >= BookshelfLayout.values.length) {
        // 旧语义（每行封面数 2..6）迁移成宫格，并把新值写回去。
        setState(() => _layout = BookshelfLayout.grid);
        await preferences.setInt(
          _bookshelfLayoutPreference,
          BookshelfLayout.grid.index,
        );
        return;
      }
      setState(() => _layout = BookshelfLayout.values[saved]);
    } catch (_) {
      // A layout preference is optional; retain the default and all data.
      // Note: .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md
    }
  }

  @override
  void dispose() {
    _historyChanges.removeListener(_storeChanged);
    _readTimeChanges.removeListener(_storeChanged);
    _shelfChanges.removeListener(_storeChanged);
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Actions shared by the header, the 更多 menu and the edit bar.
  // -------------------------------------------------------------------------

  void _selectTab(int tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      // 编辑态与选中集合属于当前 tab，切 tab 时回到浏览态。
      _editing = false;
      _selected.clear();
      _filterOpen = false;
    });
  }

  Future<void> _setLayout(BookshelfLayout layout) async {
    if (layout == _layout) return;
    final generation = ++_layoutGeneration;
    setState(() => _layout = layout);
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
    if (action == _MenuAction.clearHistory) {
      _confirmClear();
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CachedBooksPage()),
      );
    }
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  void _open(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }

  List<_ShelfEntry> get _visibleEntries {
    final entries = _tab == 0 ? _shelf : _browseHistory;
    final kind = _kindFilter;
    if (kind == null) return entries;
    return [for (final entry in entries) if (entry.item.kind == kind) entry];
  }

  bool get _allSelected {
    final entries = _visibleEntries;
    return entries.isNotEmpty && _selected.length >= entries.length;
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
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(entries.map((entry) => entry.selectionKey));
      }
    });
  }

  void _enterEdit([_ShelfEntry? entry]) {
    setState(() {
      _editing = true;
      _filterOpen = false;
      if (entry != null) _selected.add(entry.selectionKey);
    });
  }

  void _exitEdit() {
    setState(() {
      _editing = false;
      _selected.clear();
    });
  }

  /// 书架 tab 的「移出书架」：只把条目移出本地收藏库，阅读历史保留。
  Future<void> _removeFromShelf() async {
    final selected = [
      for (final entry in _shelf)
        if (_selected.contains(entry.selectionKey)) entry,
    ];
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('确定把选中的 ${selected.length} 本移出书架吗？阅读记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // The list is updated before the write lands. The user just confirmed the
    // removal, and leaving the selection on screen until the disk round trip
    // finishes reads as a dead button.
    final keys = [
      for (final entry in selected) ShelfStore.keyOf(entry.item),
    ];
    final removed = {for (final entry in selected) entry.selectionKey};
    _exitEdit();
    setState(() {
      _shelf = [
        for (final entry in _shelf)
          if (!removed.contains(entry.selectionKey)) entry,
      ];
    });
    try {
      await ShelfStore.instance.removeKeys(keys);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('移出书架失败，请重试')));
        // A failed write means the optimistic list was wrong: reload it.
        _load();
      }
    }
  }

  /// 浏览历史 tab 的「删除」。
  ///
  /// LibraryStore 只有整表清空（clearHistory / clearReadingData），没有单条
  /// 历史删除 API，所以这里只能清空全部；对话框如实说明，不假装选中项被单独
  /// 移除。
  Future<void> _deleteHistory() async {
    final entries = _browseHistory;
    if (entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除历史记录'),
        content: Text('本地阅读历史不支持单条删除，将清空全部 ${entries.length} 条记录。'),
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
    // Same optimistic update as 移出书架: the list empties on screen now, and a
    // failed clear reloads the snapshot instead of leaving a lie behind.
    _exitEdit();
    setState(() => _browseHistory = const []);
    try {
      await LibraryStore.instance.clearHistory();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清空失败，请重试')));
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

  // -------------------------------------------------------------------------
  // Build.
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (_editing) _editBar(palette) else _tabRow(palette),
            if (!_editing && _tab == 0) _shelfHeader(palette),
            if (!_editing && _tab == 1) _historyHeader(palette),
            if (!_editing && _tab == 0 && _filterOpen) _filterPanel(),
            Expanded(child: _content(palette)),
          ],
        ),
      ),
      bottomNavigationBar: _editing ? _editBottomBar(palette) : null,
    );
  }

  /// 顶部一级 tab（选中 20sp / 未选中 16sp，指示条 34dp）+ 右侧两个 24dp 图标。
  Widget _tabRow(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 7, left: 16),
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
            icon: Icons.search,
            color: palette.ink,
            onTap: _openSearch,
          ),
          const SizedBox(width: 8),
          PopupMenuButton<_MenuAction>(
            key: const Key('library-more-button'),
            tooltip: '更多',
            color: palette.surface,
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
                  child: Text(
                    action.label,
                    style: TextStyle(
                      color: action.layout == _layout
                          ? palette.muted
                          : action == _MenuAction.clearHistory
                          ? _deleteRed
                          : palette.ink,
                    ),
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.only(right: 20, left: 8, bottom: 5),
              child: Icon(Icons.more_horiz, size: 24, color: palette.ink),
            ),
          ),
        ],
      ),
    );
  }

  /// 书架 tab 页头（cql.xml）：左侧今日已读，右侧 筛选 / 编辑。
  Widget _shelfHeader(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 6, left: 20, right: 12),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 20, color: palette.ink),
          const SizedBox(width: 1),
          Text(
            '今日已读$_todayMinutes分钟',
            style: TextStyle(
              fontSize: 12,
              // 官方行高 30dp。
              height: 30 / 12,
              color: palette.ink,
            ),
          ),
          const Spacer(),
          _HeaderButton(
            key: const Key('shelf-filter-button'),
            label: '筛选',
            palette: palette,
            onTap: () => setState(() => _filterOpen = !_filterOpen),
          ),
          _HeaderButton(
            key: const Key('shelf-edit-button'),
            label: '编辑',
            palette: palette,
            onTap: _enterEdit,
          ),
        ],
      ),
    );
  }

  /// 浏览历史 tab 只有编辑入口（官方该 tab 的数据只支持整表清空）。
  Widget _historyHeader(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 6, right: 12),
      child: Row(
        children: [
          const Spacer(),
          _HeaderButton(
            key: const Key('history-edit-button'),
            label: '编辑',
            palette: palette,
            onTap: _enterEdit,
          ),
        ],
      ),
    );
  }

  /// 筛选面板：按内容类型过滤（官方 BSFilterPanelLayout 的本地可支撑子集）。
  Widget _filterPanel() {
    final palette = HomePalette.of(context);
    final options = <(String, String?)>[
      ('全部', null),
      for (final kind in bookshelfFilterKinds) (bookshelfKindLabel(kind), kind),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (label, kind) in options)
            ChoiceChip(
              key: Key('shelf-filter-${kind ?? 'all'}'),
              label: Text(label),
              selected: _kindFilter == kind,
              labelStyle: TextStyle(
                fontSize: 13,
                color: _kindFilter == kind ? palette.ink : palette.muted,
              ),
              onSelected: (_) => setState(() => _kindFilter = kind),
            ),
        ],
      ),
    );
  }

  /// 编辑态顶部操作栏（by1.xml）：全选 / 已选择 N 本 / 完成。
  Widget _editBar(HomePalette palette) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          TextButton(
            key: const Key('shelf-select-all'),
            onPressed: _toggleSelectAll,
            style: TextButton.styleFrom(
              foregroundColor: palette.ink,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('全选', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: Center(
              child: Text(
                '已选择 ${_selected.length} 本',
                style: TextStyle(
                  fontSize: 19,
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
              foregroundColor: palette.ink,
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
            child: const Text('完成', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  /// 编辑态底功能栏（amb.xml）：每个条目 28dp 图标 + 10sp 文案。
  ///
  /// 官方底栏还有找相似书 / 移动至分组 / 分享为书单 / 加入桌面 / 云同步 / 导入
  /// 图书 / 最近删除 / 连载更新提醒，这些本地都没有数据源，不伪造入口；有数据
  /// 支撑的只有「移出书架」（书架 tab）与「删除」（浏览历史 tab）。
  Widget _editBottomBar(HomePalette palette) {
    final removing = _tab == 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.dark ? palette.surface : const Color(0xFFFAFAFA),
        border: Border(top: BorderSide(color: palette.line, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _BottomAction(
              key: Key(removing ? 'shelf-remove-action' : 'history-delete-action'),
              icon: removing
                  ? Icons.bookmark_remove_outlined
                  : Icons.delete_outline,
              label: removing ? '移出书架' : '删除',
              color: removing ? palette.ink : _deleteRed,
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
    );
  }

  Widget _content(HomePalette palette) {
    final entries = _visibleEntries;
    if (entries.isEmpty) {
      return _tab == 0 && _shelf.isEmpty
          ? _EmptyShelf(onBrowse: widget.onBrowse)
          : const _EmptyHint(text: '未找到相关内容');
    }
    return switch (_layout) {
      BookshelfLayout.grid => _grid(entries),
      BookshelfLayout.doubleColumn => _doubleGrid(entries),
      BookshelfLayout.list => _list(entries),
    };
  }

  Widget _grid(List<_ShelfEntry> entries) {
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        key: const Key('shelf-grid-view'),
        padding: const EdgeInsets.fromLTRB(
          bookshelfGridSidePadding,
          4,
          bookshelfGridSidePadding,
          24,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: bookshelfGridColumns,
          crossAxisSpacing: bookshelfGridSpacing,
          mainAxisSpacing: bookshelfGridRunSpacing,
          childAspectRatio: bookshelfGridChildAspectRatio(
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
            onLongPress: () => _enterEdit(entry),
          );
        },
      ),
    );
  }

  Widget _doubleGrid(List<_ShelfEntry> entries) {
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        key: const Key('shelf-double-view'),
        padding: const EdgeInsets.fromLTRB(
          bookshelfDoubleSidePadding,
          4,
          bookshelfDoubleSidePadding,
          24,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: bookshelfDoubleSpacing,
          mainAxisSpacing: bookshelfDoubleRunSpacing,
          childAspectRatio: bookshelfDoubleChildAspectRatio(
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
            infoLines: entry.infoLines,
            editing: _editing,
            selected: _selected.contains(entry.selectionKey),
            onTap: () => _tap(entry),
            onLongPress: () => _enterEdit(entry),
          );
        },
      ),
    );
  }

  Widget _list(List<_ShelfEntry> entries) {
    return ListView.separated(
      key: const Key('shelf-list-view'),
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: entries.length,
      separatorBuilder: (context, index) => Divider(
        height: 0.5,
        thickness: 0.5,
        color: HomePalette.of(context).line,
      ),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return BookshelfListCard(
          key: ValueKey('shelf-list-${entry.selectionKey}'),
          item: entry.item,
          progressText: entry.readingText,
          metaText: entry.metaText,
          editing: _editing,
          selected: _selected.contains(entry.selectionKey),
          onTap: () => _tap(entry),
          onLongPress: () => _enterEdit(entry),
        );
      },
    );
  }

  void _tap(_ShelfEntry entry) {
    if (_editing) {
      _toggleSelected(entry);
    } else {
      _open(entry.item);
    }
  }
}

class _ShelfEntry {
  final MediaItem item;

  /// Stable identity of the row: `kind:contentId`, i.e. the same key the shelf
  /// box and the history dedupe use.
  final String selectionKey;

  /// Last read time in milliseconds; null when the work has no history yet.
  final int? readTime;

  /// 加入书架时间，仅书架条目有值。
  final int addedAt;
  final double? progress;
  final int? episode;

  const _ShelfEntry({
    required this.item,
    required this.selectionKey,
    required this.addedAt,
    this.readTime,
    this.progress,
    this.episode,
  });

  factory _ShelfEntry.fromRecord(
    ShelfRecord record,
    Map<String, dynamic>? history,
  ) => _ShelfEntry(
    item: record.item,
    selectionKey:
        '${record.item.kind}:${record.item.seriesId ?? record.item.id}',
    addedAt: record.addedAt.millisecondsSinceEpoch,
    readTime: _timeOf(history),
    progress: _progressOf(history),
    episode: _episodeOf(history),
  );

  factory _ShelfEntry.fromHistory(Map<String, dynamic> history) {
    final item = MediaItem(
      id: historyContentId(history),
      title: history['title']?.toString() ?? '未知作品',
      cover: history['cover']?.toString() ?? '',
      author: history['author']?.toString() ?? '',
      badge: '',
      ep: history['ep']?.toString() ?? '',
      kind: history['kind']?.toString() ?? 'book',
      seriesId: history['seriesId']?.toString(),
      episodeId: history['episodeId']?.toString(),
    );
    return _ShelfEntry(
      item: item,
      selectionKey: '${item.kind}:${item.seriesId ?? item.id}',
      addedAt: 0,
      readTime: _timeOf(history),
      progress: _progressOf(history),
      episode: _episodeOf(history),
    );
  }

  /// 角标（官方是「更新」角标位）里放真实进度，没有进度时不出角标。
  String? get badgeText {
    final value = progress;
    if (value == null || value <= 0) return null;
    return '${(value * 100).round()}%';
  }

  /// 宫格副信息 / 列表进度行：例如「第12章 · 35%」。
  String? get readingText {
    final parts = <String>[];
    final chapter = episode;
    if (chapter != null && chapter >= 0) parts.add('第${chapter + 1}章');
    final value = progress;
    if (value != null && value > 0) {
      parts.add('${(value * 100).round()}%');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String? get metaText {
    if (item.author.trim().isNotEmpty) return item.author.trim();
    final relative = _relativeTime(readTime);
    if (relative != null) return relative;
    return bookshelfKindLabel(item.kind);
  }

  String? get infoText => readingText ?? _relativeTime(readTime) ?? bookshelfKindLabel(item.kind);

  String? get subtitleText =>
      item.author.trim().isEmpty ? bookshelfKindLabel(item.kind) : item.author.trim();

  /// 双列的 简介 槽位（官方 12sp maxLines 4）。模型没有简介字段，这里放真实
  /// 的副信息，而不是编一段文案。
  List<String> get infoLines => [
    ?readingText,
    if (item.author.trim().isNotEmpty) item.author.trim(),
    if (item.ep.trim().isNotEmpty)
      '共 ${item.ep}${switch (item.kind) {
        'video' || 'manju' || 'audio' => '集',
        'manga' => '话',
        _ => '章',
      }}',
  ];
}

/// 空书架（官方文案）：书架暂无书籍 + 去书城找书。
class _EmptyShelf extends StatelessWidget {
  final VoidCallback? onBrowse;

  const _EmptyShelf({this.onBrowse});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 56,
            color: palette.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 14),
          Text(
            '书架暂无书籍',
            style: TextStyle(fontSize: 16, color: palette.muted),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            key: const Key('shelf-browse-button'),
            onPressed: onBrowse,
            style: OutlinedButton.styleFrom(foregroundColor: HomePalette.accent),
            child: const Text('去书城找书'),
          ),
        ],
      ),
    );
  }
}

/// 官方通用空态文案（RecyclerBookLayoutV2）。
class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: Text(text, style: TextStyle(fontSize: 15, color: palette.muted)),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final HomePalette palette;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: selected ? 20 : 16,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? palette.ink : palette.muted,
              ),
            ),
            const SizedBox(height: 4),
            // 指示条 34dp；未选中时占位保持行高一致。
            Container(
              width: 34,
              height: 3,
              decoration: BoxDecoration(
                color: selected ? palette.ink : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _IconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Icon(icon, size: 24, color: color),
        ),
      ),
    );
  }
}

/// 页头文本按钮：官方 14sp、padding 8dp。
class _HeaderButton extends StatelessWidget {
  final String label;
  final HomePalette palette;
  final VoidCallback onTap;

  const _HeaderButton({
    super.key,
    required this.label,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: palette.ink,
        padding: const EdgeInsets.all(8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 14)),
    );
  }
}

/// 编辑态底栏条目：28dp 图标 + 10sp 文案。
class _BottomAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _BottomAction({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final muted = color.withValues(alpha: 0.4);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: onTap == null ? muted : color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                height: 1.2,
                color: onTap == null ? muted : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double? _progressOf(Map<String, dynamic>? history) {
  final value = history?['progress'];
  if (value is! num || value <= 0) return null;
  return value.toDouble().clamp(0, 1);
}

int? _episodeOf(Map<String, dynamic>? history) {
  final value = history?['episode'];
  return value is num && value >= 0 ? value.toInt() : null;
}

int? _timeOf(Map<String, dynamic>? history) {
  final value = history?['time'];
  return value is num && value > 0 ? value.toInt() : null;
}

String? _relativeTime(int? time) {
  if (time == null) return null;
  final date = DateTime.fromMillisecondsSinceEpoch(time);
  final difference = DateTime.now().difference(date);
  if (difference.isNegative || difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes}分钟前';
  if (difference.inDays < 1) return '${difference.inHours}小时前';
  if (difference.inDays < 7) return '${difference.inDays}天前';
  return '${date.month}月${date.day}日';
}
