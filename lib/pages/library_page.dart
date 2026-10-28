import 'dart:async';

import '../services/desktop_platform.dart';
// 书架页：官方免费小说书架形态的本地重设计（三 tab + 页头分层 +
// 三档版式 + 编辑态）。设计 token、版式/排序枚举集中在
// lib/widgets/shelf/shelf_design.dart（docs/system_design.md）。
//
// 不伪造能力：分组 / 云同步 / 导入图书 / 最近删除均无数据源，
// 不放占位控件；书架内本地搜索也刻意不做（规模小，筛选胶囊 + 排序 + 顶栏
// 全局搜索已覆盖，详见 system_design.md §2）。被砍掉的官方能力与版式偏好
// key 的语义迁移见
// .agents/notes/implemented/feature/2026-09-20-official-bookshelf.md
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../services/book_open_preferences.dart';
import '../services/book_updates.dart';
import '../services/chapter_cache_store.dart';
import '../services/connectivity_status.dart';
import '../services/imported_book_store.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/reader_history.dart';
import '../services/shelf_store.dart';
import '../widgets/bookshelf_card.dart';
import '../widgets/home/home_design.dart';
import '../widgets/shelf/shelf_design.dart';
import '../widgets/shelf/shelf_empty.dart';
import '../widgets/tab_swipe_area.dart';
import 'cached_book_reader.dart';
import 'cached_books_page.dart';
import 'detail_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

/// 版式偏好：0 宫格 / 1 双列 / 2 列表，与 [BookshelfLayout] 的枚举下标一致。
/// 6.0 以前的版本在这里存的是列数 (2..6)，读取时迁移成宫格。
const _bookshelfLayoutPreference = 'bookshelf_layout';

/// 顶栏一级 tab 的官方文案（amg.xml 的 SlidingTabLayout；顺序同官方
/// 书架页：书架 / 历史 / 收藏）。官方还有「圈子」，本地无此功能不设。
const _tabTitles = ['书架', '浏览历史', '收藏'];

/// 官方分工：书架 tab 只放书籍类，追剧 / 追漫的视频类只进「收藏」tab
/// （与短剧页收藏频道同一批 [ShelfStore] 数据）。
bool _isVideoKind(String kind) => kind == 'video' || kind == 'manju';

enum _MenuAction {
  importBook('导入图书', null, LucideIcons.plus),
  switchGrid('切换为宫格', BookshelfLayout.grid, LucideIcons.layout_grid),
  switchDouble('切换为双列', BookshelfLayout.doubleColumn, LucideIcons.columns_2),
  switchList('切换为列表', BookshelfLayout.list, LucideIcons.list),
  clearHistory('清空历史', null, LucideIcons.trash),
  cachedBooks('离线缓存', null, LucideIcons.download);

  const _MenuAction(this.label, this.layout, this.icon);

  final String label;
  final BookshelfLayout? layout;
  final IconData icon;
}

/// 页面动效时长统一入口：无障碍「移除动画」开启时全部退化为瞬时切换。
Duration _motionDuration(BuildContext context, int milliseconds) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

/// 书架页：L1 标题栏（tab + 搜索 + 更多；菜单承载版式/清空历史/离线缓存）/
/// L2 工具栏（今日已读 + 版式分段；收藏 tab 为类型筛选 + 版式分段）/
/// L3 内容区（三档版式）+ 编辑态（长按卡片进入，提供全选与移出书架）。
/// 列表数据分别来自 [ShelfStore]（本地加入书架集合，按官方分工拆进
/// 书架与收藏两个 tab）与 [LibraryStore]（阅读历史）。
class LibraryPage extends StatefulWidget {
  /// 空书架上的「去书城找书」要切到首页 tab；由 RootShell 注入，测试里可以为
  /// 空，此时按钮不响应。
  final VoidCallback? onBrowse;

  /// 收藏 tab 空态上的「找短剧」要切到短剧 tab；由 RootShell 注入，测试里
  /// 可以为空，此时按钮不响应。
  final VoidCallback? onFindDrama;

  /// 离线直读要用的三件外部依赖；都缺省走真实实现，注入后测试可完全离线
  /// （与缓存页、详情页的注入同一套路）。
  final ChapterCache? cacheStore;
  final ReaderStore? readerStore;
  final Future<ConnectivityView> Function()? connectivity;
  final BookDirectoryLoader? directoryLoader;
  final BookChapterCountLoader? chapterCountLoader;

  const LibraryPage({
    super.key,
    this.onBrowse,
    this.onFindDrama,
    this.cacheStore,
    this.readerStore,
    this.connectivity,
    this.directoryLoader,
    this.chapterCountLoader,
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  int _tab = 0;
  BookshelfLayout _layout = BookshelfLayout.grid;
  int _layoutGeneration = 0;
  bool _editing = false;
  bool _importingBook = false;
  final Set<String> _selected = {};
  int _todayMinutes = 0;
  List<_ShelfEntry> _shelf = const [];
  List<_ShelfEntry> _browseHistory = const [];
  List<_ShelfEntry> _collection = const [];

  /// 收藏 tab 的类型筛选：null 全部 / video 短剧 / manju 漫剧（官方还有
  /// 「其他视频」，本地没有这种 kind，不放空壳胶囊）。
  String? _collectionFilter;
  bool _visible = false;
  final Map<String, int> _latestChapterCounts = {};
  Future<void>? _updatesFuture;

  /// 已完成入场动画的条目下标：HomeEntrance 只在首屏（index 0–5）播一次，
  /// 滚动回看不重放（HomeEntrance 的 animate 开关约定）。
  final Set<int> _entered = {};
  late final Listenable _historyChanges;
  late final Listenable _readTimeChanges;
  late final ValueListenable<int> _shelfChanges;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (visible) {
      _load();
      unawaited(_refreshUpdates());
    }
  }

  /// Retained pages stay off the rebuild path while hidden: a write only marks
  /// them dirty and the snapshot is reloaded on the next visit.
  void _storeChanged() {
    if (_visible) _load();
  }

  Future<void> _refreshUpdates() => _updatesFuture ??= _checkUpdates()
      .whenComplete(() => _updatesFuture = null);

  Future<void> _checkUpdates() async {
    final cache = widget.cacheStore ?? ChapterCacheStore.instance;
    final books = [
      for (final entry in _shelf)
        if (entry.item.kind == 'book' &&
            !ImportedBookStore.isLocalBookId(entry.item.id))
          entry.item,
    ];
    for (final item in books) {
      try {
        final book = await cache.savedCatalogue(item.id);
        if (!mounted) return;
        if (book != null &&
            book.chapters.length > (_latestChapterCounts[item.id] ?? 0)) {
          _latestChapterCounts[item.id] = book.chapters.length;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    if (_visible) _load();
    if (widget.cacheStore != null && widget.chapterCountLoader == null) return;
    final network = await (widget.connectivity ?? probeConnectivity)();
    if (network?.online != true) return;
    for (var i = 0; i < books.length; i += 3) {
      if (!mounted || !_visible) return;
      await Future.wait(
        books.skip(i).take(3).map((item) async {
          try {
            final count = await (widget.chapterCountLoader ??
                loadBookChapterCount)(item.id);
            if (!mounted || count <= 0) return;
            _latestChapterCounts[item.id] = count;
            if (_visible) _load();
          } catch (_) {
            // 单本更新检测失败不清空进度或阻止其他书籍更新。
          }
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_visible && state == AppLifecycleState.resumed) {
      unawaited(_refreshUpdates());
    }
  }

  void _load() {
    if (!mounted) return;
    final history = LibraryStore.instance.historySnapshot();
    setState(() {
      final records = ShelfStore.instance.records();
      _shelf = _shelfEntries([
        for (final record in records)
          if (!_isVideoKind(record.item.kind)) record,
      ], history);
      _collection = _shelfEntries([
        for (final record in records)
          if (_isVideoKind(record.item.kind)) record,
      ], history);
      _browseHistory = [
        for (final entry in history) _ShelfEntry.fromHistory(entry),
      ];
      // 选中集合随数据回真：条目在别处被移出 / 删除后，它的键不该继续占着
      // 「已选择 N 本」，也不该把全选判定带偏。
      final available = {
        for (final entry in switch (_tab) {
          1 => _browseHistory,
          2 => _collection,
          _ => _shelf,
        })
          entry.selectionKey,
      };
      _selected.removeWhere((key) => !available.contains(key));
      _todayMinutes = _todayReadMinutes();
    });
  }

  /// 书架条目（关联阅读历史取进度/时间），按 [_sortShelf] 的固定排序输出。
  List<_ShelfEntry> _shelfEntries(
    List<ShelfRecord> records,
    List<Map<String, dynamic>> history,
  ) {
    final byIdentity = <String, Map<String, dynamic>>{
      for (final entry in history)
        '${entry['kind'] ?? 'book'}:${historyContentId(entry)}': entry,
    };
    return [
      for (final record in records)
        _ShelfEntry.fromRecord(
          record,
          byIdentity['${record.item.kind}:${record.item.seriesId ?? record.item.id}'],
          latestChapterCount: _latestChapterCounts[record.item.id],
        ),
    ];
  }

  /// 书架固定按「最近阅读优先」排：有阅读记录的按时间倒序，没有的按加入
  /// 时间倒序（2026-10-13 删掉排序入口后退回的唯一排序，即重设计前的行为）。
  List<_ShelfEntry> _sortShelf(List<_ShelfEntry> entries) {
    final sorted = [...entries];
    sorted.sort((a, b) {
      final left = a.readTime ?? 0;
      final right = b.readTime ?? 0;
      if (left != right) return right.compareTo(left);
      return b.addedAt.compareTo(a.addedAt);
    });
    return sorted;
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
    WidgetsBinding.instance.removeObserver(this);
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

  // -------------------------------------------------------------------------
  // Build.
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return PopScope<Object?>(
      // 编辑态拦下系统返回 / 侧滑：先退出编辑态，而不是把整页 pop 掉。
      // 书架页是 RootShell 里 LazyIndexedStack 的一个 child、不是独立路由，
      // 不拦的话返回事件会一路冒泡到根路由 —— 表现就是「侧滑直接退出应用」。
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) _exitEdit();
      },
      child: Scaffold(
        backgroundColor: palette.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // L1 标题栏：编辑态与浏览态淡切。
              AnimatedSwitcher(
                duration: _motionDuration(context, 200),
                child: _editing
                    ? KeyedSubtree(
                        key: const ValueKey('library-edit-bar'),
                        child: _editBar(palette),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('library-tab-row'),
                        child: _tabRow(palette),
                      ),
              ),
              if (!_editing && _tab == 0) _toolbar(palette),
              if (!_editing && _tab == 2) _collectionToolbar(palette),
              Expanded(
                child: TabSwipeArea(
                  index: _tab,
                  count: _tabTitles.length,
                  onSelect: _selectTab,
                  // 编辑态里横向拖动留给列表自身（多选/滑动删除的起手）。
                  enabled: !_editing,
                  // 只让内容跟手横移：标题栏与工具条固定在顶上，切换后立刻
                  // 显示新的选中项。
                  child: RefreshIndicator(
                    onRefresh: _refreshUpdates,
                    child: _content(palette),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _editing ? _editBottomBar(palette) : null,
      ),
    );
  }

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
              border: Border.all(color: palette.line, width: 0.5),
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
          _CollectionChip(
            key: const Key('library-collection-filter-all'),
            label: '全部',
            selected: _collectionFilter == null,
            palette: palette,
            onTap: () => setState(() => _collectionFilter = null),
          ),
          const SizedBox(width: 8),
          _CollectionChip(
            key: const Key('library-collection-filter-video'),
            label: '短剧',
            selected: _collectionFilter == 'video',
            palette: palette,
            onTap: () => setState(() => _collectionFilter = 'video'),
          ),
          const SizedBox(width: 8),
          _CollectionChip(
            key: const Key('library-collection-filter-manju'),
            label: '漫剧',
            selected: _collectionFilter == 'manju',
            palette: palette,
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

class _ShelfEntry {
  final MediaItem item;

  /// Stable identity of the row: `kind:contentId`, i.e. the same key the shelf
  /// box and the history dedupe use.
  final String selectionKey;

  /// 历史 / 删除 API 用的内容标识（`kind:contentId` 的 contentId 部分）：
  /// 历史条目取存储记录的 `contentId ?? id`（与 LibraryStore 的
  /// _historyIdentity 一致），书架条目取 `seriesId ?? id`。
  final String contentId;

  /// Last read time in milliseconds; null when the work has no history yet.
  final int? readTime;

  /// 加入书架时间，仅书架条目有值。
  final int addedAt;
  final double? progress;
  final int? episode;

  /// 目录总章数。旧历史没有这个字段（null），书架回退到百分比显示。
  final int? chapterCount;
  final int? latestChapterCount;
  final bool importedResume;

  const _ShelfEntry({
    required this.item,
    required this.selectionKey,
    required this.contentId,
    required this.addedAt,
    this.readTime,
    this.progress,
    this.episode,
    this.chapterCount,
    this.latestChapterCount,
    this.importedResume = false,
  });

  factory _ShelfEntry.fromRecord(
    ShelfRecord record,
    Map<String, dynamic>? history, {
    int? latestChapterCount,
  }) => _ShelfEntry(
    item: record.item,
    selectionKey:
        '${record.item.kind}:${record.item.seriesId ?? record.item.id}',
    contentId: record.item.seriesId ?? record.item.id,
    addedAt: record.addedAt.millisecondsSinceEpoch,
    readTime: _timeOf(history),
    progress: _progressOf(history),
    episode: _episodeOf(history),
    chapterCount: _chapterCountOf(history),
    latestChapterCount: latestChapterCount,
    importedResume:
        record.item.kind == 'book' &&
        history?['fanqieImported'] == true &&
        history?['chapterId'] != null,
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
    final contentId = historyContentId(history);
    return _ShelfEntry(
      item: item,
      selectionKey: '${item.kind}:$contentId',
      contentId: contentId,
      addedAt: 0,
      readTime: _timeOf(history),
      progress: _progressOf(history),
      episode: _episodeOf(history),
      chapterCount: _chapterCountOf(history),
      importedResume:
          item.kind == 'book' &&
          history['fanqieImported'] == true &&
          history['chapterId'] != null,
    );
  }

  /// 是否读到最后一章（含章内进度）。
  ///
  /// 官方用「共 N 章·已读完」（strings `bm6`）表达这个状态，而不是把百分比
  /// 四舍五入成 100%——总章数多、剩余章数少时 100% 无法区分「差一点」和
  /// 「读完了」（issue #110 第 3 条）。
  bool get _finished {
    final total = _totalChapterCount;
    final chapter = episode;
    if (total == null || chapter == null) return false;
    if (chapter < total - 1) return false;
    final value = progress;
    return value == null || value >= 1;
  }

  /// 新增章节优先显示「更新」，其余情况显示真实进度。
  ///
  /// 读完时不再显示 100%，让「已读完」只由 [readingText] 表达一次。
  String? get badgeText {
    if (_hasUpdate) return '更新';
    if (_finished) return null;
    final total = _totalChapterCount;
    final chapter = episode;
    // 有总章数时用章序号，读者能看出「还剩多少章」。
    if (total != null && chapter != null && chapter >= 0) {
      return '${chapter + 1}/$total';
    }
    final value = progress;
    if (value == null || value <= 0) return null;
    return '${(value * 100).round()}%';
  }

  /// 宫格副信息 / 列表进度行。
  ///
  /// 有总章数时对齐官方：“第12章 · 共84章”，读完则是“共84章·已读完”
  /// （strings `bm6`）。旧历史没有总章数，回退到原来的百分比。
  String? get readingText {
    final total = _totalChapterCount;
    final chapter = episode;
    if (total != null && chapter != null && chapter >= 0) {
      if (_finished) return '共$total章·已读完';
      return '${_hasUpdate ? '更新 · ' : ''}第${chapter + 1}章 · 共$total章';
    }
    final parts = <String>[];
    if (chapter != null && chapter >= 0) parts.add('第${chapter + 1}章');
    final value = progress;
    if (value != null && value > 0) {
      parts.add('${(value * 100).round()}%');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  bool get _hasUpdate =>
      chapterCount != null &&
      latestChapterCount != null &&
      latestChapterCount! > chapterCount!;

  int? get _totalChapterCount =>
      chapterCount != null &&
      (latestChapterCount == null || latestChapterCount! < chapterCount!)
      ? chapterCount
      : latestChapterCount;

  String? get metaText {
    if (item.author.trim().isNotEmpty) return item.author.trim();
    final relative = _relativeTime(readTime);
    if (relative != null) return relative;
    return bookshelfKindLabel(item.kind);
  }

  String? get infoText =>
      readingText ?? _relativeTime(readTime) ?? bookshelfKindLabel(item.kind);

  String? get subtitleText => item.author.trim().isEmpty
      ? bookshelfKindLabel(item.kind)
      : item.author.trim();
}

/// 编辑态底栏的上滑入场：AnimatedSlide + AnimatedOpacity，首帧隐藏、
/// 下一帧滑入（无障碍关闭动画时直接呈现）。
class _SlideUp extends StatefulWidget {
  final Widget child;

  const _SlideUp({required this.child});

  @override
  State<_SlideUp> createState() => _SlideUpState();
}

class _SlideUpState extends State<_SlideUp> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.disableAnimationsOf(context);
    return AnimatedSlide(
      offset: _shown || disabled ? Offset.zero : const Offset(0, 1),
      duration: disabled ? Duration.zero : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _shown || disabled ? 1 : 0,
        duration: disabled ? Duration.zero : const Duration(milliseconds: 260),
        child: widget.child,
      ),
    );
  }
}

/// 收藏 tab 的筛选胶囊（形态对齐短剧页收藏频道的筛选行）：选中浅橙底
/// 橙字加粗，未选中浅灰底深字。
class _CollectionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final HomePalette palette;
  final VoidCallback onTap;

  const _CollectionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? HomePalette.accent.withValues(alpha: 0.10)
              : palette.soft,
          borderRadius: BorderRadius.circular(ShelfTokens.radiusChip),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? HomePalette.accent : palette.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// 一级 tab：选中 18sp w600，指示条宽度动画（AnimatedContainer）。
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
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: selected ? 18 : 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: -0.3,
                  color: selected ? palette.ink : palette.muted,
                ),
              ),
              const SizedBox(height: 5),
              // 指示条宽度动画；高度恒定保持行高一致。
              AnimatedContainer(
                duration: _motionDuration(context, 220),
                curve: Curves.easeOutCubic,
                width: selected ? 26 : 0,
                height: 3,
                decoration: BoxDecoration(
                  color: selected ? HomePalette.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
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
      child: IconButton(
        onPressed: onTap,
        style: IconButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.all(8),
          minimumSize: const Size(38, 38),
        ),
        icon: Icon(icon, size: 21),
      ),
    );
  }
}

/// L2 版式分段控件：宫格 / 双列 / 列表三个图标按钮，与更多菜单同 handler。
class _LayoutSegments extends StatelessWidget {
  final BookshelfLayout current;
  final HomePalette palette;
  final ValueChanged<BookshelfLayout> onChanged;

  const _LayoutSegments({
    required this.current,
    required this.palette,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(ShelfTokens.radiusButton),
        border: Border.all(color: palette.line, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final layout in BookshelfLayout.values)
            Tooltip(
              message: layout.menuLabel,
              child: InkWell(
                key: Key('shelf-layout-${layout.segmentKey}'),
                onTap: () => onChanged(layout),
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  width: 34,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: layout == current
                        ? HomePalette.accent.withValues(alpha: 0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    layout.menuIcon,
                    size: 17,
                    color: layout == current
                        ? HomePalette.accent
                        : palette.muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 编辑态底栏条目：现代化操作胶囊按钮。
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
    final enabled = onTap != null;
    final fg = enabled ? color : color.withValues(alpha: 0.35);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ShelfTokens.radiusButton),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: fg),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.2,
                color: fg,
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

/// 目录总章数，用于区分「读到末尾」与「全书读完」（issue #110）。
int? _chapterCountOf(Map<String, dynamic>? history) {
  final value = history?['chapterCount'];
  return value is num && value > 0 ? value.toInt() : null;
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
