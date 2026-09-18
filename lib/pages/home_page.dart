import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../widgets/home/ambient_backdrop.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_spotlight.dart';
import '../widgets/home/home_tab_bar.dart';
import 'detail_page.dart';
import 'rank_page.dart';
import 'search_page.dart';
import 'home_provider.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const _captions = [
    '换个故事，换一种心情',
    '翻开之后，就舍不得合上',
    '好戏开场，下一集更精彩',
    '画中的故事，正在上演',
    '每一格，都藏着一个新世界',
    '让好故事，陪你走过日常',
  ];

  static const _gridPadding = 20.0;

  final ScrollController _scroll = ScrollController();
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
    _scroll.dispose();
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
    final kind = HomeNotifier.tabKinds[homeCategories[state.tabIndex].label];
    return state.items.where((item) => item.kind == kind).toList();
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
              constraints: const BoxConstraints(maxWidth: 840),
              child: SafeArea(
                bottom: false,
                child: state.error != null
                    ? _ErrorView(message: state.error!, onRetry: notifier.load)
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
                                  onRanks: _openRanks,
                                  onRefresh: notifier.load,
                                  refreshing: state.isLoading,
                                ),
                              ),
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: HomeTabBarDelegate(
                                  selectedIndex: state.tabIndex,
                                  onSelect: notifier.selectTab,
                                  extent: 60 + (textScale - 1).clamp(0, 2) * 24,
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

  List<Widget> _contentSlivers(HomeState state, double gridWidth) {
    final items = _visibleItems(state);
    if (items.isEmpty) {
      if (state.isLoading || state.hasMore) {
        if (!state.isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
        }
        return const [SliverToBoxAdapter(child: _LoadingView())];
      }
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyView(onRefresh: ref.read(homeProvider.notifier).load),
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
      if (rest.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: HomeSectionHeader(
            title: state.tabIndex == 0
                ? '发现更多好故事'
                : '值得一看的${homeCategories[state.tabIndex].label}',
            subtitle: _captions[state.tabIndex],
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
        const SliverToBoxAdapter(child: _EndOfFeed())
      else
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
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

  void _openItem(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      height: 270,
      margin: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(height: 18),
          Text('正在寻找好故事', style: TextStyle(fontSize: 13, color: palette.muted)),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final Future<void> Function() onRefresh;

  const _EmptyView({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: palette.soft,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.compass,
              size: 32,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '暂无内容',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '换个分类，或刷新发现新故事',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(LucideIcons.rotate_ccw, size: 16),
            label: const Text('刷新推荐'),
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.accentText,
            ),
          ),
        ],
      ),
    );
  }
}

class _EndOfFeed extends StatelessWidget {
  const _EndOfFeed();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Row(
        children: [
          Expanded(child: Divider(color: palette.line)),
          Flexible(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                '好故事，未完待续',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: palette.muted),
              ),
            ),
          ),
          Expanded(child: Divider(color: palette.line)),
        ],
      ),
    );
  }
}

/// Long upstream messages stay scrollable all the way to the retry action.
class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              LucideIcons.cloud_off,
              size: 30,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '故事还在路上',
            style: TextStyle(
              fontSize: 30,
              height: 1.2,
              fontWeight: FontWeight.w800,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '暂时无法加载推荐，稍后再试一次。',
            style: TextStyle(color: palette.muted, fontSize: 14, height: 1.6),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              message,
              style: TextStyle(fontSize: 12, height: 1.6, color: palette.muted),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(LucideIcons.rotate_ccw, size: 16),
            label: const Text('重试'),
            style: FilledButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: HomePalette.accentStrong,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
