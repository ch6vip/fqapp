import '../services/desktop_platform.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/home_cell.dart';
import '../models/media_item.dart';
import '../models/search_discovery.dart';
import '../services/api_client.dart';
import '../services/book_open_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
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
import 'category_page.dart';
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

  /// The block pipeline's content slivers (rank strip, card stream grid),
  /// given the same reuse contract as [_gridSliver].
  ///
  /// Without this cache, every state publish during pagination — `isLoadMore`
  /// turning on and back off — rebuilt the whole block list with fresh grid
  /// slivers and child delegates, and `SliverChildBuilderDelegate
  /// .shouldRebuild` is always true, so every mounted card rebuilt twice per
  /// page load. `cellsForView()` mints a new list whenever a page appends, so
  /// the identity check below is also exactly the invalidation signal.
  List<Widget>? _blocksBody;
  List<HomeCell>? _blocksCells;
  double? _blocksWidth;
  double? _blocksTitleScale;
  double? _blocksMetaScale;

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
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;

    return Scaffold(
      backgroundColor: palette.canvas,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWindowsDesktop ? 1440 : 840),
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
    final body = _blockBodySlivers(state, gridWidth);
    if (body == null) return null;

    final slivers = <Widget>[...body];
    // 官方流尾（aes.xml/u4，type 199）三态文案；错误但页面已有内容时给
    // 重试（loadMore 失败只把 hasMore 置 false，items 还在）。
    if (state.isLoadMore) {
      slivers.add(
        SliverToBoxAdapter(
          child: HomeStreamFooter.loading(onRetry: _maybeLoadMore),
        ),
      );
    } else if (state.error != null && state.items.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: HomeStreamFooter.retry(onRetry: _maybeLoadMore),
        ),
      );
    } else if (!state.hasMore) {
      slivers.add(const SliverToBoxAdapter(child: HomeStreamFooter.done()));
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 84)));
    return slivers;
  }

  /// The block pipeline's content slivers, reused verbatim while they still
  /// describe the same cells, width and text scale.
  ///
  /// The stream footer and trailing spacer stay out of the cache: they follow
  /// `isLoadMore` / `error` / `hasMore`, which flip on every pagination cycle —
  /// exactly the rebuilds the cache exists to short-circuit.
  List<Widget>? _blockBodySlivers(HomeState state, double gridWidth) {
    // 每个书城分类都渲染自己那份 `cell_data`（官方 `m0` 对 `tab_type` 一视
    // 同仁地建区块），所以这里不再只放行「推荐」。没带区块的分类照旧落到
    // 下面的旧管线，不会被空掉。
    final cells = state.cells;
    if (cells.isEmpty) return null;
    registerDefaultHomeCells(
      onOpenRankBoard: _openRanks,
      loadBoard: _loadRankPreview,
    );

    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(14);
    final metaScale = scaler.scale(12);
    final cached = _blocksBody;
    if (cached != null &&
        identical(_blocksCells, cells) &&
        _blocksWidth == gridWidth &&
        _blocksTitleScale == titleScale &&
        _blocksMetaScale == metaScale) {
      return cached;
    }
    _blocksCells = cells;
    _blocksWidth = gridWidth;
    _blocksTitleScale = titleScale;
    _blocksMetaScale = metaScale;

    final slivers = <Widget>[];
    var rendered = false;
    for (final cell in cells) {
      // 只有真拿到 widget 才算处理过。handles() 为真但 build() 返回 null 时
      // 要落到下面的 grid 分支，否则这个块会被静默跳过——首页曾因此只显示
      // 排行榜、整段「猜你喜欢」消失。
      final custom = HomeCellRenderers.handles(cell.showType)
          ? HomeCellRenderers.build(context, cell, onOpen: _openItem)
          : null;
      if (custom != null) {
        slivers.add(SliverToBoxAdapter(child: custom));
        rendered = true;
        continue;
      }
      if (isHomeGridBlock(cell)) {
        // 官方的卡片流不装在白色区块卡里：卡片直接铺在 #F6F6F6 画布上，
        // 外边距 12dp、列间距 8dp、行距 8dp（源码级：DoubleRowMarginConfig
        // 默认 8/12 + ta5/j decoration + k1:1247 容器 padding），流也没有
        // 自己的标题和「更多书籍信息」条。顶距 0——385 强制隐藏标题/筛选
        // 时 feed 侧 top inset 就是 0（k1.java h3() → i(0)）。
        final entries = homeCellEntries(cell);
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            // 交错网格（官方 StaggeredFeedLayout）：无摘要/无标签的卡更短，
            // 不再按最坏情况预留统一格高。
            sliver: homeBookMasonry(
              context,
              childCount: entries.length,
              itemBuilder: (context, index) {
                final item = entries[index];
                // 挂 key：续播裁剪（snapshot sublist 丢前段卡）会让所有下标
                // 移位，没有 key 时整屏卡片按位置错位重建。
                return HomeBookCard(
                  key: ValueKey('${item.kind}:${item.id}'),
                  item: item,
                  onTap: () => _openItem(item),
                );
              },
            ),
          ),
        );
        rendered = true;
      }
    }
    if (!rendered) return null;
    return _blocksBody = slivers;
  }

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
