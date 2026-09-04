import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../widgets/media_card.dart';
import 'detail_page.dart';
import 'search_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _tabs = ['全部', '小说', '短剧', '漫画', '听书'];
  static const _tabKinds = {
    '小说': 'book',
    '短剧': 'video',
    '漫画': 'manga',
    '听书': 'audio',
  };
  // Upstream recommend tabs that carry non-novel content. The default
  // tab_type=2 feed only contains novels; 看剧=8 / 听书=5 return real
  // video / audio cards.
  static const _tabTypes = {'短剧': 8, '听书': 5};

  List<MediaItem> _items = [];
  int _tabIndex = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _recommendExhausted = false;
  int _offset = 0;
  final Set<String> _seen = {};
  String? _error;
  final ScrollController _scroll = ScrollController();
  // Throttle window for load-more triggers (PiliPlus EasyThrottle style):
  // rapid scrolling near the bottom must not fire back-to-back requests.
  DateTime? _lastLoadMoreAt;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
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
          now.difference(_lastLoadMoreAt!) >= const Duration(milliseconds: 500)) {
        _lastLoadMoreAt = now;
        _loadMore();
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _offset = 0;
      _hasMore = true;
      _recommendExhausted = false;
      _seen.clear();
    });
    try {
      List<MediaItem> all;
      final tabType = _tabTypes[_tabs[_tabIndex]];
      if (tabType != null) {
        all = await _loadTabRecommend(tabType: tabType, page: 1);
      } else {
        try {
          final d = await ApiClient.instance.homepageRecommend(offset: 0);
          all = _parseHomepage(d);
        } catch (_) {
          // Older  binaries may not expose the recommendation route yet;
          // keep the home page useful with a normal search fallback.
          final d = await ApiClient.instance.search('推荐');
          all = parseSearchTabs(d).expand((tab) => tab.items).toList();
          _hasMore = false;
        }
      }
      setState(() {
        _items = all;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Loads a content tab that has its own upstream recommend feed (短剧→8,
  /// 听书→5). Prefers the real recommend cards; falls back to searching the
  /// tab name if the recommend route is unavailable or empty. Items are
  /// forced to the tab's kind because the dedicated feeds carry no reliable
  /// type field (e.g. audio cards look like book cards).
  Future<List<MediaItem>> _loadTabRecommend({
    required int tabType,
    required int page,
  }) async {
    final kind = _tabKinds[_tabs[_tabIndex]];
    List<MediaItem> items;
    try {
      final d = await ApiClient.instance.homepageRecommend(
        tabType: tabType,
        offset: 0,
      );
      items = _parseHomepage(d);
      if (items.isNotEmpty) {
        // The dedicated feed returns at most one page (e.g. 看剧 has 6
        // cards); mark it exhausted so load-more goes straight to search.
        _recommendExhausted = true;
      } else {
        items = await _loadTabSearch(tabType: tabType, page: page);
      }
    } catch (_) {
      items = await _loadTabSearch(tabType: tabType, page: page);
    }
    return _forceKind(items, kind);
  }

  /// Forces every item's kind to [kind] (dedicated feeds carry no reliable
  /// type field on the cards themselves).
  List<MediaItem> _forceKind(List<MediaItem> items, String? kind) {
    if (kind == null) return items;
    return items
        .map(
          (item) => MediaItem(
            id: item.id,
            title: item.title,
            cover: item.cover,
            author: item.author,
            badge: item.badge,
            ep: item.ep,
            kind: kind,
            seriesId: item.seriesId,
            episodeId: item.episodeId,
          ),
        )
        .toList();
  }

  /// Searches [keyword] and returns the items matching [kind] for the tab.
  Future<List<MediaItem>> _loadTabSearch({
    required int tabType,
    required int page,
  }) async {
    final keyword = _tabs[_tabIndex];
    final kind = _tabKinds[keyword];
    final d = await ApiClient.instance.search(keyword, page: page);
    final tabs = parseSearchTabs(d);
    final all = tabs.expand((tab) => tab.items).toList();
    final fresh = <MediaItem>[];
    for (final item in all) {
      if (kind != null && item.kind != kind) continue;
      final key = '${item.kind}:${item.id}';
      if (_seen.add(key)) fresh.add(item);
    }
    if (fresh.isEmpty) _hasMore = false;
    return fresh;
  }

  /// Parses a homepage recommend payload, dedupes items and updates the
  /// pagination cursor. The upstream `has_more` flag is unreliable, so we
  /// keep paging while a page still yields new items.
  List<MediaItem> _parseHomepage(Map<String, dynamic> d) {
    final items = parseMediaItems(d);
    final fresh = <MediaItem>[];
    for (final item in items) {
      final key = '${item.kind}:${item.id}';
      if (_seen.add(key)) fresh.add(item);
    }
    final data = d['data'];
    if (data is Map) {
      final tabItem = data['tab_item'];
      // Scan every tab for a usable next_offset. The first tab_item is often
      // an empty "推荐" shell with no cursor, while the real content tab (e.g.
      // 看剧) carries it — reading only the first would wrongly stop paging.
      if (tabItem is List) {
        var advanced = false;
        for (final t in tabItem) {
          if (t is! Map) continue;
          final no = t['next_offset'];
          if (no is num && no.toInt() > _offset) {
            _offset = no.toInt();
            advanced = true;
          }
        }
        if (!advanced) _hasMore = false;
      }
    }
    if (fresh.isEmpty) _hasMore = false;
    return fresh;
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      List<MediaItem> fresh;
      final tabType = _tabTypes[_tabs[_tabIndex]];
      if (tabType != null) {
        final kind = _tabKinds[_tabs[_tabIndex]];
        if (_recommendExhausted) {
          // The dedicated feed has been fully consumed; keep loading from
          // search so the tab isn't stuck at one small page.
          final page = _offset ~/ 10 + 2;
          fresh = _forceKind(
            await _loadTabSearch(tabType: tabType, page: page),
            kind,
          );
          _offset += 10;
        } else {
          final d = await ApiClient.instance.homepageRecommend(
            tabType: tabType,
            offset: _offset,
          );
          fresh = _parseHomepage(d);
          if (fresh.isEmpty) {
            _recommendExhausted = true;
            final page = _offset ~/ 10 + 2;
            fresh = _forceKind(
              await _loadTabSearch(tabType: tabType, page: page),
              kind,
            );
            _offset += 10;
          }
        }
      } else {
        final d = await ApiClient.instance.homepageRecommend(offset: _offset);
        fresh = _parseHomepage(d);
      }
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...fresh];
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  List<MediaItem> get _visibleItems {
    if (_tabIndex == 0) return _items;
    final kind = _tabKinds[_tabs[_tabIndex]];
    return _items.where((item) => item.kind == kind).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: _searchBar(),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          _topTabs(),
          Expanded(child: _content()),
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
  Widget _topTabs() {
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
          final selected = _tabIndex == i;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _tabIndex = i),
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

  Widget _content() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final items = _visibleItems;
    if (items.isEmpty) {
      return const Center(child: Text('暂无内容'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.52,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: items.length + (_loadingMore ? 1 : 0),
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
          return MediaCard(
            item: items[i],
            onTap: () => _openItem(items[i]),
          );
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
