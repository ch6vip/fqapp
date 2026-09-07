import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/search_history_store.dart';
import '../widgets/media_card.dart';
import 'detail_page.dart';

typedef SearchPageLoader =
    Future<List<SearchTab>> Function(String query, {int page});

class SearchPage extends StatefulWidget {
  final String? initialQuery;
  final SearchPageLoader? searchLoader;
  final SearchHistoryRepository? historyStore;

  const SearchPage({
    super.key,
    this.initialQuery,
    this.searchLoader,
    this.historyStore,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _paginationThreshold = 480.0;

  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<SearchTab> _tabs = [];
  String _query = '';
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  String? _loadMoreError;
  int _tabIndex = 0;
  int _page = 0;
  int _requestGeneration = 0;
  List<String> _history = const [];
  bool _historyLoading = true;
  int _historyGeneration = 0;

  SearchHistoryRepository get _historyStore =>
      widget.historyStore ?? SearchHistoryStore.instance;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadHistory();
    final initial = widget.initialQuery?.trim() ?? '';
    if (initial.isNotEmpty) {
      _ctrl.text = initial;
      _search(initial);
    }
  }

  Future<void> _loadHistory() async {
    final generation = _historyGeneration;
    try {
      final history = await _historyStore.load();
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _history = history;
        _historyLoading = false;
      });
    } catch (_) {
      if (mounted && generation == _historyGeneration) {
        setState(() => _historyLoading = false);
      }
    }
  }

  Future<void> _search(String q) async {
    final query = normalizeSearchQuery(q);
    if (query.isEmpty) return;
    if (_ctrl.text != query) {
      _ctrl.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _rememberQuery(query);
    final generation = ++_requestGeneration;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _query = query;
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _error = null;
      _loadMoreError = null;
      _tabIndex = 0;
      _page = 0;
      _tabs = const [];
    });
    try {
      final tabs = await _loadPage(query, page: 1);
      if (!mounted || generation != _requestGeneration) return;
      final merged = _mergeSearchTabs(const [], tabs);
      setState(() {
        _tabs = merged.tabs;
        _page = 1;
        _hasMore = merged.addedCount > 0;
        _loading = false;
      });
      _scheduleLoadMoreIfNeeded();
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _hasMore = false;
      });
    }
  }

  void _rememberQuery(String query) {
    final generation = ++_historyGeneration;
    setState(() {
      _history = mergeSearchHistory(_history, query);
      _historyLoading = false;
    });
    unawaited(_persistQuery(query, generation));
  }

  Future<void> _persistQuery(String query, int generation) async {
    try {
      final history = await _historyStore.add(query);
      if (mounted && generation == _historyGeneration) {
        setState(() => _history = history);
      }
    } catch (_) {
      // Search remains available even if local history persistence fails.
    }
  }

  Future<void> _removeHistory(String query) async {
    final generation = ++_historyGeneration;
    setState(() {
      final normalized = normalizeSearchQuery(query).toLowerCase();
      _history = _history
          .where((item) => item.toLowerCase() != normalized)
          .toList(growable: false);
    });
    try {
      final history = await _historyStore.remove(query);
      if (mounted && generation == _historyGeneration) {
        setState(() => _history = history);
      }
    } catch (_) {}
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空搜索历史'),
        content: const Text('确定清空全部搜索记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    ++_historyGeneration;
    setState(() => _history = const []);
    try {
      await _historyStore.clear();
    } catch (_) {}
  }

  void _showHistory() {
    ++_requestGeneration;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _query = '';
      _tabs = const [];
      _loading = false;
      _loadingMore = false;
      _hasMore = false;
      _error = null;
      _loadMoreError = null;
      _page = 0;
      _tabIndex = 0;
    });
  }

  void _clearSearchInput() {
    _ctrl.clear();
    _showHistory();
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _query.isEmpty) return;

    final generation = _requestGeneration;
    final nextPage = _page + 1;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });

    try {
      final nextTabs = await _loadPage(_query, page: nextPage);
      if (!mounted || generation != _requestGeneration) return;
      final merged = _mergeSearchTabs(_tabs, nextTabs);
      setState(() {
        _tabs = merged.tabs;
        _page = nextPage;
        _hasMore = merged.addedCount > 0;
        _loadingMore = false;
      });
      if (merged.addedCount > 0) _scheduleLoadMoreIfNeeded();
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = '$e';
      });
    }
  }

  Future<List<SearchTab>> _loadPage(String query, {required int page}) {
    final loader = widget.searchLoader;
    if (loader != null) return loader(query, page: page);
    return ApiClient.instance.searchTabs(query, page: page);
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadMoreError != null) return;
    if (_scrollController.position.extentAfter < _paginationThreshold) {
      _loadMore();
    }
  }

  void _scheduleLoadMoreIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.extentAfter < _paginationThreshold) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    ++_requestGeneration;
    _scrollController.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeTab = _tabs.isNotEmpty
        ? _tabs[_tabIndex.clamp(0, _tabs.length - 1)]
        : null;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索短剧、小说、漫画...',
            border: InputBorder.none,
            suffixIconConstraints: const BoxConstraints(minWidth: 48),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _ctrl,
              builder: (context, value, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (value.text.isNotEmpty)
                    IconButton(
                      tooltip: '清空',
                      icon: const Icon(Icons.close),
                      onPressed: _clearSearchInput,
                    ),
                  IconButton(
                    tooltip: '搜索',
                    icon: const Icon(Icons.search),
                    onPressed: () => _search(_ctrl.text),
                  ),
                ],
              ),
            ),
          ),
          onChanged: (_) {
            if (_query.isEmpty) setState(() {});
          },
          onSubmitted: _search,
        ),
      ),
      body: Column(
        children: [
          if (_tabs.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: List.generate(_tabs.length, (i) {
                  final t = _tabs[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(t.title),
                      selected: i == _tabIndex,
                      onSelected: (_) => _selectTab(i),
                    ),
                  );
                }),
              ),
            ),
          Expanded(
            child: _query.isEmpty && !_loading
                ? _historyView(context)
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                : activeTab == null
                ? const Center(child: Text('无结果'))
                : activeTab.items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('无结果'),
                        if (_hasMore || _loadingMore || _loadMoreError != null)
                          _paginationFooter(context),
                      ],
                    ),
                  )
                : _resultGrid(context, activeTab),
          ),
        ],
      ),
    );
  }

  Widget _historyView(BuildContext context) {
    final theme = Theme.of(context);
    final filter = normalizeSearchQuery(_ctrl.text).toLowerCase();
    final visible = filter.isEmpty
        ? _history
        : _history
              .where((item) => item.toLowerCase().contains(filter))
              .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '搜索历史',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_history.isNotEmpty)
                    TextButton.icon(
                      onPressed: _confirmClearHistory,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('清空'),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (_historyLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_history.isEmpty)
                _historyMessage(context, '暂无搜索历史')
              else if (visible.isEmpty)
                _historyMessage(context, '没有匹配的搜索记录')
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final query in visible)
                      InputChip(
                        label: Text(query),
                        avatar: const Icon(Icons.history, size: 17),
                        onPressed: () => _search(query),
                        onDeleted: () => _removeHistory(query),
                        deleteButtonTooltipMessage: '删除 $query',
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _historyMessage(BuildContext context, String text) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }

  Widget _resultGrid(BuildContext context, SearchTab activeTab) {
    return CustomScrollView(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          sliver: SliverGrid(
            gridDelegate: mediaGridDelegateFor(context),
            delegate: SliverChildBuilderDelegate((context, i) {
              final item = activeTab.items[i];
              return MediaCard(item: item, onTap: () => _openItem(item));
            }, childCount: activeTab.items.length),
          ),
        ),
        SliverToBoxAdapter(child: _paginationFooter(context)),
      ],
    );
  }

  Widget _paginationFooter(BuildContext context) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: _loadMore,
            icon: const Icon(Icons.refresh),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: TextButton(onPressed: _loadMore, child: const Text('加载更多')),
      ),
    );
  }

  void _selectTab(int index) {
    if (index == _tabIndex) return;
    setState(() => _tabIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
        _onScroll();
      }
    });
  }

  void _openItem(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }
}

class _SearchTabsMerge {
  final List<SearchTab> tabs;
  final int addedCount;

  const _SearchTabsMerge(this.tabs, this.addedCount);
}

_SearchTabsMerge _mergeSearchTabs(
  List<SearchTab> current,
  List<SearchTab> incoming,
) {
  final merged = <SearchTab>[];
  final indexByTitle = <String, int>{};
  final seenByTitle = <String, Set<String>>{};
  var addedCount = 0;

  void appendTab(SearchTab tab, {required bool countAsAdded}) {
    var index = indexByTitle[tab.title];
    if (index == null) {
      index = merged.length;
      indexByTitle[tab.title] = index;
      seenByTitle[tab.title] = <String>{};
      merged.add(SearchTab(title: tab.title, items: []));
    }

    final items = List<MediaItem>.of(merged[index].items);
    final seen = seenByTitle[tab.title]!;
    for (final item in tab.items) {
      if (item.id.isEmpty) continue;
      final key = '${item.kind}:${item.id}';
      if (!seen.add(key)) continue;
      items.add(item);
      if (countAsAdded) addedCount++;
    }
    merged[index] = SearchTab(title: tab.title, items: items);
  }

  for (final tab in current) {
    appendTab(tab, countAsAdded: false);
  }
  for (final tab in incoming) {
    appendTab(tab, countAsAdded: true);
  }

  return _SearchTabsMerge(merged, addedCount);
}
