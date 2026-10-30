import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/home_cell.dart';
import '../models/media_item.dart';
import '../models/search_discovery.dart';
import '../services/api_client.dart';
import '../services/app_log.dart';
import '../services/book_open_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/desktop_platform.dart';
import '../services/home_continue_preferences.dart';
import '../services/home_page_affinity.dart';
import '../services/library_store.dart';
import '../widgets/home/home_cell_blocks.dart';
import '../widgets/home/home_cell_renderers.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_reading_row.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/home/home_skeleton.dart';
import '../widgets/home/home_tab_bar.dart';
import '../widgets/tab_swipe_area.dart';
import 'cached_book_reader.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'rank_page.dart';
import 'search_page.dart';
import 'home_provider.dart';

/// 书城首页：以书为主的书架。
///
/// 版式（用户 2026-10-26 起的设计方向）：
///
/// ```
/// 搜索行
/// 分类条（吸顶）
/// 继续阅读          ← 只有「推荐」且有阅读史：一行字，无封面无卡面
/// 排行榜            ← 上游 RankCellV3，横滑大封面 + 名次
/// 为你推荐 / 分类名  ← 统一的书籍网格
/// 流尾 / 加载中 / 重试
/// ```
///
/// 「推荐」只画书：上游的卡片流是混排（短剧、漫剧、听书都夹在里面），这里按
/// 当前分类的种类过滤，其余媒介留在各自分类里。上游的其余区块仍然按
/// `show_type` 分发（见 [HomeCellRenderers]），没登记的类型不会让页面变空。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    super.key,
    this.cacheStore,
    this.readerStore,
    this.scrollController,
    this.cueLoader,
  });

  final ChapterCache? cacheStore;
  final ReaderStore? readerStore;

  /// 首页 feed 的滚动控制器，由壳层持有。
  ///
  /// 官方「重复点击底部书城 tab 回顶部」发生在底部栏
  /// （`onBottomTabRepeatClick` → `scrollToPosition(0)`），不在首页内部，
  /// 所以控制器要能被外面拿到。为 null 时首页自建并自行释放，测试与独立
  /// 使用不受影响。
  final ScrollController? scrollController;

  /// 搜索框热搜词来源，由壳层注入（生产接 `ApiClient.searchCue`）。
  ///
  /// 注入而不是页内直连，与 [SearchPage] 的 `hotSearchLoader` 同一规矩：
  /// 页面测试不落网络（ApiClient 的超时是 20s Timer，挂进测试必炸）。
  final Future<SearchCue> Function()? cueLoader;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late final ScrollController _scroll =
      widget.scrollController ?? ScrollController();
  bool get _ownsScroll => widget.scrollController == null;
  Timer? _loadMoreTimer;
  bool _visible = false;

  /// Item keys whose entrance animation already played. A sliver disposes the
  /// children that leave its cache extent, so without this each scroll back up
  /// the feed replays a fade layer for every card it re-mounts.
  final _entered = <String>{};

  /// The fallback grid, reused while it still describes the same feed.
  Widget? _gridSliver;
  List<MediaItem>? _gridItems;
  int? _gridTabIndex;
  double? _gridWidth;
  double? _gridTitleScale;
  double? _gridMetaScale;

  /// The block pipeline's content slivers, given the same reuse contract.
  ///
  /// Without this cache, every state publish during pagination — `isLoadMore`
  /// turning on and back off — rebuilt the whole block list with fresh grid
  /// slivers and child delegates, and `SliverChildBuilderDelegate
  /// .shouldRebuild` is always true, so every mounted card rebuilt twice per
  /// page load. `cellsForView()` mints a new list whenever a page appends, so
  /// the identity check below is also exactly the invalidation signal.
  List<Widget>? _blocksBody;
  List<HomeCell>? _blocksCells;
  int? _blocksTabIndex;
  String? _blocksLeadKey;
  double? _blocksWidth;
  double? _blocksTitleScale;
  double? _blocksMetaScale;

  /// Last logged render shape; keeps the diagnostic to one line per change.
  String? _loggedShape;

  /// 阅读史存在 Hive 里，不经过 provider；「继续阅读」那一行要跟着阅读
  /// 进度换书，所以页面自己订阅盒子的变更。
  Listenable? _historyListenable;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final store = LibraryStore.instance;
    if (store.isInitialized) {
      _historyListenable = store.historyListenable
        ..addListener(_onLocalDataChanged);
    }
    // 关闭「继续阅读」是个持久化开关，加载完成后要重画这一行。
    HomeContinuePreferences.instance.dismissedId.addListener(_onLocalDataChanged);
    unawaited(HomeContinuePreferences.instance.load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(homeProvider.notifier).load();
    });
  }

  void _onLocalDataChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible == visible) return;
    _visible = visible;
    // Muting tickers does not stop this page's pagination timer.
    // Note: .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md
    if (!_visible) {
      _loadMoreTimer?.cancel();
      _loadMoreTimer = null;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  @override
  void dispose() {
    _loadMoreTimer?.cancel();
    _historyListenable?.removeListener(_onLocalDataChanged);
    HomeContinuePreferences.instance.dismissedId.removeListener(
      _onLocalDataChanged,
    );
    // 外部传入的控制器归壳层所有，这里不能释放。
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_visible) return;
    if (!_scroll.hasClients) {
      final state = ref.read(homeProvider);
      if (state.error == null && _visibleItems(state).isEmpty) _maybeLoadMore();
      return;
    }
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 600) _maybeLoadMore();
  }

  /// Short and empty pages must continue even without a user scroll event.
  void _maybeLoadMore() {
    if (!mounted || !_visible || _loadMoreTimer != null) return;
    final state = ref.read(homeProvider);
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    _loadMoreTimer = Timer(const Duration(milliseconds: 500), () {
      _loadMoreTimer = null;
      if (mounted) _onScroll();
    });
    ref.read(homeProvider.notifier).loadMore();
  }

  /// 下拉与冷启动错误里的「重试」都走手动刷新：手动刷新会跳过续接快照，
  /// 用服务端的第一页整体替换列表（官方 `SaasClientReqType.Refresh`）。
  Future<void> _refresh() =>
      ref.read(homeProvider.notifier).load(manualRefresh: true);

  /// 追加失败后 footer 的重试：`loadMore` 失败会把 `hasMore` 置 false，必须
  /// 让 notifier 先把游标恢复，否则重试会被「已经没有下一页」挡住。
  Future<void> _retryLoadMore() =>
      ref.read(homeProvider.notifier).retryLoadMore();

  /// 当前分类的种类：「推荐」与「全部」都会落到 `book`。
  String _kindOf(HomeState state) =>
      ref.read(homeProvider.notifier).identityOf(state.tabIndex).kind;

  List<MediaItem> _visibleItems(HomeState state) {
    final kind = _kindOf(state);
    return [
      for (final item in state.items)
        if (item.kind == kind) item,
    ];
  }

  /// 当前分类的区块，或空表示这份 `cells` 不属于这里。
  ///
  /// 归属由数据自己声明（[HomeState.cellsTabIndex]），不再靠页面猜：上游曾把
  /// `tab_index` 写死成 0 返回推荐流，于是「听书」里画出了推荐榜。请求侧已经
  /// 修好，这里再兜一道——不属于当前分类的区块一律不画，别把别人的内容
  /// 当成自己这份。
  List<HomeCell> _cellsOfCurrentTab(HomeState state) {
    final cells = state.cells;
    if (cells.isEmpty) return const [];
    final owner = state.cellsTabIndex;
    if (owner == null) return cells;
    return owner == state.tabIndex ? cells : const [];
  }

  /// 顶栏分类：固定用本地六分类（推荐/小说/短剧/漫剧/漫画/听书）。
  ///
  /// 2026-10-24 用户决定回退服务端 11 项方案——服务端表没有「短剧/漫剧」，
  /// 跨媒介入口只能本地给；点击身份由 `homeProvider` 的 `usesLocalTabs`
  /// 本地表驱动，与这里的下标一一对应。
  List<HomeCategory> _categoriesOf(HomeState state) => homeCategories;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    final notifier = ref.read(homeProvider.notifier);
    final palette = HomePalette.of(context);
    final categories = _categoriesOf(state);
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return Scaffold(
      backgroundColor: palette.canvas,
      body: Align(
        alignment: Alignment.topCenter,
        // 阅读宽度：手机/平板压 840（一屏三到五列，再宽眼睛就散）。
        //
        // 桌面不吃固定 1440：2560 的窗口里只占一半多，两侧各空 560dp。
        // 宽度交给窗口后，列数由 homeShelfColumns 按「一格 190dp，钳 6–9 列」
        // 反推（见 `widgets/home/home_shelf.dart`）：默认六列、全屏九列，
        // 窗口再宽只把卡片放大，不会往格子里塞更多小封面。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isWindowsDesktop || MediaQuery.sizeOf(context).width >= 840 ? double.infinity : 840,
          ),
          child: SafeArea(
            bottom: false,
            // 冷启动失败不再整页替换：搜索行与分类条留在原位，错误信息进
            // feed 里滚动，用户换个分类或下拉都能继续用。
            child: RefreshIndicator(
              color: HomePalette.accent,
              backgroundColor: palette.surface,
              onRefresh: _refresh,
              // The grid is measured once here, outside the sliver: a sliver's
              // constraints carry the scroll offset, so measuring inside one
              // re-ran the builder and rebuilt every visible card per frame.
              child: LayoutBuilder(
                builder: (context, constraints) => TabSwipeArea(
                  index: state.tabIndex,
                  count: categories.length,
                  onSelect: notifier.selectTab,
                  child: CustomScrollView(
                    key: const Key('home_feed'),
                    controller: _scroll,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      SliverToBoxAdapter(
                        child: HomeHero(
                          onSearch: _openSearch,
                          onCategory: _openCategory,
                          cueLoader: widget.cueLoader,
                        ),
                      ),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: HomeTabBarDelegate(
                          selectedIndex: state.tabIndex,
                          onSelect: notifier.selectTab,
                          categories: categories,
                          extent:
                              HomeTabBarDelegate.barHeight +
                              HomeTabBarDelegate.bottomPadding +
                              (textScale - 1).clamp(0, 2) * 16,
                          dark: palette.dark,
                          eink: palette.eink,
                          oled: palette.oled,
                        ),
                      ),
                      ..._contentSlivers(
                        state,
                        constraints.maxWidth - homeGutter * 2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _contentSlivers(HomeState state, double gridWidth) {
    if (state.error != null &&
        state.items.isEmpty &&
        _cellsOfCurrentTab(state).isEmpty) {
      return [
        SliverToBoxAdapter(
          child: HomeFeedError(
            headline: '故事还在路上',
            message: '暂时无法加载推荐，稍后再试一次。',
            detail: state.error!,
            onRetry: _refresh,
          ),
        ),
      ];
    }

    final items = _visibleItems(state);
    final now = _readingNow(state);
    final lead = now?.item;
    final blockBody = _blockBodySlivers(
      state,
      gridWidth,
      kind: _kindOf(state),
      lead: lead,
    );
    _logShape(state, blockBody != null);

    // 短页要能自己续上：没有滚动事件时，也让页面在布局后检查一次是否
    // 已经到底（内容不足一屏时 `maxScrollExtent` 为 0）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
    if (blockBody != null) {
      return [
        if (now != null) _continueRow(now),
        ...blockBody,
        _footer(state),
        _bottomSpacer(context),
      ];
    }
    if (items.isNotEmpty) {
      return [
        if (now != null) _continueRow(now),
        ..._fallbackGrid(state, items, gridWidth, lead: lead),
        _footer(state),
        _bottomSpacer(context),
      ];
    }
    if (state.isLoading || state.hasMore) {
      if (!state.isLoading) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
      }
      // `alx.xml` points its `SkeletonLayout` at `cmc`, so a cold first load
      // paints the skeleton rather than a spinner.
      return const [SliverToBoxAdapter(child: HomeSkeleton())];
    }
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: HomeFeedEmpty(
          title: '暂无内容',
          message: '换个分类，或刷新发现新故事',
          actionLabel: '刷新推荐',
          onRefresh: _refresh,
        ),
      ),
    ];
  }

  /// 「继续阅读」显示哪一本：只在推荐页、有阅读史、且这一本没被关掉时出现。
  ReadingNow? _readingNow(HomeState state) {
    if (state.tabIndex != 0) return null;
    final now = latestReadingNow();
    if (now == null) return null;
    return HomeContinuePreferences.instance.isDismissed(now.item) ? null : now;
  }

  Widget _continueRow(ReadingNow now) => SliverToBoxAdapter(
    child: HomeContinueRow(
      now: now,
      onOpen: () => _resumeItem(now.item),
      onDismiss: () => HomeContinuePreferences.instance.dismiss(now.item),
    ),
  );

  void _logShape(HomeState state, bool blocks) {
    // 设备日志：分类页到底画的是区块还是卡片网格、画了多少张。听书出问题时
    // 这一行直接说明它被画成了哪一种版式。
    final shape = blocks
        ? 'blocks tab=${state.tabIndex} '
              'cells=${describeHomeCells(_cellsOfCurrentTab(state))}'
        : 'grid tab=${state.tabIndex} items=${_visibleItems(state).length}';
    if (shape == _loggedShape) return;
    _loggedShape = shape;
    AppLog.d('home', '渲染 $shape');
  }

  /// The block pipeline's content slivers, reused verbatim while they still
  /// describe the same cells, width, text scale and lead book.
  List<Widget>? _blockBodySlivers(
    HomeState state,
    double gridWidth, {
    required String kind,
    required MediaItem? lead,
  }) {
    // 每个书城分类都渲染自己那份 `cell_data`（官方 `m0` 对 `tab_type` 一视
    // 同仁地建区块），所以这里不再只放行「推荐」。没带区块的分类照旧落到
    // 下面的兜底网格，不会被空掉。
    final cells = _cellsOfCurrentTab(state);
    if (cells.isEmpty) return null;
    registerDefaultHomeCells(
      onOpenRankBoard: _openRanks,
      loadBoard: _loadRankPreview,
    );

    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(15);
    final metaScale = scaler.scale(11);
    final leadKey = lead == null ? null : '${lead.kind}:${lead.id}';
    final cached = _blocksBody;
    if (cached != null &&
        identical(_blocksCells, cells) &&
        _blocksTabIndex == state.tabIndex &&
        _blocksLeadKey == leadKey &&
        _blocksWidth == gridWidth &&
        _blocksTitleScale == titleScale &&
        _blocksMetaScale == metaScale) {
      return cached;
    }
    _blocksCells = cells;
    _blocksTabIndex = state.tabIndex;
    _blocksLeadKey = leadKey;
    _blocksWidth = gridWidth;
    _blocksTitleScale = titleScale;
    _blocksMetaScale = metaScale;

    final slivers = <Widget>[];
    final entries = <MediaItem>[];
    final seen = <String>{};
    var rendered = false;
    for (final cell in cells) {
      // 只有真拿到 widget 才算处理过。handles() 为真但 build() 返回 null 时
      // 要落到 card 分支，否则这个块会被静默跳过。
      final custom = HomeCellRenderers.handles(cell.showType)
          ? HomeCellRenderers.build(context, cell, onOpen: _openItem)
          : null;
      if (custom != null) {
        slivers.add(SliverToBoxAdapter(child: custom));
        rendered = true;
        continue;
      }
      if (!isHomeGridBlock(cell)) continue;
      for (final item in homeCellEntries(cell)) {
        // 以书为主：推荐页的卡片流里混着短剧、漫画和听书，这里只留当前
        // 分类的书；其余媒介在自己的分类里出现。
        if (item.kind != kind) continue;
        final key = '${item.kind}:${item.id}';
        // 主视觉已经在上面独占一张卡，网格里不再重复。
        if (key == leadKey || !seen.add(key)) continue;
        entries.add(item);
      }
    }
    if (entries.isNotEmpty) {
      // 多个卡片流合并成一个网格：首页只保留一个「为你推荐」段落，块与块
      // 之间的边界对读书的人没有意义。
      slivers.add(
        SliverToBoxAdapter(child: HomeSectionHeader(title: _gridTitle(state))),
      );
      slivers.add(_gridBody(entries, gridWidth));
      rendered = true;
    }
    if (!rendered) {
      // 这份 `cells` 一个块都没画出来（听书的 337、老后端的未知类型…）：
      // **必须把缓存清掉**。`_blocksCells` 已经在上面改成了这份列表，
      // 若把 `_blocksBody`（上上个分类建的那套 widget）留着，下一次带着
      // **同一份列表实例**的重建就会命中缓存、把上一个分类的排行榜画到
      // 当前分类上——真机上「听书第二次加载变成推荐」就是这么来的。
      _blocksBody = null;
      _blocksCells = null;
      _blocksTabIndex = null;
      _blocksLeadKey = null;
      _blocksWidth = null;
      _blocksTitleScale = null;
      _blocksMetaScale = null;
      return null;
    }
    return _blocksBody = slivers;
  }

  /// 兜底：上游没给区块时，把当前分类的条目排成同一个书架网格。
  List<Widget> _fallbackGrid(
    HomeState state,
    List<MediaItem> items,
    double gridWidth, {
    required MediaItem? lead,
  }) {
    final leadKey = lead == null ? null : '${lead.kind}:${lead.id}';
    final entries = [
      for (final item in items)
        if ('${item.kind}:${item.id}' != leadKey) item,
    ];
    if (entries.isEmpty) return const [];
    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(15);
    final metaScale = scaler.scale(11);
    final cached = _gridSliver;
    if (cached != null &&
        identical(_gridItems, state.items) &&
        _gridTabIndex == state.tabIndex &&
        _gridWidth == gridWidth &&
        _gridTitleScale == titleScale &&
        _gridMetaScale == metaScale) {
      return [
        SliverToBoxAdapter(child: HomeSectionHeader(title: _gridTitle(state))),
        cached,
      ];
    }
    _gridItems = state.items;
    _gridTabIndex = state.tabIndex;
    _gridWidth = gridWidth;
    _gridTitleScale = titleScale;
    _gridMetaScale = metaScale;
    final sliver = _gridBody(entries, gridWidth);
    return [
      SliverToBoxAdapter(child: HomeSectionHeader(title: _gridTitle(state))),
      _gridSliver = sliver,
    ];
  }

  /// One book grid: cover, title, one meta line, nothing else.
  Widget _gridBody(List<MediaItem> entries, double gridWidth) {
    final cardWidth = homeShelfCardWidth(context, gridWidth);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      sliver: SliverGrid(
        gridDelegate: homeShelfDelegate(context, gridWidth),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = entries[index];
          final key = '${item.kind}:${item.id}';
          return HomeEntrance(
            key: ValueKey(key),
            index: index,
            // Only the first appearance of an item animates; see HomeEntrance.
            animate: _entered.add(key),
            child: HomeMediaCard(
              item: item,
              coverWidth: cardWidth,
              onTap: () => _openItem(item),
            ),
          );
        }, childCount: entries.length),
      ),
    );
  }

  String _gridTitle(HomeState state) {
    if (state.tabIndex == 0) return '为你推荐';
    return ref.read(homeProvider.notifier).identityOf(state.tabIndex).name;
  }

  /// 流尾三态：加载中 / 追加失败可重试 / 已到底。
  Widget _footer(HomeState state) {
    if (state.isLoadMore) {
      return SliverToBoxAdapter(
        child: HomeStreamFooter.loading(onRetry: _retryLoadMore),
      );
    }
    if (state.error != null) {
      return SliverToBoxAdapter(
        child: HomeStreamFooter.retry(onRetry: _retryLoadMore),
      );
    }
    if (!state.hasMore) {
      return const SliverToBoxAdapter(child: HomeStreamFooter.done());
    }
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }

  SliverToBoxAdapter _bottomSpacer(BuildContext context) =>
      SliverToBoxAdapter(child: SizedBox(height: homeBottomClearance(context)));

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  /// 官方搜索行右上角的「分类」入口（`alx.xml` `i_y`）。官方点它走
  /// `turnToCategoryTab` → `//category` 路由（`BookCategoryActivity` →
  /// `KmpCategoryFragment`）；这里打开同结构的分类页。
  void _openCategory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CategoryPage()),
    );
  }

  /// The rank board. Its catalogue (and the rank id the entries endpoint needs)
  /// only exist inside the novel homepage response the app already fetches.
  ///
  /// Note: 榜单目录与 rank_id 的来源 — 见
  /// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
  void _openRanks() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RankPage()),
    );
  }

  /// Reloads the homepage rank preview for one board.
  ///
  /// Official flow: `RankMixContentHolder.K7` fetches the picked board through
  /// the same rank endpoint and swaps the preview in place, so the page stays
  /// put. Only the first page is needed — the rail scrolls the rest.
  Future<List<MediaItem>> _loadRankPreview(String rankId, int algo) async {
    final board = await ApiClient.instance.rankBoard(
      rankId: rankId,
      algo: algo,
    );
    return [
      for (final entry in board.entries)
        if (entry.id.isNotEmpty) entry.toMediaItem(),
    ];
  }

  void _openItem(MediaItem item) {
    openBookDetail(context, item);
  }

  Future<void> _resumeItem(MediaItem item) async {
    if (await openRecentBook(
      context,
      item,
      cache: widget.cacheStore,
      readerStore: widget.readerStore,
    )) {
      return;
    }
    if (!mounted) return;
    await openBookDetail(context, item, entry: BookOpenEntry.shelf);
  }
}
