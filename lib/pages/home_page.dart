import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_tab_bar.dart';
import '../widgets/media_card.dart' show mediaGridDelegateFor;
import 'detail_page.dart';
import 'search_page.dart';
import 'home_provider.dart';

/// Home feed, rebuilt as an editorial surface: an oversized typographic hero
/// with a scroll-driven marquee, a pinned frosted category strip, a featured
/// showcase card and a cascading cover grid.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const _tabKinds = {
    '小说': 'book',
    '短剧': 'video',
    '漫画': 'manga',
    '听书': 'audio',
  };

  final ScrollController _scroll = ScrollController();
  // Throttle window for load-more triggers (PiliPlus EasyThrottle style):
  // rapid scrolling near the bottom must not fire back-to-back requests.
  Timer? _loadMoreTimer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(homeProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _loadMoreTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) {
      final state = ref.read(homeProvider);
      if (state.error == null && _visibleItems(state).isEmpty) {
        _maybeLoadMore();
      }
      return;
    }
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      _maybeLoadMore();
    }
  }

  /// Throttled load-more trigger. Shared by the scroll listener and content
  /// builders so empty or short feeds keep paginating without scrolling.
  void _maybeLoadMore() {
    if (!mounted || _loadMoreTimer != null) return;
    final state = ref.read(homeProvider);
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    _loadMoreTimer = Timer(const Duration(milliseconds: 500), () {
      _loadMoreTimer = null;
      // An empty or short page can finish inside the throttle window without
      // a scroll event. Recheck it when the window ends to keep paginating.
      if (mounted) _onScroll();
    });
    ref.read(homeProvider.notifier).loadMore();
  }

  List<MediaItem> _visibleItems(HomeState state) {
    if (state.tabIndex == 0) return state.items;
    final kind = _tabKinds[homeCategories[state.tabIndex].label];
    return state.items.where((item) => item.kind == kind).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    final notifier = ref.read(homeProvider.notifier);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        // A load error replaces the feed entirely so the (potentially long)
        // message stays scrollable down to the retry action.
        child: state.error != null
            ? _ErrorView(message: state.error!, onRetry: notifier.load)
            : RefreshIndicator(
                onRefresh: notifier.load,
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  slivers: [
                    SliverToBoxAdapter(
                      child: HomeHero(
                        scroll: _scroll,
                        onSearch: _openSearch,
                        onRefresh: notifier.load,
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: HomeTabBarDelegate(
                        selectedIndex: state.tabIndex,
                        onSelect: notifier.selectTab,
                      ),
                    ),
                    ..._contentSlivers(state),
                  ],
                ),
              ),
      ),
    );
  }

  List<Widget> _contentSlivers(HomeState state) {
    final items = _visibleItems(state);

    if (state.isLoading && items.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (items.isEmpty) {
      if (state.hasMore) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
        return const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
        ];
      }
      return const [
        SliverFillRemaining(hasScrollBody: false, child: _EmptyView()),
      ];
    }

    final featured = items.first;
    final rest = items.sublist(1);
    // A tall hero and featured card can push a short grid below the fold, so
    // the "last card built" trigger is no longer reachable. Recheck proximity
    // after every content build instead; the scroll-position guard inside
    // _onScroll stops this once the feed is taller than the viewport.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    return [
      SliverToBoxAdapter(
        child: StaggeredEntrance(
          index: 0,
          child: FeaturedMediaCard(
            item: featured,
            onTap: () => _openItem(featured),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        sliver: SliverGrid(
          gridDelegate: mediaGridDelegateFor(context),
          delegate: SliverChildBuilderDelegate((context, i) {
            return StaggeredEntrance(
              index: i + 1,
              child: HomeMediaCard(
                item: rest[i],
                index: i + 1,
                onTap: () => _openItem(rest[i]),
              ),
            );
          }, childCount: rest.length),
        ),
      ),
      // Full-width footer spinner instead of an extra grid cell, so the
      // loader never occupies a lone trailing card slot.
      if (state.isLoadMore)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        )
      else if (!state.hasMore)
        const SliverToBoxAdapter(child: _EndOfFeed()),
    ];
  }

  void _openSearch() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchPage()));
  }

  void _openItem(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }
}

/// Editorial empty state for a feed with no entries.
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.compass, size: 34, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Text(
            '暂无内容',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'NOTHING HERE — YET',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 3,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hairline rule marking the end of pagination.
class _EndOfFeed extends StatelessWidget {
  const _EndOfFeed();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(width: 28, height: 0.5, color: scheme.outlineVariant),
          const SizedBox(width: 10),
          Icon(
            LucideIcons.asterisk,
            size: 12,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Container(width: 28, height: 0.5, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

/// Full-page error panel. The message lives inside a [SingleChildScrollView]
/// so even a very long error can be scrolled down to the retry action.
class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 22, height: 1, color: scheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'SYSTEM NOTICE',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '加载失败',
            style: TextStyle(
              fontSize: 40,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.cloud_off,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(LucideIcons.rotate_ccw, size: 16),
            label: const Text('重试'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
