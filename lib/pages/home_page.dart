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

  final ScrollController _scroll = ScrollController();
  Timer? _loadMoreTimer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(homeProvider.notifier).load();
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
      if (state.error == null && _visibleItems(state).isEmpty) _maybeLoadMore();
      return;
    }
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 600) _maybeLoadMore();
  }

  /// Short and empty pages must continue even without a user scroll event.
  void _maybeLoadMore() {
    if (!mounted || _loadMoreTimer != null) return;
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
                              ),
                            ),
                            ..._contentSlivers(state),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _contentSlivers(HomeState state) {
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
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) => SliverGrid(
              gridDelegate: homeGridDelegate(
                context,
                constraints.crossAxisExtent,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = rest[index];
                return HomeEntrance(
                  key: ValueKey('${item.kind}:${item.id}'),
                  index: index,
                  child: HomeMediaCard(
                    item: item,
                    onTap: () => _openItem(item),
                  ),
                );
              }, childCount: rest.length),
            ),
          ),
        ),
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

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
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
