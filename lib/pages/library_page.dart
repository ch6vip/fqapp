import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../models/shelf_categories.dart';
import '../models/shelf_identity.dart';
import '../models/shelf_view_state.dart';
import '../models/shuqi_book.dart';
import '../services/app_log.dart';
import '../services/app_style_tokens.dart';
import '../services/book_open_preferences.dart';
import '../services/book_updates.dart';
import '../services/chapter_cache_store.dart';
import '../services/shell_visibility.dart';
import '../services/classic_shelf_layout.dart';
import '../services/connectivity_status.dart';
import '../services/imported_book_store.dart';
import '../services/haptic_preferences.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/reader_history.dart';
import '../services/shelf_group_store.dart';
import '../services/shelf_projection.dart';
import '../services/shelf_store.dart';
import '../services/shelf_view_store.dart';
import '../services/update_check_gate.dart';
import '../widgets/bookshelf_card.dart';
import '../widgets/home/home_chip.dart';
import '../widgets/home/home_design.dart';
import '../widgets/shelf/book_collection_tiles.dart';
import '../widgets/shelf/shelf_collection_view.dart';
import '../widgets/shelf/shelf_design.dart';
import '../widgets/shelf/shelf_empty.dart';
import '../widgets/shelf/shelf_groups_sheet.dart';
import '../widgets/shelf/shelf_performance_scope.dart';
import '../widgets/tab_swipe_area.dart';
import '../widgets/sliding_tab_indicator.dart';
import '../widgets/wenku/archive_shelf.dart';
import '../widgets/wenku/book_collection_layout.dart';
import '../widgets/wenku/shelf_options_sheet.dart';
import '../widgets/wenku/shelf_toolbar.dart';
import '../widgets/wenku/src/app_text.dart';
import '../widgets/wenku/src/archive_shelf_entry.dart';
import '../widgets/wenku/src/dock_layout.dart';
import '../widgets/wenku/wenku_archive.dart';
import '../widgets/wenku/wenku_feature.dart';
import '../widgets/wenku/wenku_glass.dart';
import '../widgets/wenku/wenku_icons.dart';
import '../widgets/wenku/wenku_loading.dart';
import '../widgets/wenku/wenku_overlay.dart';
import '../widgets/wenku/wenku_reveal.dart';
import '../widgets/wenku/wenku_segments.dart';
import 'cached_book_reader.dart';
import 'cached_books_page.dart';
import 'detail_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

part 'library_classic_chrome.dart';
part 'library_classic_views.dart';
part 'library_classic_widgets.dart';
part 'library_page_actions.dart';
part 'library_shelf_chrome.dart';
part 'library_shelf_entry.dart';
part 'library_shelf_views.dart';
part 'library_shelf_widgets.dart';

/// 顶栏一级 tab 的官方文案（amg.xml 的 SlidingTabLayout；顺序同官方
/// 书架页：书架 / 历史 / 收藏）。官方还有「圈子」，本地无此功能不设。
const _tabTitles = ['书架', '浏览历史', '收藏'];

/// 经典主题 tab 下划线在两个标签之间滑动所需的时间。它比文字动画长，因为
/// 下划线要走过一段看得见的距离。
const _classicUnderlineDuration = Duration(milliseconds: 300);

/// 官方分工：书架 tab 只放书籍类，追剧 / 追漫的视频类只进「收藏」tab
/// （与短剧页收藏频道同一批 [ShelfStore] 数据）。
bool _isVideoKind(String kind) => kind == 'video' || kind == 'manju';

/// 「更多」菜单只保留 fqapp 有数据源的入口。版式已移进视图弹层
/// （design §1.3 #10），菜单不再承载 switchGrid/switchDouble/switchList。
enum _MenuAction {
  importBook('导入图书', CupertinoIcons.arrow_down_doc),
  cachedBooks('离线缓存', CupertinoIcons.tray_arrow_down),
  clearHistory('清空历史', CupertinoIcons.trash);

  const _MenuAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 书架页：同一份状态下切换档案书架与旧版经典书架（三 tab）。
///
/// 经典版式由 [ClassicShelfLayout] 独立持久化，使用原三档卡片与页头；
/// 档案版式、排序、阅读状态、来源、分类、宫格密度与立体书架参数来自
/// [ShelfViewStore]；分组来自 [ShelfGroupStore]；排序/筛选由
/// [ShelfProjection] 完成。视觉按上游 1:1（WenkuPage / ShelfToolbar /
/// ArchiveFileCarousel / ShelfNovelRow / ShelfBookGridTile / showJellySheet /
/// GlassMenuAnchor），fqapp 专有行为（长按编辑、多选移出与撤销、历史删除
/// 确认、续读分流、离线直读、更新检测、本地导入、下拉刷新、编辑态拦截返回、
/// 隐藏 tab 不重建）全部保留。
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

  /// 本页在壳层里的下标，用来判断 [shellVisibleTab] 是否指向自己。
  ///
  /// 独立页面/测试把它设成宿主的下标即可；默认按主壳层的顺序取 2。
  final int shellIndex;

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
    this.shellIndex = 2,
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

/// 书架页状态的共享字段与生命周期。拆出去的动作 / 页头 / 内容区 mixin
/// （library_page_actions.dart、library_shelf_chrome.dart、
/// library_shelf_views.dart）都 `on` 这个 mixin，从而共用同一份状态。
mixin _LibraryPageStateBase on State<LibraryPage>, WidgetsBindingObserver {
  /// The anchors of the classic tab buttons, used to place the underline.
  List<GlobalKey> _classicTabKeys = const [];

  /// The measured centres of the classic tabs.
  List<double> _classicTabCentres = const [];
  List<double> _classicTabWidths = const [];

  /// The reserved width of every classic tab.
  ///
  /// Every tab is measured with the *selected* typography (18sp), so the row
  /// keeps the same geometry whichever tab is active. Measuring with the
  /// live typography would make the active tab wider and shift every tab
  /// after it - the row would jump on every swipe.
  double _classicTabWidth(int index) {
    if (index < 0 || index >= _tabTitles.length) return 0;
    final painter = TextPainter(
      text: TextSpan(
        text: _tabTitles[index],
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -.3,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    // 4dp of padding on each side.
    final width = painter.width + 8;
    painter.dispose();
    return width;
  }

  /// Rebuild the anchors when the tab count changes.
  void _syncClassicTabKeys() {
    if (_classicTabKeys.length == _tabTitles.length) return;
    _classicTabKeys = [
      for (var index = 0; index < _tabTitles.length; index++) GlobalKey(),
    ];
  }

  /// Measure the tabs once the layout is done.
  void _scheduleClassicMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureClassicTabs();
    });
  }

  /// Measure the classic tab buttons so the underline can sit on them.
  ///
  /// 宽度只跟文案 + 字体缩放有关，缓存下来：下划线宽度在横滑期间是逐帧
  /// 求值的，每次重排全部 `TextPainter` 等于每帧做几次文本布局。
  ///
  /// 测量结果变了要 `setState`：标签按**实时**字号排版、下划线读的是这份
  /// 缓存，只写字段不重建会让系统字号变化后两者一直错位（直到用户再点一次
  /// 标签才自愈）。
  void _measureClassicTabs() {
    final widths = <double>[
      for (var index = 0; index < _tabTitles.length; index++)
        _classicTabWidth(index),
    ];
    if (widths.length != _tabTitles.length) return;
    final changed = !listEquals(widths, _classicTabWidths);
    _classicTabWidths = widths;
    _classicTabCentres = SlidingTabStrip.centres(widths, gap: 20);
    if (changed && mounted) setState(() {});
  }

  /// The width of the classic tab underline, centred on each tab.
  ///
  /// 26dp is the width the old per-tab underline used; it stays the floor so
  /// two-character labels look unchanged, and longer labels ("浏览历史") grow
  /// up to 40dp instead of being clipped at the old fixed 26.
  static const double _classicIndicatorMinWidth = 26;
  static const double _classicIndicatorMaxWidth = 40;

  /// The underline width at the floating [position].
  ///
  /// Scales with the reserved tab widths so long labels (e.g. "浏览历史")
  /// get a proportionally longer underline.
  double _classicIndicatorWidth(double position) {
    if (_tabTitles.isEmpty) return _classicIndicatorMinWidth;
    // 测量结果由 [_measureClassicTabs] 缓存；还没测过时退回现算一次。
    final widths = _classicTabWidths.length == _tabTitles.length
        ? _classicTabWidths
        : <double>[
            for (var index = 0; index < _tabTitles.length; index++)
              _classicTabWidth(index),
          ];
    return SlidingTabStrip.indicatorWidth(
      widths: widths,
      position: position,
      ratio: 0.5,
      min: _classicIndicatorMinWidth,
      max: _classicIndicatorMaxWidth,
    );
  }

  /// The floating tab position (selected + progress, fractional).
  double _classicFloatingPosition(double progress) => SlidingTabStrip.position(
    index: _tab,
    progress: progress,
    count: _tabTitles.length,
  );

  /// The underline's x (left edge) at the floating [position].
  ///
  /// Delegates to [SlidingTabStrip] for the shared position→left-edge math.
  /// [indicatorWidth] is the full width of the underline bar.
  double? _classicUnderlineLeftForPosition(
    double position,
    double indicatorWidth,
  ) {
    if (_classicTabCentres.isEmpty || _tabTitles.length <= 1) return null;
    return SlidingTabStrip.indicatorLeft(
      centres: _classicTabCentres,
      position: position,
      indicatorWidth: indicatorWidth,
    );
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  int _tab = 0;

  /// The live horizontal swipe progress, handed from the swipe area to the
  /// classic tab row so the underline follows the finger.
  ///
  /// A notifier rather than a plain field: the row is rebuilt on every frame
  /// of the drag, and rebuilding the whole shelf page for that would drop
  /// its scroll positions and the edit selection.
  final ValueNotifier<double> _tabProgress = ValueNotifier<double>(0);
  bool _editing = false;
  bool _importingBook = false;
  bool _assigningCategory = false;
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

  /// 离线缓存扫描结果（源限定键，如 `book:123`）。扫描完成前「已缓存」
  /// 来源筛选不匹配任何行，页面显示「正在检查离线缓存…」；扫描失败时
  /// 保持未完成并显示「离线缓存暂不可用」。
  Set<String> _cachedContentKeys = const {};
  bool _cacheScanComplete = false;
  bool _cacheScanFailed = false;

  /// 立体书架只在首次出现时播放入场；切 tab / 隐藏后回来不重播。
  bool _carouselEntrancePlayed = false;

  /// 最近一次宫格几何，供视图弹层的密度预览使用。
  BookGridViewport? _gridViewport;

  late final Listenable _historyChanges;
  late final Listenable _readTimeChanges;
  late final ValueListenable<int> _shelfChanges;
  late final Listenable _viewChanges;
  late final ClassicShelfLayout _classicLayout;
  late final ValueListenable<int> _groupChanges;

  /// 立体书架宽屏信息栏的按钮文案取决于「书架点书直达阅读器」偏好。
  /// 页面必须在冷启动时加载它并跟随变化，否则用户关掉开关后仍显示
  /// 「继续阅读 / 开始阅读」（design §2.5：传实际值）。
  late final ValueNotifier<bool> _shelfDirectReader;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    shellVisibleTab.addListener(_onShellVisibility);
    _syncClassicTabKeys();
    _scheduleClassicMeasure();
    _historyChanges = LibraryStore.instance.historyListenable
      ..addListener(_storeChanged);
    _readTimeChanges = LibraryStore.instance.readTimeListenable
      ..addListener(_storeChanged);
    _shelfChanges = ShelfStore.instance.listenable..addListener(_storeChanged);
    _viewChanges = ShelfViewStore.instance..addListener(_storeChanged);
    _classicLayout = ClassicShelfLayout.instance..addListener(_storeChanged);
    unawaited(_classicLayout.load());
    _groupChanges = ShelfGroupStore.instance.listenable
      ..addListener(_storeChanged);
    _shelfDirectReader = BookOpenPreferences.instance.shelfDirectReader
      ..addListener(_storeChanged);
    unawaited(BookOpenPreferences.instance.load());
    unawaited(_loadViewPreferences());
    unawaited(_scanCache());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 可见性由壳层的 [shellVisibleTab] 通知，不再读 `TickerMode`：后者会让
    // 整页在每次底部切页时 `didChangeDependencies` → 重建。
    final shown = shellVisibleTab.value;
    _applyVisibility(shown == null || shown == widget.shellIndex);
    // 字号（textScaler）与方向变了要重新量标签：按钮按实时字号排版，
    // 下划线读的是这份测量缓存，不重量就会一直错位。
    _scheduleClassicMeasure();
  }

  /// 壳层切走/切回：只补数据与刷新，不触发整页重建。
  void _onShellVisibility() {
    if (!mounted) return;
    final shown = shellVisibleTab.value;
    _applyVisibility(shown == null || shown == widget.shellIndex);
  }

  void _applyVisibility(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    // Catch up once when returning from another tab or an opaque route.
    if (visible) {
      _load();
      unawaited(_refreshUpdates());
      if (!_cacheScanComplete) unawaited(_scanCache());
    }
  }

  /// Retained pages stay off the rebuild path while hidden: a write only marks
  /// them dirty and the snapshot is reloaded on the next visit.
  void _storeChanged() {
    if (_visible) _load();
  }

  Future<void> _loadViewPreferences() async {
    try {
      await ShelfViewStore.instance.load();
    } catch (_) {
      // ShelfViewStore.load keeps defaults and marks itself loaded.
    }
    if (mounted) _load();
  }

  /// 一次扫描得到「已缓存」来源筛选需要的源限定键。扫描失败保持未完成，
  /// 页面显示「离线缓存暂不可用」，绝不把未扫描当成「没缓存」。
  Future<void> _scanCache() async {
    if (mounted && _cacheScanFailed) {
      setState(() => _cacheScanFailed = false);
    }
    final cache = widget.cacheStore;
    try {
      final List<CachedBookSummary> books;
      if (cache is ChapterCacheStore) {
        books = await cache.books();
      } else if (cache == null) {
        books = await ChapterCacheStore.instance.books();
      } else {
        // An injected cache without the summary API cannot answer the scan;
        // mark it complete so the filter is usable with an empty set.
        if (mounted) {
          _cacheScanComplete = true;
          _load();
        }
        return;
      }
      if (!mounted) return;
      _cachedContentKeys = {
        for (final summary in books)
          ShelfIdentity.contentKeyFor('book', summary.book.id),
      };
      _cacheScanComplete = true;
      // Rebuild the rows: `cached` is folded into each entry at load time.
      _load();
    } catch (error, stack) {
      AppLog.w('shelf', '离线缓存扫描失败', error: error, stack: stack);
      if (mounted) setState(() => _cacheScanFailed = true);
    }
  }

  /// 可见 / 回前台的重查走最短间隔；下拉刷新用 `force: true` 绕过。
  Future<void> _refreshUpdates({bool force = false}) => _updateChecks.run(
    _checkUpdates,
    interval: widget.updateCheckInterval,
    force: force,
  );

  Future<void> _checkUpdates() async {
    final cache = widget.cacheStore ?? ChapterCacheStore.instance;
    // 更新检测只处理番茄小说：书旗走只读会话、本地导入没有上游目录。
    final books = [
      for (final entry in _shelf)
        if (entry.item.kind == 'book' &&
            entry.item.source == ShelfIdentity.fanqie &&
            !ImportedBookStore.isLocalBookId(entry.item.id))
          entry.item,
    ];
    var changed = false;
    for (final item in books) {
      final key = ShelfIdentity.contentKeyOf(item);
      try {
        final book = await cache.savedCatalogue(item.id);
        if (!mounted) return;
        if (book != null &&
            book.chapters.length > (_latestChapterCounts[key] ?? 0)) {
          _latestChapterCounts[key] = book.chapters.length;
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
              final key = ShelfIdentity.contentKeyOf(item);
              try {
                final count =
                    await (widget.chapterCountLoader ?? loadBookChapterCount)(
                      item.id,
                    );
                if (!mounted || count <= 0) return;
                if (_latestChapterCounts[key] != count) changed = true;
                _latestChapterCounts[key] = count;
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
    final byIdentity = <String, Map<String, dynamic>>{
      for (final entry in history)
        ShelfIdentity.contentKeyFor(
          entry['kind']?.toString() ?? 'book',
          historyContentId(entry),
        ): entry,
    };
    setState(() {
      final records = ShelfStore.instance.records();
      _shelf = _shelfEntries([
        for (final record in records)
          if (!_isVideoKind(record.item.kind)) record,
      ], byIdentity);
      _collection = _shelfEntries([
        for (final record in records)
          if (_isVideoKind(record.item.kind)) record,
      ], byIdentity);
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

  /// 书架条目（关联阅读历史取进度/时间），按 contentKey 关联历史，避免
  /// 同数字 id 的番茄 / 书旗互相串进度（design D-M6）。
  List<_ShelfEntry> _shelfEntries(
    List<ShelfRecord> records,
    Map<String, Map<String, dynamic>> byIdentity,
  ) => [
    for (final record in records)
      _ShelfEntry.fromRecord(
        record,
        byIdentity[ShelfIdentity.contentKeyOf(record.item)],
        latestChapterCount:
            _latestChapterCounts[ShelfIdentity.contentKeyOf(record.item)],
        cached: _isCached(record.item),
      ),
  ];

  bool _isCached(MediaItem item) =>
      _cacheScanComplete &&
      item.kind == 'book' &&
      item.source == ShelfIdentity.fanqie &&
      _cachedContentKeys.contains(ShelfIdentity.contentKeyOf(item));

  int _todayReadMinutes() {
    final now = DateTime.now();
    final key = '${now.year}-${now.month}-${now.day}';
    var seconds = 0.0;
    for (final days in LibraryStore.instance.readTimeSnapshot().values) {
      seconds += days[key] ?? 0;
    }
    return seconds ~/ 60;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    shellVisibleTab.removeListener(_onShellVisibility);
    _historyChanges.removeListener(_storeChanged);
    _readTimeChanges.removeListener(_storeChanged);
    _shelfChanges.removeListener(_storeChanged);
    _viewChanges.removeListener(_storeChanged);
    _classicLayout.removeListener(_storeChanged);
    _groupChanges.removeListener(_storeChanged);
    _shelfDirectReader.removeListener(_storeChanged);
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
        _LibraryShelfViews,
        _LibraryClassicChrome,
        _LibraryClassicViews {
  @override
  Widget build(BuildContext context) {
    final classic = AppStyleTokens.of(context).isClassic;
    final topInset = featurePadding(context).top;
    return PopScope<Object?>(
      // 编辑态拦下系统返回 / 侧滑：先退出编辑态，而不是把整页 pop 掉。
      // 书架页是 RootShell 保活容器（移动端 Stack+Offstage / 桌面
      // LazyIndexedStack）的一个 child、不是独立路由，
      // 不拦的话返回事件会一路冒泡到根路由 —— 表现就是「侧滑直接退出应用」。
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) _exitEdit();
      },
      child: classic
          ? _classicPage(context)
          : WenkuPage(
              header: _header(context),
              bottomNavigationBar: _editing ? _editBottomBar(context) : null,
              child: ShelfPerformanceScope(
                shelf3d: ShelfViewStore.instance.state.shelf3d,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(24, topInset, 24, 0),
                      child: _editing
                          ? _editBar(context)
                          : _tabSegments(context),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TabSwipeArea(
                        index: _tab,
                        count: _tabTitles.length,
                        onSelect: _selectTab,
                        onProgress: (value) {
                          if (_tabProgress.value != value) {
                            _tabProgress.value = value;
                          }
                        },
                        // 编辑态里横向拖动留给列表自身（多选/滑动删除的起手）。
                        enabled: !_editing,
                        child: RefreshIndicator(
                          onRefresh: () => _refreshUpdates(force: true),
                          child: _content(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
