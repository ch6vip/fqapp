import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../widgets/home/ambient_backdrop.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_filter.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_resume_card.dart';
import '../widgets/home/home_spotlight.dart';
import '../widgets/home/home_tab_bar.dart';
import 'detail_page.dart';
import 'home_provider.dart';
import 'rank_page.dart';
import 'search_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  static final _scrollToTopSignal = ValueNotifier<int>(0);

  /// Smoothly scroll the home feed back to the top.
  static void scrollToTop() {
    _scrollToTopSignal.value++;
  }

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  Timer? _loadMoreTimer;
  bool _visible = false;

  /// Cards whose one-shot entrance already played. Slivers dispose children
  /// outside the cache extent, so replaying the animation after a scroll would
  /// waste a layer for every remounted card.
  final _entered = <String>{};

  /// Reuse the grid sliver while the feed, filter and geometry are unchanged.
  Widget? _gridSliver;
  List<MediaItem>? _gridItems;
  int? _gridTabIndex;
  HomeFeedFilter? _gridFilter;
  double? _gridWidth;
  double? _gridTitleScale;
  double? _gridMetaScale;
  bool? _gridEink;

  final Map<int, HomeFeedFilter> _tabFilters = {};

  HomeFeedFilter _filterFor(int tabIndex) =>
      _tabFilters[tabIndex] ?? const HomeFeedFilter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HomePage._scrollToTopSignal.addListener(_onScrollToTop);
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
    if (!_visible) {
      _loadMoreTimer?.cancel();
      _loadMoreTimer = null;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HomePage._scrollToTopSignal.removeListener(_onScrollToTop);
    _loadMoreTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    ref.read(homeProvider.notifier).flushPendingSave();
  }

  void _onScrollToTop() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.offset <= 0) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(0);
    } else {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    }
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

  /// Short and empty pages must keep paginating without a user scroll event.
  void _maybeLoadMore() {
    if (!mounted || !_visible || _loadMoreTimer != null) return;
    final state = ref.read(homeProvider);
    if (state.isLoading ||
        state.isLoadMore ||
        state.loadMoreFailed ||
        !state.hasMore) {
      return;
    }
    // A restrictive filter can leave the loaded page with no visible result.
    // Do not walk the upstream cursor automatically; expose a manual button
    // instead, matching the search filter's continuation contract.
    if (_filterFor(state.tabIndex).isActive) return;
    _loadMoreTimer = Timer(const Duration(milliseconds: 500), () {
      _loadMoreTimer = null;
      if (mounted) _onScroll();
    });
    ref.read(homeProvider.notifier).loadMore();
  }

  void _manualLoadMore() {
    unawaited(ref.read(homeProvider.notifier).loadMore(manual: true));
  }

  List<MediaItem> _visibleItems(HomeState state) {
    if (state.tabIndex == 0) return state.items;
    final kind = HomeNotifier.tabKinds[homeCategories[state.tabIndex].label];
    return state.items.where((item) => item.kind == kind).toList();
  }

  Future<void> _manualRefresh() =>
      ref.read(homeProvider.notifier).load(manualRefresh: true);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    final notifier = ref.read(homeProvider.notifier);
    final palette = HomePalette.of(context);

    return Scaffold(
      backgroundColor: palette.canvas,
      body: Stack(
        children: [
          Positioned.fill(child: AmbientBackdrop(scroll: _scroll)),
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: SafeArea(
                bottom: false,
                child: state.error != null && state.items.isEmpty
                    ? HomeFeedError(
                        headline: '故事暂时走丢了',
                        message: '检查网络后再试一次。',
                        detail: state.error!,
                        onRetry: _manualRefresh,
                      )
                    : RefreshIndicator(
                        color: HomePalette.accent,
                        backgroundColor: palette.surface,
                        onRefresh: _manualRefresh,
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
                                  onRanks: _openRanks,
                                  issue: _issueLabel(),
                                ),
                              ),
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: HomeTabBarDelegate(
                                  selectedIndex: state.tabIndex,
                                  onSelect: notifier.selectTab,
                                  dark: palette.dark,
                                  eink: palette.eink,
                                ),
                              ),
                              ..._contentSlivers(state, constraints.maxWidth),
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

  List<Widget> _contentSlivers(HomeState state, double viewportWidth) {
    final palette = HomePalette.of(context);
    final items = _visibleItems(state);
    final currentFilter = _filterFor(state.tabIndex);
    final category = homeCategories[state.tabIndex].label;
    if (items.isEmpty) {
      if (state.isLoading) {
        return const [
          SliverToBoxAdapter(child: HomeFeedLoading(message: '正在挑选好故事')),
        ];
      }
      if (currentFilter.isActive) {
        return [
          ..._filterHeadingSlivers(state, currentFilter, category),
          _filteredEmptySliver(state, palette),
        ];
      }
      if (state.hasMore) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
        return const [
          SliverToBoxAdapter(child: HomeFeedLoading(message: '正在挑选好故事')),
        ];
      }
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: HomeFeedEmpty(
            title: '这里还很安静',
            message: '换个分类，或刷新看看。',
            actionLabel: '刷新',
            onRefresh: _manualRefresh,
          ),
        ),
      ];
    }

    final featured = items.take(3).toList(growable: false);
    final rest = items.skip(featured.length).toList(growable: false);
    final filteredRest = currentFilter.apply(rest);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });

    return [
      SliverToBoxAdapter(
        child: HomeEntrance(
          child: HomeSpotlight(
            key: ValueKey('spotlight_${state.tabIndex}'),
            title: state.tabIndex == 0 ? '今日焦点' : '精选$category',
            items: featured,
            onOpen: _openItem,
          ),
        ),
      ),
      if (state.tabIndex == 0)
        SliverToBoxAdapter(
          child: HomeEntrance(child: HomeResumeCard(onOpen: _openItem)),
        ),
      if (rest.isNotEmpty || currentFilter.isActive) ...[
        ..._filterHeadingSlivers(state, currentFilter, category),
        if (filteredRest.isEmpty)
          _filteredEmptySliver(state, palette)
        else
          _gridSliverFor(state, filteredRest, currentFilter, viewportWidth),
        if (filteredRest.isNotEmpty && currentFilter.isActive && state.hasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: TextButton(
                  key: const Key('home_filter_load_more'),
                  onPressed: state.isLoadMore ? null : _manualLoadMore,
                  child: Text(
                    state.isLoadMore
                        ? '正在加载…'
                        : state.loadMoreFailed
                        ? '加载失败，点击重试'
                        : '加载更多匹配内容',
                  ),
                ),
              ),
            ),
          ),
      ],
      if (!currentFilter.isActive && state.loadMoreFailed)
        SliverToBoxAdapter(
          child: Center(
            child: TextButton(
              key: const Key('home_load_more_retry'),
              onPressed: _manualLoadMore,
              child: const Text('加载更多失败，点击重试'),
            ),
          ),
        ),
      if (state.isLoadMore && !currentFilter.isActive)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.accentText,
                ),
              ),
            ),
          ),
        )
      else if (!state.hasMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                '今天的好故事就看到这里',
                style: TextStyle(color: palette.tertiary, fontSize: 11.5),
              ),
            ),
          ),
        )
      else
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      const SliverToBoxAdapter(child: SizedBox(height: 100)),
    ];
  }

  List<Widget> _filterHeadingSlivers(
    HomeState state,
    HomeFeedFilter currentFilter,
    String category,
  ) {
    final scopeLabel = state.tabIndex == 0 ? '为你推荐' : '更多$category';
    return [
      SliverToBoxAdapter(
        child: HomeSectionHeader(
          title: scopeLabel,
          trailing: HomeFilterButton(
            active: currentFilter.isActive,
            onTap: () => _openFilter(state.tabIndex, currentFilter),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: HomeFilterSummary(
          filter: currentFilter,
          scopeLabel: scopeLabel,
          onClear: () => setState(
            () => _tabFilters[state.tabIndex] = const HomeFeedFilter(),
          ),
        ),
      ),
    ];
  }

  Widget _filteredEmptySliver(HomeState state, HomePalette palette) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HomeSpace.gutter,
          8,
          HomeSpace.gutter,
          36,
        ),
        child: Column(
          children: [
            Text(
              '没有符合条件的内容',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '放宽一点条件，好故事会回来的。',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('home_filter_clear'),
              onPressed: () => setState(
                () => _tabFilters[state.tabIndex] = const HomeFeedFilter(),
              ),
              child: const Text('清除筛选'),
            ),
            if (state.hasMore)
              TextButton(
                key: const Key('home_filter_load_more'),
                onPressed: state.isLoadMore ? null : _manualLoadMore,
                child: Text(
                  state.isLoadMore
                      ? '正在加载…'
                      : state.loadMoreFailed
                      ? '加载失败，点击重试'
                      : '继续加载',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFilter(int tabIndex, HomeFeedFilter current) async {
    final scopeLabel = tabIndex == 0
        ? '为你推荐'
        : '更多${homeCategories[tabIndex].label}';
    await showHomeFilterSheet(
      context,
      current: current,
      scopeLabel: scopeLabel,
      onApply: (filter) {
        if (mounted) {
          setState(() => _tabFilters[tabIndex] = filter);
        }
      },
    );
  }

  /// Grid sliver measured once outside the scroll path.
  Widget _gridSliverFor(
    HomeState state,
    List<MediaItem> rest,
    HomeFeedFilter currentFilter,
    double viewportWidth,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final palette = HomePalette.of(context);
    final titleScale = scaler.scale(15);
    final metaScale = scaler.scale(12);
    final cached = _gridSliver;

    if (cached != null &&
        identical(_gridItems, state.items) &&
        _gridTabIndex == state.tabIndex &&
        _gridFilter == currentFilter &&
        _gridWidth == viewportWidth &&
        _gridTitleScale == titleScale &&
        _gridMetaScale == metaScale &&
        _gridEink == palette.eink) {
      return cached;
    }

    _gridItems = state.items;
    _gridTabIndex = state.tabIndex;
    _gridFilter = currentFilter;
    _gridWidth = viewportWidth;
    _gridTitleScale = titleScale;
    _gridMetaScale = metaScale;
    _gridEink = palette.eink;

    // The grid delegate receives the content width, not the viewport width, so
    // its cell size is exactly the same value passed to the cover decoder.
    final contentWidth = viewportWidth - HomeSpace.gutter * 2;
    final cardWidth = homeCardWidth(context, contentWidth);

    return _gridSliver = SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: HomeSpace.gutter),
      sliver: SliverGrid(
        gridDelegate: homeGridDelegate(context, contentWidth),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = rest[index];
          final key = '${item.kind}:${item.id}';
          return HomeEntrance(
            key: ValueKey(key),
            index: index,
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

  /// `9月15日 · 第 258 期`, using tabular figures in the hero so the header does
  /// not jitter when the day changes.
  String _issueLabel() {
    final now = DateTime.now();
    final dayOfYear = now.difference(DateTime(now.year)).inDays + 1;
    return '${now.month}月${now.day}日 · 第 $dayOfYear 期';
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  /// Rank ids only exist inside the novel homepage response the app already
  /// fetches, so this opens the existing in-app rank surface.
  void _openRanks() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RankPage()),
    );
  }

  void _openItem(MediaItem item) {
    openBookDetail(context, item);
  }
}
