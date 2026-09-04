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
  DateTime? _lastLoadMoreAt;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(homeProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      final now = DateTime.now();
      if (_lastLoadMoreAt == null ||
          now.difference(_lastLoadMoreAt!) >=
              const Duration(milliseconds: 500)) {
        _lastLoadMoreAt = now;
        ref.read(homeProvider.notifier).loadMore();
      }
    }
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
            Text(
              '搜索短剧、小说、漫画...',
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: notifier.load, child: const Text('重试')),
          ],
        ),
      );
    }

    final items = _visibleItems(state);
    if (items.isEmpty) {
      return const Center(child: Text('暂无内容'));
    }

    return RefreshIndicator(
      onRefresh: notifier.load,
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.52,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: items.length + (state.isLoadMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= items.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return MediaCard(item: items[i], onTap: () => _openItem(items[i]));
        },
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
