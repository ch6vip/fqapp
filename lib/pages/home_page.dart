import '../services/desktop_platform.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/home_cell.dart';
import '../models/media_item.dart';
import '../models/search_discovery.dart';
import '../services/api_client.dart';
import '../services/app_links.dart';
import '../services/book_open_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
import '../widgets/home/ambient_backdrop.dart';
import '../widgets/home/home_cell_blocks.dart';
import '../widgets/home/home_cell_renderers.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_skeleton.dart';
import '../widgets/home/home_resume_card.dart';
import '../widgets/home/home_spotlight.dart';
import '../widgets/home/home_tab_bar.dart';
import 'detail_page.dart';
import 'cached_book_reader.dart';
import 'rank_page.dart';
import 'search_page.dart';
import 'home_provider.dart';

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
  /// 旧编辑式布局的副标题（已不再用于首屏：官方书城区块自带 `bqe.xml`
  /// 头部，没有这种一句文案）。保留是因为 fallback 网格仍会用到。
  static const _captions = [
    '换个故事，换一种心情',
    '翻开之后，就舍不得合上',
    '好戏开场，下一集更精彩',
    '画中的故事，正在上演',
    '每一格，都藏着一个新世界',
    '让好故事，陪你走过日常',
  ];

  static const _gridPadding = 20.0;

  late final ScrollController _scroll =
      widget.scrollController ?? ScrollController();
  bool get _ownsScroll => widget.scrollController == null;
  Timer? _loadMoreTimer;
  bool _visible = false;

  /// Item keys whose entrance animation already played. A sliver disposes the
  /// children that leave its cache extent, so without this each scroll back up
  /// the feed replays a fade layer for every card it re-mounts.
  final _entered = <String>{};

  /// The card grid, reused while it still describes the same feed.
  Widget? _gridSliver;
  List<MediaItem>? _gridItems;
  int? _gridTabIndex;
  double? _gridWidth;
  double? _gridTitleScale;
  double? _gridMetaScale;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(homeProvider.notifier).load();
    });
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

  List<MediaItem> _visibleItems(HomeState state) {
    if (state.tabIndex == 0) return state.items;
    final kind = ref
        .read(homeProvider.notifier)
        .identityOf(state.tabIndex)
        .kind;
    return state.items.where((item) => item.kind == kind).toList();
  }

  /// 顶栏分类：服务端下发了就用服务端的，否则退回本地兜底表。
  ///
  /// 官方书城的顶栏由 `data.tab_item` 决定（名字取 `title`、身份取
  /// `tab_type`），本地写死的 6 个跨媒介分类既缺「经典/知识/短篇/新书/
  /// 商城」，又多一个服务端没有的「漫剧」，所以优先用服务端的。
  List<HomeCategory> _categoriesOf(HomeState state) {
    if (state.tabs.isEmpty) return homeCategories;
    return [
      for (final tab in state.tabs) HomeCategory(tab.title, Icons.circle),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    final notifier = ref.read(homeProvider.notifier);
    final palette = HomePalette.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;

    return Scaffold(
      backgroundColor: palette.canvas,
      body: Stack(
        children: [
          Positioned.fill(child: AmbientBackdrop(scroll: _scroll)),
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isWindowsDesktop ? 1440 : 840,
              ),
              child: SafeArea(
                bottom: false,
                child: state.error != null && state.items.isEmpty
                    ? HomeFeedError(
                        headline: '故事还在路上',
                        message: '暂时无法加载推荐，稍后再试一次。',
                        detail: state.error!,
                        onRetry: notifier.load,
                      )
                    : RefreshIndicator(
                        color: HomePalette.accent,
                        backgroundColor: palette.surface,
                        onRefresh: notifier.load,
                        // The grid used to measure itself from inside a sliver
                        // (SliverLayoutBuilder). A sliver's constraints carry
                        // the scroll offset, so they differ on every scroll
                        // frame -- which re-ran the builder, handed the sliver
                        // a fresh SliverChildBuilderDelegate, and rebuilt every
                        // visible card for the whole duration of the scroll.
                        // Measuring once here keeps the grid out of the scroll
                        // path completely.
                        child: LayoutBuilder(
                          builder: (context, constraints) => CustomScrollView(
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
                                  categories: _categoriesOf(state),
                                  extent:
                                      HomeTabBarDelegate.barHeight +
                                      HomeTabBarDelegate.bottomPadding +
                                      (textScale - 1).clamp(0, 2) * 16,
                                  dark: palette.dark,
                                ),
                              ),
                              ..._contentSlivers(
                                state,
                                constraints.maxWidth - _gridPadding * 2,
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders the page as upstream blocks, or null to keep the flat grid.
  ///
  /// Only the "全部" tab carries blocks (`tab_type=2`), and only when at least
  /// one block type has a widget. Returning null leaves the previous pipeline —
  /// and therefore the previous look — completely untouched.
  ///
  /// This replaces the cross-media interleave that used to mix recommendations
  /// with drama/comic/audio search results: the official bookstore tab shows
  /// its own blocks and nothing else, so those other sources stay in their own
  /// tabs.
  List<Widget>? _blockSlivers(HomeState state, double gridWidth) {
    // 每个书城分类都渲染自己那份 `cell_data`（官方 `m0` 对 `tab_type` 一视
    // 同仁地建区块），所以这里不再只放行「推荐」。没带区块的分类照旧落到
    // 下面的旧管线，不会被空掉。
    final cells = state.cells;
    if (cells.isEmpty) return null;
    registerDefaultHomeCells(
      onOpenRankBoard: _openRanks,
      loadBoard: _loadRankPreview,
    );

    final slivers = <Widget>[];
    var rendered = false;
    for (final cell in cells) {
      // 只有真拿到 widget 才算处理过。handles() 为真但 build() 返回 null 时
      // 要落到下面的 grid 分支，否则这个块会被静默跳过——首页曾因此只显示
      // 排行榜、整段「猜你喜欢」消失。
      final custom = HomeCellRenderers.handles(cell.showType)
          ? HomeCellRenderers.build(
              context,
              cell,
              fallback: () => _gridFallbackFor(cell, gridWidth),
              onOpen: _openItem,
            )
          : null;
      if (custom != null) {
        slivers.add(SliverToBoxAdapter(child: custom));
        rendered = true;
        continue;
      }
      if (isHomeGridBlock(cell)) {
        // A white rounded block card cannot wrap a sliver list, so grid blocks
        // render as a box widget inside `HomeBlockCard` instead of a sliver.
        slivers.add(
          SliverToBoxAdapter(
            child: buildCardSection(
              context,
              cell,
              onOpen: _openItem,
              gridWidth: gridWidth,
              onMore: () => _openCellMore(cell),
            ),
          ),
        );
        rendered = true;
      }
    }
    if (!rendered) return null;

    if (state.isLoadMore) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: HomePalette.accent,
                ),
              ),
            ),
          ),
        ),
      );
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 84)));
    return slivers;
  }

  /// Generic card grid for a block whose type has no widget.
  Widget _gridFallbackFor(HomeCell cell, double gridWidth) =>
      buildCardSection(context, cell, onOpen: _openItem, gridWidth: gridWidth);

  List<Widget> _contentSlivers(HomeState state, double gridWidth) {
    final blocks = _blockSlivers(state, gridWidth);
    if (blocks != null) return blocks;
    final items = _visibleItems(state);
    if (items.isEmpty) {
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
            onRefresh: ref.read(homeProvider.notifier).load,
          ),
        ),
      ];
    }

    final featured = items.take(3).toList(growable: false);
    final rest = items.skip(featured.length).toList(growable: false);
    // The next page may be needed before any grid card has been built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });

    return [
      SliverToBoxAdapter(
        child: HomeEntrance(
          child: HomeSpotlight(
            key: ValueKey('spotlight_${state.tabIndex}'),
            items: featured,
            onOpen: _openItem,
          ),
        ),
      ),
      if (state.tabIndex == 0)
        SliverToBoxAdapter(child: HomeResumeCard(onOpen: _resumeItem)),
      if (rest.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: HomeSectionHeader(
            title: '值得一看',
            subtitle: _captions[state.tabIndex % _captions.length],
          ),
        ),
        _gridSliverFor(state, rest, gridWidth),
      ],
      if (state.isLoadMore)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: HomePalette.accent,
                ),
              ),
            ),
          ),
        )
      else if (!state.hasMore)
        const SliverToBoxAdapter(child: HomeEndOfFeed(message: '好故事，未完待续'))
      else
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      const SliverToBoxAdapter(child: SizedBox(height: 84)),
    ];
  }

  /// The card grid, reused verbatim while it still describes the same feed.
  ///
  /// Widgets are immutable descriptions, so handing the framework back the
  /// identical instance lets it skip the visible cards when a rebuild only
  /// carries a new loading flag. Column count, cell height and coverWidth are
  /// baked into that instance, so the cache key also includes the text scales
  /// those values were computed from. Theme colors and device pixel ratio still
  /// reach the cards through inherited widgets.
  ///
  /// Note: 网格曾在 sliver 内部量宽度，导致每帧重建全部可见卡片；字号变化
  /// 必须使这份缓存失效 — 见
  /// .agents/notes/implemented/bug-fix/2026-09-18-home-scroll-cost.md
  Widget _gridSliverFor(
    HomeState state,
    List<MediaItem> rest,
    double gridWidth,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(14);
    final metaScale = scaler.scale(11);
    final cached = _gridSliver;
    if (cached != null &&
        identical(_gridItems, state.items) &&
        _gridTabIndex == state.tabIndex &&
        _gridWidth == gridWidth &&
        _gridTitleScale == titleScale &&
        _gridMetaScale == metaScale) {
      return cached;
    }
    _gridItems = state.items;
    _gridTabIndex = state.tabIndex;
    _gridWidth = gridWidth;
    _gridTitleScale = titleScale;
    _gridMetaScale = metaScale;
    final cardWidth = homeCardWidth(context, gridWidth);
    return _gridSliver = SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: _gridPadding),
      sliver: SliverGrid(
        gridDelegate: homeGridDelegate(context, gridWidth),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = rest[index];
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
        }, childCount: rest.length),
      ),
    );
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  /// 官方搜索行右上角的「分类」入口（`alx.xml` `i_y`）。官方点它走
  /// `turnToCategoryTab` → `//category` 路由，打开的是完整的分类页；那个
  /// 页面还没有建，先按官方位置摆入口，点击时说明状态。
  void _openCategory() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('分类页还在接入中，敬请期待')));
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
  /// put. Only the first page is needed — the preview shows four rows.
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

  /// Opens a block's 「更多书籍信息」 target (`jd.xml` node `anr`).
  ///
  /// Upstream binds the strip to the cell's own `url`; when the cell carries
  /// none the tap falls through to the generic more-books list.
  void _openCellMore(HomeCell cell) {
    final url = cell.url;
    if (url.isNotEmpty) {
      unawaited(openAppLink(context, url));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RankPage()),
    );
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
