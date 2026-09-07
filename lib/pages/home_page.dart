import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../widgets/media_card.dart';
import 'detail_page.dart';
import 'search_page.dart';
import 'home_provider.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const _tabs = ['全部', '小说', '短剧', '漫画', '听书'];
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
    final kind = _tabKinds[_tabs[state.tabIndex]];
    return state.items.where((item) => item.kind == kind).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    final notifier = ref.read(homeProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: _searchBar(),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: notifier.load),
        ],
      ),
      body: Column(
        children: [
          _topTabs(state),
          Expanded(child: _content(state)),
        ],
      ),
    );
  }

  /// Tappable fake search input; tapping opens the search page.
  Widget _searchBar() {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SearchPage()),
      ),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '搜索短剧、小说、漫画...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Top navigation tabs filtering the recommendation stream by content type.
  Widget _topTabs(HomeState state) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        children: List.generate(_tabs.length, (i) {
          final selected = state.tabIndex == i;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => ref.read(homeProvider.notifier).selectTab(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected ? primary : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Text(
                  _tabs[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected
                        ? primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _content(HomeState state) {
    final notifier = ref.read(homeProvider.notifier);
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(state.error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: notifier.load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final items = _visibleItems(state);
    if (items.isEmpty) {
      if (state.hasMore) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(child: Text('暂无内容'));
    }

    return RefreshIndicator(
      onRefresh: notifier.load,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: mediaGridDelegateFor(context),
              delegate: SliverChildBuilderDelegate((context, i) {
                // When the last card is built, nudge pagination. Post-frame
                // so we don't mutate state mid-build; loadMore() self-guards.
                if (i == items.length - 1) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _maybeLoadMore(),
                  );
                }
                return MediaCard(
                  item: items[i],
                  onTap: () => _openItem(items[i]),
                );
              }, childCount: items.length),
            ),
          ),
          // Full-width footer spinner instead of an extra grid cell, so the
          // loader never occupies a lone 7th card slot.
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
            ),
        ],
      ),
    );
  }

  void _openItem(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }
}
