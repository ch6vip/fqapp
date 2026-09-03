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

  final TextEditingController _searchCtrl = TextEditingController();
  List<MediaItem> _items = [];
  int _tabIndex = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<MediaItem> all;
      try {
        final d = await ApiClient.instance.homepageRecommend();
        all = parseMediaItems(d);
      } catch (_) {
        // Older  binaries may not expose the recommendation route yet;
        // keep the home page useful with a normal search fallback.
        final d = await ApiClient.instance.search('推荐');
        all = parseSearchTabs(d).expand((tab) => tab.items).toList();
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

  List<MediaItem> get _visibleItems {
    if (_tabIndex == 0) return _items;
    final kind = _tabKinds[_tabs[_tabIndex]];
    return _items.where((item) => item.kind == kind).toList();
  }

  void _submitSearch(String query) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(initialQuery: query.trim()),
      ),
    );
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

  /// Tappable search input; submitting opens the search page with the query.
  Widget _searchBar() {
    return TextField(
      controller: _searchCtrl,
      textInputAction: TextInputAction.search,
      onSubmitted: _submitSearch,
      decoration: InputDecoration(
        hintText: '搜索短剧、小说、漫画...',
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
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
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.52,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => MediaCard(
          item: items[i],
          onTap: () => _openItem(items[i]),
        ),
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
