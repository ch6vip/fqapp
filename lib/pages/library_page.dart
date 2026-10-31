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
import '../services/update_check_gate.dart';
import '../widgets/bookshelf_card.dart';
import '../widgets/home/home_chip.dart';
import '../widgets/home/home_design.dart';
import '../widgets/shelf/shelf_design.dart';
import '../widgets/shelf/shelf_empty.dart';
import '../widgets/tab_swipe_area.dart';
import 'cached_book_reader.dart';
import 'cached_books_page.dart';
import 'detail_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

part 'library_page_actions.dart';
part 'library_shelf_chrome.dart';
part 'library_shelf_entry.dart';
part 'library_shelf_views.dart';
part 'library_shelf_widgets.dart';

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

  /// 后台检查目录更新的最短间隔；下拉刷新总是强制检查。测试可传
  /// [Duration.zero]，让每次可见 / 回前台都真正重查。
  final Duration updateCheckInterval;

  const LibraryPage({
    super.key,
    this.onBrowse,
    this.onFindDrama,
    this.cacheStore,
    this.readerStore,
    this.connectivity,
    this.directoryLoader,
    this.chapterCountLoader,
    this.updateCheckInterval = const Duration(minutes: 10),
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

/// 书架页状态的共享字段与生命周期。拆出去的动作 / 页头 / 内容区 mixin
/// （library_page_actions.dart、library_shelf_chrome.dart、
/// library_shelf_views.dart）都 `on` 这个 mixin，从而共用同一份状态。
mixin _LibraryPageStateBase on State<LibraryPage>, WidgetsBindingObserver {
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
  final _updateChecks = UpdateCheckGate();

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

  /// 可见 / 回前台的重查走最短间隔；下拉刷新用 `force: true` 绕过。
  Future<void> _refreshUpdates({bool force = false}) => _updateChecks.run(
    _checkUpdates,
    interval: widget.updateCheckInterval,
    force: force,
  );

  Future<void> _checkUpdates() async {
    final cache = widget.cacheStore ?? ChapterCacheStore.instance;
    final books = [
      for (final entry in _shelf)
        if (entry.item.kind == 'book' &&
            !ImportedBookStore.isLocalBookId(entry.item.id))
          entry.item,
    ];
    var changed = false;
    for (final item in books) {
      try {
        final book = await cache.savedCatalogue(item.id);
        if (!mounted) return;
        if (book != null &&
            book.chapters.length > (_latestChapterCounts[item.id] ?? 0)) {
          _latestChapterCounts[item.id] = book.chapters.length;
          changed = true;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    // 本地缓存扫描不需要网络：先发现的变化马上刷新，不跟着整轮网络探测等。
    if (changed && _visible) {
      _load();
      changed = false;
    }
    if (widget.cacheStore == null || widget.chapterCountLoader != null) {
      final network = await (widget.connectivity ?? probeConnectivity)();
      if (network?.online == true) {
        for (var i = 0; i < books.length; i += 3) {
          if (!mounted || !_visible) break;
          await Future.wait(
            books.skip(i).take(3).map((item) async {
              try {
                final count =
                    await (widget.chapterCountLoader ?? loadBookChapterCount)(
                      item.id,
                    );
                if (!mounted || count <= 0) return;
                if (_latestChapterCounts[item.id] != count) changed = true;
                _latestChapterCounts[item.id] = count;
              } catch (_) {
                // 单本更新检测失败不清空进度或阻止其他书籍更新。
              }
            }),
          );
        }
      }
    }
    // One rebuild for the whole sweep instead of one per batch.
    if (!mounted) return;
    if (changed && _visible) _load();
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
}

/// 书架页状态：共享字段与生命周期在 [_LibraryPageStateBase]，动作 / 页头 /
/// 内容区分别由三个 part 文件里的 mixin 提供；这里只留 build。
class _LibraryPageState extends State<LibraryPage>
    with
        WidgetsBindingObserver,
        _LibraryPageStateBase,
        _LibraryPageActions,
        _LibraryShelfChrome,
        _LibraryShelfViews {
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
                    onRefresh: () => _refreshUpdates(force: true),
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
}
