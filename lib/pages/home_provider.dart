import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/home_cell.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/home_feed_cache.dart';
import '../services/user_facing_error.dart';

typedef HomepageLoader =
    Future<HomepagePage> Function({int tabType, int offset, String? sessionId});
typedef SearchTabsLoader =
    Future<List<SearchTab>> Function(String query, {int page});
typedef CategorySearchLoader = Future<List<SearchTab>> Function({int offset});

/// Immutable view-model of the home recommendation feed.
class HomeState {
  final List<MediaItem> items;

  /// The same page keeping upstream block boundaries (see [HomeCell]).
  ///
  /// Empty when the payload had no recognisable blocks, or when the page came
  /// from the disk cache. Callers that render blocks must fall back to [items]
  /// rather than showing nothing.
  final List<HomeCell> cells;

  final int tabIndex;

  /// 服务端下发的顶栏分类（`data.tab_item`）。空时调用方用 [HomeNotifier.tabs]
  /// 的本地兜底表。
  final List<HomeTabItem> tabs;

  final bool isLoading;
  final bool isLoadMore;
  final bool hasMore;
  final String? error;

  const HomeState({
    this.items = const [],
    this.cells = const [],
    this.tabs = const [],
    this.tabIndex = 0,
    this.isLoading = false,
    this.isLoadMore = false,
    this.hasMore = true,
    this.error,
  });

  HomeState copyWith({
    List<MediaItem>? items,
    List<HomeCell>? cells,
    List<HomeTabItem>? tabs,
    int? tabIndex,
    bool? isLoading,
    bool? isLoadMore,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) {
    return HomeState(
      items: items ?? this.items,
      cells: cells ?? this.cells,
      tabs: tabs ?? this.tabs,
      tabIndex: tabIndex ?? this.tabIndex,
      isLoading: isLoading ?? this.isLoading,
      isLoadMore: isLoadMore ?? this.isLoadMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Mutable pagination state owned by exactly one tab.
class _TabFeed {
  List<MediaItem> items = [];

  /// Upstream blocks for the current page; empty when none were recognised.
  List<HomeCell> cells = [];

  /// 追加页的书：区块管线渲染 `cells`，而分页响应不再带区块结构，新拉的
  /// 书若只进 [items] 就永远进不了网格。这里按去重顺序攒着，发布 state
  /// 时拼进流区块（见 [_streamCellsFor]）。
  final List<MediaItem> appendedStreamItems = [];

  /// 服务端下发的顶栏分类，跟区块一起按整页替换（分页响应里只有第一页
  /// 带 `tab_item`，跟其他光标字段一样不能在追加时被空值冲掉）。
  List<HomeTabItem> tabs = [];
  int offset = 0;
  String? sessionId;
  int searchPage = 0;
  Map<String, int> searchPages = const {};
  Map<String, int> searchOffsets = const {};
  bool manjuSearchExhausted = false;
  bool mangaSearchExhausted = false;
  final Set<String> seen = {};
  bool recommendExhausted = false;
  bool hasMore = true;
  bool loaded = false;

  /// The card the user is currently on, reported by the page as it renders
  /// feeds. Persisted with the snapshot so the next cold start can resume from
  /// it (officially the landing cache keeps one video plus its position,
  /// `recordNextVideoData`, and consumes it once on the first response).
  String? lastVid;

  /// Set when a load seeded its list from the snapshot's resume point; the
  /// first network response then appends instead of replacing (official
  /// `onMoreDataLoaded` path, `Te` → `uf`), and is cleared right after.
  String? resumedVid;

  void reset() {
    items = [];
    cells = [];
    appendedStreamItems.clear();
    offset = 0;
    sessionId = null;
    searchPage = 0;
    searchPages = const {};
    searchOffsets = const {};
    manjuSearchExhausted = false;
    mangaSearchExhausted = false;
    seen.clear();
    recommendExhausted = false;
    hasMore = true;
    loaded = false;
    // A cancelled load must not leave its resume intent behind; lastVid is
    // deliberately kept — it tracks the card on screen across refreshes.
    resumedVid = null;
  }

  /// 发布给 UI 的区块：流区块（384/385 家族）的卡片后面接上追加页的书。
  ///
  /// 只补「无限流」那一个区块——追加页的书本来就是它的续页；其他区块
  /// （排行榜等）保持上游原样。快照缓存存的也是这份拼好的（恢复后网格
  /// 与滚动位置所见一致）。
  List<HomeCell> cellsForView() {
    if (appendedStreamItems.isEmpty) return cells;
    return [
      for (final cell in cells)
        switch (cell.showType) {
          384 => HomeCell(
            showType: cell.showType,
            name: cell.name,
            id: cell.id,
            style: cell.style,
            items: cell.items,
            children: [
              for (final child in cell.children)
                child.showType == 385
                    ? HomeCell(
                        showType: child.showType,
                        name: child.name,
                        id: child.id,
                        style: child.style,
                        items: [...child.items, ...appendedStreamItems],
                        children: child.children,
                        url: child.url,
                        extra: child.extra,
                      )
                    : child,
            ],
            url: cell.url,
            extra: cell.extra,
          ),
          _ => cell,
        },
    ];
  }
}

class _FetchedFeed {
  final List<MediaItem> items;

  /// Upstream blocks, when this page came from the bookstore tab feed.
  /// Empty for search/other sources, which have no block structure.
  final List<HomeCell> cells;

  /// 服务端下发的顶栏分类；空表示这页没带 `tab_item`。
  final List<HomeTabItem> tabs;
  final int? nextOffset;
  final String? sessionId;
  final int searchPage;
  final Map<String, int> searchPages;
  final Map<String, int> searchOffsets;
  final bool manjuSearchExhausted;
  final bool mangaSearchExhausted;
  final bool searchCanAdvance;
  final bool recommendExhausted;
  final bool hasMore;

  const _FetchedFeed({
    required this.items,
    this.cells = const [],
    this.tabs = const [],
    required this.nextOffset,
    required this.sessionId,
    required this.searchPage,
    this.searchPages = const {},
    this.searchOffsets = const {},
    this.manjuSearchExhausted = false,
    this.mangaSearchExhausted = false,
    this.searchCanAdvance = false,
    required this.recommendExhausted,
    required this.hasMore,
  });
}

class _Attempt<T> {
  final T? value;
  final Object? error;

  const _Attempt.value(T this.value) : error = null;
  const _Attempt.error(this.error) : value = null;
}

Future<_Attempt<T>> _attempt<T>(Future<T> future) async {
  try {
    return _Attempt<T>.value(await future);
  } catch (error) {
    return _Attempt<T>.error(error);
  }
}

/// The manju group of the combined feed, with the search cursor state that
/// continues it once the uncursored recommendation stream runs out.
typedef _AllManjuGroup = ({
  List<MediaItem> items,
  int? searchOffset,
  bool searchCanAdvance,
  bool searchExhausted,
  bool hasMore,
});

/// Loads and pages the homepage feeds. Each async operation captures its tab
/// and feed before the first await, so switching tabs can never redirect a
/// late response into a different tab's cache.
class HomeNotifier extends Notifier<HomeState> {
  static const tabs = ['全部', '小说', '短剧', '漫剧', '漫画', '听书', '视频'];
  static const tabKinds = {
    '小说': 'book',
    '短剧': 'video',
    '漫剧': 'manju',
    '漫画': 'manga',
    '听书': 'audio',
    // The 短剧 tab's 推荐 channel. `BookstoreTabType.video_feed = 16`; the
    // bookstore strip happens to label 16 「视频」, while the seriesmall tab
    // shows the same feed under 「推荐」 (用户截图与 ap3.xml 的兜底名都如此).
    '视频': 'video',
  };
  static const tabTypes = {'小说': 2, '短剧': 8, '漫剧': 24, '听书': 5, '视频': 16};

  /// 服务端 `tab_type`（官方 `BookstoreTabType`）→ 卡片种类。
  ///
  /// 服务端下发的 `data.tab_item` 有 11 项（推荐/小说/经典/知识/听书/看剧/
  /// 视频/短篇/漫画/新书/商城），与本地 7 项兜底表既不同长也不同序。若用本地
  /// 表按服务端下标取名字，点「经典」（服务端下标 2）会去拉 `tab_type=8`
  /// （短剧）——串台。所以索引落在服务端表内时，种类与 `tab_type` 都从那一项
  /// 自己的类型推。
  static const _kindByTabType = <int, String>{
    2: 'book', // recommend
    3: 'book', // new_book
    5: 'audio', // audio
    8: 'video', // video_episode（看剧）
    9: 'manga', // comic
    11: 'book', // classic
    12: 'book', // knowledge2
    15: 'book', // ecom_book
    16: 'video', // video_feed
    24: 'manju', // dynamic_comic
    25: 'book', // novel
    31: 'book', // latest_published_book
    103: 'book', // ugc_story（短篇）
  };

  /// 一个顶栏分类的身份：显示名、卡片种类、要请求的 `tab_type`。
  ///
  /// [tabType] 为 null 表示这一项没有可请求的书城流（官方 `female`/`male`
  /// 这类性别入口），只能走搜索兜底。
  ///
  /// 索引口径由 [usesLocalTabs] 决定，**不能靠 state.tabs 是否为空来猜**：
  /// 短剧页（`dramaProvider`）用本地表下标驱动自己的频道条，它的 state.tabs
  /// 同样会被服务端那 11 项填满，若跟着服务端下标解析，它的「短剧」（本地 2）
  /// 就会变成服务端的「经典」。
  ({String name, String kind, int? tabType}) identityOf(int tabIndex) {
    final server = state.tabs;
    if (!usesLocalTabs && tabIndex >= 0 && tabIndex < server.length) {
      final tab = server[tabIndex];
      final type = tab.type;
      return (
        name: tab.title,
        kind: _kindByTabType[type] ?? 'book',
        // 0/1 是官方 female/male 性别入口，没有对应的书城流。
        tabType: type <= 1 ? null : type,
      );
    }
    final name = tabIndex >= 0 && tabIndex < tabs.length
        ? tabs[tabIndex]
        : tabs.first;
    return (
      name: name,
      kind: tabKinds[name] ?? 'book',
      tabType: tabTypes[name],
    );
  }

  final HomepageLoader _homepageLoader;
  final SearchTabsLoader _searchLoader;
  final CategorySearchLoader _mangaSearchLoader;
  final CategorySearchLoader _manjuSearchLoader;
  final HomeFeedCache? _feedCache;
  final int initialTabIndex;

  /// 顶栏下标的口径：`true` 表示这一页的分类条由本地 [tabs] 表驱动。
  ///
  /// 短剧页（[dramaProvider]）的频道条是本地表下标拼的
  /// （`drama_page.dart` 的 `dramaChannels` 全用 `HomeNotifier.tabs.indexOf`），
  /// 而它的 `state.tabs` 同样会被服务端那 11 项填满。若跟着服务端下标解析，
  /// 它的「短剧」（本地下标 2）就会变成服务端的「经典」——所以这一页必须
  /// 固定走本地表，不能靠 `state.tabs` 空不空来猜。
  final bool usesLocalTabs;

  HomeNotifier({
    HomepageLoader? homepageLoader,
    SearchTabsLoader? searchLoader,
    CategorySearchLoader? mangaSearchLoader,
    CategorySearchLoader? manjuSearchLoader,
    HomeFeedCache? feedCache,
    this.initialTabIndex = 0,
    this.usesLocalTabs = false,
  }) : _feedCache = feedCache ?? HomeFeedCache.instance,
       _homepageLoader = homepageLoader ?? ApiClient.instance.homepagePage,
       _searchLoader = searchLoader ?? ApiClient.instance.searchTabs,
       _mangaSearchLoader =
           mangaSearchLoader ??
           (searchLoader == null
               ? _searchManga
               : ({int offset = 0}) =>
                     searchLoader('漫画', page: offset ~/ 10 + 1)),
       _manjuSearchLoader =
           manjuSearchLoader ??
           (searchLoader == null
               ? _searchManju
               : ({int offset = 0}) =>
                     searchLoader('漫剧', page: offset ~/ 10 + 1));

  static Future<List<SearchTab>> _searchManga({int offset = 0}) =>
      ApiClient.instance.searchTabs('漫画', tabType: 8, offset: offset);

  static Future<List<SearchTab>> _searchManju({int offset = 0}) =>
      ApiClient.instance.searchTabs('漫剧', tabType: 11, offset: offset);

  Future<List<SearchTab>> _searchByType(
    String name, {
    int page = 1,
    int offset = 0,
  }) => switch (name) {
    '漫画' => _mangaSearchLoader(offset: offset),
    '漫剧' => _manjuSearchLoader(offset: offset),
    _ => _searchLoader(name, page: page),
  };

  final Map<int, _TabFeed> _feeds = {};
  int _generation = 0;

  /// In-flight feed request. Cancelled when a newer load supersedes it, when
  /// the tab changes, and on dispose, so leaving the page stops the upstream
  /// work instead of only ignoring its result.
  BackendRequest? _activeRequest;

  /// Tabs whose appends are waiting on the debounced snapshot write; see
  /// [_scheduleSave].
  final Set<int> _dirtySaveTabs = {};
  Timer? _saveDebounce;

  /// The category this feed opens on. The home page starts on 全部; a page that
  /// is locked to one channel starts on that channel and never shows the strip.
  @override
  HomeState build() {
    ++_generation;
    // Leaving the page (or rebuilding the provider) stops whatever is in
    // flight instead of only ignoring its result. The pending snapshot write
    // dies with it: _feeds is cleared below, so there is nothing left to save.
    ref.onDispose(() {
      _activeRequest?.cancel();
      _saveDebounce?.cancel();
    });
    _activeRequest?.cancel();
    _feeds.clear();
    return HomeState(tabIndex: initialTabIndex);
  }

  _TabFeed _feedFor(int tabIndex) => _feeds.putIfAbsent(tabIndex, _TabFeed.new);

  /// Reloads the selected tab from page one.
  ///
  /// A manual refresh (pull-to-refresh, error retry) always replaces the list
  /// (official `SaasClientReqType.Refresh` path). A background first load may
  /// resume from the snapshot's last viewed card: the list is trimmed to start
  /// at that card and the network response is appended after it, so the video
  /// on screen never flips to a different one (official landing-cache flow,
  /// `Se` → `sf(listOf(cache))` + `Te` → `uf` append).
  Future<void> load({bool manualRefresh = false}) async {
    final tabIndex = state.tabIndex;
    final generation = ++_generation;
    final feed = _feedFor(tabIndex)..reset();
    // Stale-while-revalidate: show the last rendered cards while the network
    // refresh runs. The cursors stay reset, so the response replaces page one.
    final snapshot = manualRefresh ? null : _feedCache?.load(tabIndex);
    if (snapshot != null) {
      final resumeIndex = snapshot.lastVid == null
          ? -1
          : snapshot.items.indexWhere((item) => item.id == snapshot.lastVid);
      if (resumeIndex > 0) {
        // Resume from the card the user was last on: earlier cards are
        // dropped, matching the official single-video landing cache.
        feed.items = snapshot.items.sublist(resumeIndex);
        feed.resumedVid = snapshot.lastVid;
        // Seed the reported position too: if the user never swipes this
        // session, the next save keeps the same resume point.
        feed.lastVid = snapshot.lastVid;
      } else if (resumeIndex == 0) {
        // Resume point is already the first card; nothing to trim, but the
        // response must still append instead of replacing the visible card.
        feed.resumedVid = snapshot.lastVid;
        feed.lastVid = snapshot.lastVid;
        feed.items = snapshot.items;
      } else {
        // No resume point (or it fell out of the snapshot): show the full
        // snapshot and let the response replace it wholesale, as before.
        feed.items = snapshot.items;
      }
      if (feed.resumedVid != null) {
        // Every snapshot card counts as seen (the client-side equivalent of
        // the official `filterIds` request parameter): a fresh response that
        // still contains them is deduplicated away on append.
        for (final item in snapshot.items) {
          if (item.id.isNotEmpty) feed.seen.add('${item.kind}:${item.id}');
        }
      }
      if (snapshot.cells.isNotEmpty) {
        // Seed the block structure too, so the first frame renders the block
        // layout. Without it the page falls back to the legacy spotlight+grid
        // pipeline and flips to blocks only once the network answers — the
        // flash of the old homepage on every cold start. Older snapshots have
        // no cells and keep the previous behaviour.
        feed.cells = snapshot.cells;
      }
    }
    state = state.copyWith(
      items: feed.items,
      cells: feed.cellsForView(),
      isLoading: true,
      isLoadMore: false,
      hasMore: true,
      clearError: true,
    );

    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();

    try {
      final fetched = await ApiClient.instance.withCancellation(
        request,
        () => _loadInitial(tabIndex),
      );
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      final resume = feed.resumedVid != null;
      feed.resumedVid = null;
      _applyFetched(feed, fetched, replace: !resume);
      state = state.copyWith(
        items: feed.items,
        cells: feed.cellsForView(),
        tabs: feed.tabs,
        isLoading: false,
        isLoadMore: false,
        hasMore: feed.hasMore,
      );
      // 上报只在翻页时发生：看第一张卡没滑动就没有 lastVid——兜底用
      // 当前列表首卡（它就是本次会话实际展示的第一张），让续接链在
      // 下一次冷启动成立。整页替换立即落盘，并清掉翻页留下的待写防抖。
      _saveDebounce?.cancel();
      _dirtySaveTabs.clear();
      _writeSnapshot(tabIndex);
    } catch (error) {
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      feed.hasMore = false;
      // The seeded snapshot (or nothing, on a cold start) stays on screen;
      // the error surface only takes over when there is nothing to show.
      state = state.copyWith(
        error: userFacingError(error),
        isLoading: false,
        isLoadMore: false,
        hasMore: false,
      );
    }
  }

  /// Restores a cached tab immediately. Incrementing the generation happens
  /// even on a cache hit, which invalidates requests started by the old tab.
  void selectTab(int index) {
    // 上限跟着下标口径走：走服务端表时是它下发的分类数（首页 11 个），走本地
    // 表时是本地那 7 个。用错口径会把短剧页的「短剧」（本地下标 2）拦掉或
    // 放进越界下标。
    final limit = usesLocalTabs || state.tabs.isEmpty
        ? tabs.length
        : state.tabs.length;
    if (index == state.tabIndex || index < 0 || index >= limit) return;
    ++_generation;
    _activeRequest?.cancel();
    final cached = _feeds[index];
    state = state.copyWith(
      tabIndex: index,
      items: cached?.items ?? const [],
      // cells / tabs 必须跟着换：切到新 tab 时沿用上一个 tab 的区块会让
      // 首页显示别的 tab 的内容；而回到首页时旧的 cells 已随 feed 重建，
      // 不显式清空就会渲染出上一页的块。
      cells: cached?.cellsForView() ?? const [],
      tabs: state.tabs,
      isLoading: false,
      isLoadMore: false,
      hasMore: cached?.hasMore ?? true,
      clearError: true,
    );
    if (cached == null || !cached.loaded) load();
  }

  /// Appends the next page to the selected feed.
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    final tabIndex = state.tabIndex;
    final generation = _generation;
    final feed = _feedFor(tabIndex);
    state = state.copyWith(isLoadMore: true, clearError: true);

    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();

    try {
      final fetched = await ApiClient.instance.withCancellation(
        request,
        () => _loadNext(tabIndex, feed),
      );
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      _applyFetched(feed, fetched, replace: false);
      state = state.copyWith(
        items: feed.items,
        cells: feed.cellsForView(),
        isLoadMore: false,
        hasMore: feed.hasMore,
      );
      _scheduleSave(tabIndex);
    } catch (error) {
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      // Stop automatic bottom-of-grid retry loops; the error reaches the
      // stream footer's retry state (hasMore alone would read as 「已显示全部
      // 内容」, which lies about a failed page). Pull-to-refresh resets both.
      feed.hasMore = false;
      state = state.copyWith(
        error: userFacingError(error),
        isLoadMore: false,
        hasMore: false,
      );
    }
  }

  /// Writes one tab's current feed to the snapshot store, fire-and-forget.
  ///
  /// 上报只在翻页时发生：看第一张卡没滑动就没有 lastVid——兜底用当前列表
  /// 首卡（它就是本次会话实际展示的第一张），让续接链在下一次冷启动成立。
  void _writeSnapshot(int tabIndex) {
    final feed = _feeds[tabIndex];
    final cache = _feedCache;
    if (feed == null || cache == null || feed.items.isEmpty) return;
    final savedVid = feed.lastVid ?? feed.items.first.id;
    unawaited(
      cache.save(
        tabIndex,
        feed.items,
        hasMore: feed.hasMore,
        lastVid: savedVid,
        cells: feed.cellsForView(),
      ),
    );
  }

  /// Debounced [_writeSnapshot] for pagination.
  ///
  /// A snapshot write encodes up to [HomeFeedCache.maxItems] cards plus the
  /// whole block tree on the UI isolate; firing one per appended page lands
  /// exactly on the frame the new cards render. Debouncing coalesces a paging
  /// burst into one write per tab of its final state. `load()` keeps writing
  /// immediately: it replaces page one (pull-to-refresh, tab entry) and is not
  /// a burst.
  void _scheduleSave(int tabIndex) {
    _dirtySaveTabs.add(tabIndex);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      _saveDebounce = null;
      if (!ref.mounted) return;
      final tabs = _dirtySaveTabs.toSet();
      _dirtySaveTabs.clear();
      for (final tab in tabs) {
        _writeSnapshot(tab);
      }
    });
  }

  /// Records the card currently on screen so the next snapshot save can store
  /// the resume point. The page reports this as the user swipes.
  void noteCurrentVid(String vid) {
    if (vid.isEmpty) return;
    _feedFor(state.tabIndex).lastVid = vid;
  }

  Future<_FetchedFeed> _loadInitial(int tabIndex) async {
    final identity = identityOf(tabIndex);
    final name = identity.name;
    if (name == '全部') return _loadAllInitial();

    final kind = identity.kind;
    final tabType = identity.tabType;
    // 搜索兜底的关键词：推荐流（`tab_type=2`）本身就是小说推荐，拿「推荐」
    // 去搜既不是有效书名也匹配不到搜索结果的 tab；用「小说」才能命中。
    final searchName = tabType == 2 ? '小说' : name;
    Object? loaderFailure;
    if (tabType != null) {
      try {
        final page = await _homepageLoader(tabType: tabType);
        final items = _forceKind(page.items, kind);
        final nextOffset = page.nextOffset;
        final canAdvance = nextOffset != null && nextOffset > 0;
        // 准入条件必须包含 cells：官方书城区块（`tab_type=2`）的书全嵌在
        // `cell_data` 里，`parseMediaItems` 不一定能拉平出 items。只看 items
        // 会把一整页区块当成「空响应」丢掉，然后退回搜索路径，cells 全丢——
        // 这正是真机上区块一个都不出现、首页退回旧网格的原因。
        if (items.isNotEmpty || page.cells.isNotEmpty || canAdvance) {
          return _FetchedFeed(
            items: items,
            cells: page.cells,
            tabs: page.tabs,
            nextOffset: canAdvance ? nextOffset : null,
            sessionId: page.sessionId,
            searchPage: 0,
            recommendExhausted: !canAdvance,
            // Search remains available after recommendations are exhausted.
            hasMore: true,
          );
        }
      } catch (loaderError) {
        // Older backends may not expose recommendations; search below keeps the
        // tab usable — but only when it actually produces something. An empty
        // fallback is a dead page and must surface the original error (the
        // stream footer's retry state depends on it).
        loaderFailure = loaderError;
      }
    }

    final search = await _searchByType(searchName);
    final items = _searchItems(search, searchName, kind);
    if (items.isEmpty && loaderFailure != null) {
      throw loaderFailure;
    }
    final progress = _searchProgress(search, searchName, items, offset: 0);
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: null,
      searchPage: 1,
      searchOffsets: {
        if (progress.nextOffset != null) searchName: progress.nextOffset!,
      },
      searchCanAdvance: progress.hasCursor,
      recommendExhausted: true,
      hasMore: progress.hasMore,
    );
  }

  /// "全部" combines the novel recommendation stream with first pages for
  /// the other supported categories.
  /// Loads the "全部" tab.
  ///
  /// The official bookstore tab (`tab_type=2`) shows its own blocks and nothing
  /// else, so once the recommendation stream answers we stop there: the former
  /// cross-media interleave — mixing short drama, manju, manga and audio search
  /// results into the same card list — is gone. Those sources keep their own
  /// tabs.
  ///
  /// The interleave survives as a degraded path only: when the recommendation
  /// stream fails outright, mixing the other sources keeps the tab usable
  /// instead of blanking it.
  Future<_FetchedFeed> _loadAllInitial() async {
    final recommendation = await _attempt(_loadInitial(1));
    final page = recommendation.value;
    if (page != null && (page.items.isNotEmpty || page.cells.isNotEmpty)) {
      return _FetchedFeed(
        items: page.items,
        cells: page.cells,
        tabs: page.tabs,
        nextOffset: page.nextOffset,
        sessionId: page.sessionId,
        searchPage: page.searchPage,
        searchPages: {'小说': page.searchPage},
        recommendExhausted: page.recommendExhausted,
        hasMore: page.items.isNotEmpty || page.nextOffset != null,
      );
    }
    return _loadAllInterleaved(recommendation);
  }

  /// Degraded path for [loadAll]: the recommendation stream is unavailable, so
  /// mix whatever the other sources returned.
  Future<_FetchedFeed> _loadAllInterleaved(
    _Attempt<_FetchedFeed> recommendation,
  ) async {
    final videoFuture = _attempt(_searchLoader('短剧'));
    final manjuFuture = _attempt(_loadAllManju());
    final mangaFuture = _attempt(_mangaSearchLoader());
    final audioFuture = _attempt(_searchLoader('听书'));

    final video = await videoFuture;
    final manju = await manjuFuture;
    final manga = await mangaFuture;
    final audio = await audioFuture;
    if (recommendation.value == null &&
        video.value == null &&
        manju.value == null &&
        manga.value == null &&
        audio.value == null) {
      throw recommendation.error ??
          video.error ??
          manju.error ??
          manga.error ??
          audio.error ??
          StateError('首页加载失败');
    }

    final manjuGroup = manju.value;
    final manjuItems = manjuGroup?.items ?? const <MediaItem>[];
    final mangaItems = _searchItems(manga.value ?? [], '漫画', 'manga');
    final mangaProgress = _searchProgress(
      manga.value ?? [],
      '漫画',
      mangaItems,
      offset: 0,
    );
    final groups = <List<MediaItem>>[
      if (recommendation.value != null) recommendation.value!.items,
      if (video.value != null) _searchItems(video.value!, '短剧', 'video'),
      manjuItems,
      mangaItems,
      if (audio.value != null) _searchItems(audio.value!, '听书', 'audio'),
    ];
    final page = recommendation.value;
    final items = _interleave(groups);
    return _FetchedFeed(
      items: items,
      nextOffset: page?.nextOffset,
      sessionId: page?.sessionId,
      searchPage: 1,
      searchPages: {
        '小说': page?.searchPage ?? 0,
        if (video.value != null) '短剧': 1,
        if (audio.value != null) '听书': 1,
      },
      searchOffsets: {
        if (manjuGroup?.searchOffset != null) '漫剧': manjuGroup!.searchOffset!,
        if (mangaProgress.nextOffset != null) '漫画': mangaProgress.nextOffset!,
      },
      searchCanAdvance:
          (manjuGroup?.searchCanAdvance ?? false) || mangaProgress.hasCursor,
      manjuSearchExhausted: manjuGroup?.searchExhausted ?? false,
      mangaSearchExhausted: manga.value != null && !mangaProgress.hasMore,
      recommendExhausted: page?.recommendExhausted ?? true,
      hasMore:
          items.isNotEmpty ||
          page?.nextOffset != null ||
          (manjuGroup?.hasMore ?? false) ||
          mangaProgress.hasMore,
    );
  }

  /// The manju group of the combined feed.
  ///
  /// Prefers the dedicated manju stream (`tab_type=24`) over search, for the
  /// same reason the 漫剧 tab already does: the upstream attaches cover badges
  /// to that stream's cards, while search cells carry mostly uncoloured genre
  /// labels. The stream has no page cursor, so search still serves the pages
  /// after the first.
  Future<_AllManjuGroup> _loadAllManju() async {
    try {
      final page = await _homepageLoader(tabType: tabTypes['漫剧']!);
      final items = _forceKind(page.items, 'manju');
      if (items.isNotEmpty) {
        return (
          items: items,
          // Search has not been consulted yet, so paging starts at its first
          // page and there is still a source to advance to.
          searchOffset: 0,
          searchCanAdvance: true,
          searchExhausted: false,
          hasMore: true,
        );
      }
    } catch (_) {
      // Older backends may not expose the stream; fall through to search.
    }
    final tabs = await _manjuSearchLoader();
    final items = _searchItems(tabs, '漫剧', 'manju');
    final progress = _searchProgress(tabs, '漫剧', items, offset: 0);
    return (
      items: items,
      searchOffset: progress.nextOffset,
      searchCanAdvance: progress.hasCursor,
      searchExhausted: !progress.hasMore,
      hasMore: progress.hasMore,
    );
  }

  Future<_FetchedFeed> _loadNext(int tabIndex, _TabFeed feed) async {
    final identity = identityOf(tabIndex);
    final name = identity.name;
    if (name == '全部') return _loadAllNext(feed);

    final kind = identity.kind;
    final searchName = identity.tabType == 2 ? '小说' : name;
    final tabType = identity.tabType;
    Object? loaderFailure;
    if (tabType != null && !feed.recommendExhausted) {
      try {
        final page = await _homepageLoader(
          tabType: tabType,
          offset: feed.offset,
          sessionId: feed.sessionId,
        );
        final items = _forceKind(page.items, kind);
        final nextOffset = page.nextOffset;
        final canAdvance = nextOffset != null && nextOffset > feed.offset;
        // Duplicate or empty pages can still lead to fresh recommendations.
        // Only an advancing cursor is safe to request again.
        if (canAdvance || items.any((item) => _isUnseen(feed, item))) {
          return _FetchedFeed(
            items: items,
            nextOffset: canAdvance ? nextOffset : null,
            sessionId: page.sessionId,
            searchPage: feed.searchPage,
            recommendExhausted: !canAdvance,
            hasMore: true,
          );
        }
      } catch (loaderError) {
        // Fall through to search. A recommendation outage should not make the
        // whole category stop paginating — unless the fallback is empty too,
        // in which case the original error surfaces (see below).
        loaderFailure = loaderError;
      }
    }

    final pageNumber = feed.searchPage + 1;
    final searchOffset = feed.searchOffsets[searchName] ?? 0;
    final searchTabs = await _searchByType(
      searchName,
      page: pageNumber,
      offset: searchOffset,
    );
    final items = _searchItems(searchTabs, searchName, kind);
    if (items.isEmpty && loaderFailure != null) {
      throw loaderFailure;
    }
    final progress = _searchProgress(
      searchTabs,
      searchName,
      items,
      offset: searchOffset,
    );
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: feed.sessionId,
      searchPage: pageNumber,
      searchOffsets: {
        ...feed.searchOffsets,
        if (progress.nextOffset != null) searchName: progress.nextOffset!,
      },
      searchCanAdvance: progress.hasCursor,
      recommendExhausted: true,
      hasMore: progress.hasMore,
    );
  }

  Future<_FetchedFeed> _loadAllNext(_TabFeed feed) async {
    final pageNumber = feed.searchPage + 1;
    // Novel recommendations and search have their own cursor. In particular,
    // the first fallback search must start at page one even if the other
    // categories have already loaded several pages.
    final bookFeed = _TabFeed()
      ..offset = feed.offset
      ..sessionId = feed.sessionId
      ..searchPage = feed.searchPages['小说'] ?? 0
      ..recommendExhausted = feed.recommendExhausted;
    bookFeed.seen.addAll(feed.seen);
    final recommendationFuture = _attempt(_loadNext(1, bookFeed));
    final videoPage = (feed.searchPages['短剧'] ?? 0) + 1;
    final audioPage = (feed.searchPages['听书'] ?? 0) + 1;
    final videoFuture = _attempt(_searchLoader('短剧', page: videoPage));
    final manjuOffset = feed.searchOffsets['漫剧'] ?? 0;
    final manjuFuture = feed.manjuSearchExhausted
        ? Future.value(const _Attempt<List<SearchTab>>.value([]))
        : _attempt(_manjuSearchLoader(offset: manjuOffset));
    final mangaOffset = feed.searchOffsets['漫画'] ?? 0;
    final mangaFuture = feed.mangaSearchExhausted
        ? Future.value(const _Attempt<List<SearchTab>>.value([]))
        : _attempt(_mangaSearchLoader(offset: mangaOffset));
    final audioFuture = _attempt(_searchLoader('听书', page: audioPage));

    final recommendation = await recommendationFuture;
    final video = await videoFuture;
    final manju = await manjuFuture;
    final manga = await mangaFuture;
    final audio = await audioFuture;
    if (recommendation.value == null &&
        video.value == null &&
        manju.value == null &&
        manga.value == null &&
        audio.value == null) {
      throw recommendation.error ??
          video.error ??
          manju.error ??
          manga.error ??
          audio.error ??
          StateError('首页分页失败');
    }

    final manjuItems = _searchItems(manju.value ?? [], '漫剧', 'manju');
    final manjuProgress = _searchProgress(
      manju.value ?? [],
      '漫剧',
      manjuItems,
      offset: manjuOffset,
    );
    final mangaItems = _searchItems(manga.value ?? [], '漫画', 'manga');
    final mangaProgress = _searchProgress(
      manga.value ?? [],
      '漫画',
      mangaItems,
      offset: mangaOffset,
    );
    final groups = <List<MediaItem>>[
      if (recommendation.value != null) recommendation.value!.items,
      if (video.value != null) _searchItems(video.value!, '短剧', 'video'),
      manjuItems,
      mangaItems,
      if (audio.value != null) _searchItems(audio.value!, '听书', 'audio'),
    ];
    final recommendationPage = recommendation.value;
    final items = _interleave(groups);
    // 推荐源翻页报错、其余兜底源也没产出时把错误透传出去——否则 loadMore
    // 拿到一页空「成功」，流尾会把加载失败谎报成「已显示全部内容」。
    if (items.isEmpty && recommendationPage == null) {
      throw recommendation.error ?? StateError('翻页失败');
    }
    return _FetchedFeed(
      items: items,
      nextOffset: recommendationPage?.nextOffset,
      sessionId: recommendationPage?.sessionId ?? feed.sessionId,
      searchPage: pageNumber,
      searchPages: {
        ...feed.searchPages,
        if (recommendationPage != null) '小说': recommendationPage.searchPage,
        if (video.value != null) '短剧': videoPage,
        if (audio.value != null) '听书': audioPage,
      },
      searchOffsets: {
        ...feed.searchOffsets,
        if (manjuProgress.nextOffset != null) '漫剧': manjuProgress.nextOffset!,
        if (mangaProgress.nextOffset != null) '漫画': mangaProgress.nextOffset!,
      },
      searchCanAdvance: manjuProgress.hasCursor || mangaProgress.hasCursor,
      manjuSearchExhausted:
          feed.manjuSearchExhausted ||
          (manju.value != null && !manjuProgress.hasMore),
      mangaSearchExhausted:
          feed.mangaSearchExhausted ||
          (manga.value != null && !mangaProgress.hasMore),
      recommendExhausted:
          recommendationPage?.recommendExhausted ?? feed.recommendExhausted,
      hasMore:
          items.isNotEmpty ||
          (recommendationPage != null &&
              recommendationPage.nextOffset != null) ||
          manjuProgress.hasMore ||
          mangaProgress.hasMore,
    );
  }

  void _applyFetched(
    _TabFeed feed,
    _FetchedFeed fetched, {
    required bool replace,
  }) {
    final fresh = <MediaItem>[];
    for (final item in fetched.items) {
      final key = '${item.kind}:${item.id}';
      if (item.id.isNotEmpty && feed.seen.add(key)) fresh.add(item);
    }
    feed
      ..items = replace ? fresh : [...feed.items, ...fresh]
      // 区块只在整页替换时跟着换：追加一页时上游给的是同一批块的续页，
      // 把新块接在后面会让标题重复出现。
      //
      // 但「续播」路径（replace=false）不一样：它保的是 items 不清空，区块
      // 本来就没有旧值可保——从落地缓存恢复时 feed.cells 是空的，若也跳过
      // 赋值，首页就永远拿不到区块，只能退回旧网格。真机冷启动必命中落地
      // 缓存，所以这条路径就是「真机上区块一个都不出现」的根因。
      ..cells = (replace || feed.cells.isEmpty) ? fetched.cells : feed.cells
      // 追加页的书拼进流区块（见 cellsForView）——续播路径的第一页例外：
      // 它本来就是整页区块，只是 items 保留了缓存，别把首页书重复拼一遍。
      ..appendedStreamItems.addAll(
        (!replace &&
                feed.cells.where((c) => c.showType == 384).isNotEmpty &&
                feed.resumedVid == null)
            ? fresh
            : const <MediaItem>[],
      )
      ..tabs = fetched.tabs.isNotEmpty ? fetched.tabs : feed.tabs
      ..offset = fetched.nextOffset ?? feed.offset
      ..sessionId = fetched.sessionId ?? feed.sessionId
      ..searchPage = fetched.searchPage
      ..searchPages = fetched.searchPages
      ..searchOffsets = fetched.searchOffsets
      ..manjuSearchExhausted = fetched.manjuSearchExhausted
      ..mangaSearchExhausted = fetched.mangaSearchExhausted
      ..recommendExhausted = fetched.recommendExhausted
      ..hasMore = fetched.hasMore
      ..loaded = true;

    // If a page contained only duplicates and no source has a known cursor,
    // stop cleanly instead of repeatedly requesting the same page.
    if (!replace &&
        fresh.isEmpty &&
        fetched.nextOffset == null &&
        !fetched.searchCanAdvance) {
      feed.hasMore = false;
    }
  }

  bool _isUnseen(_TabFeed feed, MediaItem item) =>
      item.id.isNotEmpty && !feed.seen.contains('${item.kind}:${item.id}');

  List<MediaItem> _searchItems(
    List<SearchTab> searchTabs,
    String label,
    String kind,
  ) {
    searchTabs = separateManjuSearchTabs(searchTabs);
    final matching = searchTabs.where(
      (tab) =>
          tab.title.isNotEmpty &&
          (tab.title.contains(label) || label.contains(tab.title)),
    );
    final selected = matching.isEmpty ? searchTabs : matching;
    return selected
        .expand((tab) => tab.items)
        .where((item) => item.kind == kind)
        .toList(growable: false);
  }

  // Note: 首页漫画与漫剧都保留 v1 搜索游标，重复页不等于结束；见
  // .agents/notes/implemented/bug-fix/2026-09-10-search-categories.md
  ({bool hasMore, int? nextOffset, bool hasCursor}) _searchProgress(
    List<SearchTab> tabs,
    String label,
    List<MediaItem> items, {
    required int offset,
  }) {
    if (label != '漫剧' && label != '漫画') {
      return (hasMore: items.isNotEmpty, nextOffset: null, hasCursor: false);
    }
    for (final tab in separateManjuSearchTabs(tabs)) {
      if (tab.title != label ||
          (tab.hasMore == null && tab.nextOffset == null)) {
        continue;
      }
      final next = tab.nextOffset;
      final advances = tab.hasMore != false && next != null && next > offset;
      return (
        hasMore: advances,
        nextOffset: advances ? next : null,
        hasCursor: advances,
      );
    }
    // Compatibility with loaders lacking cursor metadata. The dedicated
    // category search requests ten results; known upstream cursors win above.
    return (
      hasMore: items.isNotEmpty,
      nextOffset: items.isEmpty ? null : offset + 10,
      hasCursor: false,
    );
  }

  List<MediaItem> _forceKind(List<MediaItem> items, String kind) {
    // copyWith rather than a hand-written rebuild: rebuilding by hand dropped
    // the cover badge (and would drop any future field) on every home tab.
    return items
        .where((item) => item.kind != 'manju' || kind == 'manju')
        .map((item) => item.copyWith(kind: kind))
        .toList(growable: false);
  }

  /// Round-robin groups so the combined feed does not show a solid block of
  /// one category before the next category begins.
  List<MediaItem> _interleave(List<List<MediaItem>> groups) {
    final result = <MediaItem>[];
    final maxLength = groups.fold<int>(
      0,
      (max, group) => group.length > max ? group.length : max,
    );
    for (var index = 0; index < maxLength; index++) {
      for (final group in groups) {
        if (index < group.length) result.add(group[index]);
      }
    }
    return result;
  }
}

final homeProvider = NotifierProvider<HomeNotifier, HomeState>(
  // 2026-10-24 用户决定：首页顶栏回到本地六分类（推荐/小说/短剧/漫剧/
  // 漫画/听书），不用服务端下发的 11 项——服务端表里没有「短剧/漫剧」，
  // 过滤不出这套组合，所以身份口径整条走本地表（同 dramaProvider 的
  // usesLocalTabs 机制）。
  () => HomeNotifier(usesLocalTabs: true),
);

// Note: 底部导航的短剧目的地用第二个 HomeNotifier 实例而不是复用 homeProvider，
// 理由与被否掉的方案见
// .agents/notes/implemented/feature/2026-09-20-bottom-short-drama-tab.md

/// Index of 短剧 inside [HomeNotifier.tabs].
final dramaTabIndex = HomeNotifier.tabs.indexOf('短剧');

/// The bottom navigation's 短剧 destination.
///
/// It is a second instance of the same notifier rather than a category of
/// [homeProvider]: two tabs watching one provider would move together, so
/// switching the home page to 听书 would replace the 短剧 tab's feed as well.
final dramaProvider = NotifierProvider<HomeNotifier, HomeState>(
  () => HomeNotifier(initialTabIndex: dramaTabIndex, usesLocalTabs: true),
);
