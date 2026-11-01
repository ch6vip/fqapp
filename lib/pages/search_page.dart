import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../models/media_id.dart';
import '../models/search_discovery.dart';
import '../models/shuqi_book.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/desktop_platform.dart';
import '../services/search_history_store.dart';
import '../services/user_facing_error.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/media_card.dart';
import '../widgets/search/search_content_toolbar.dart';
import '../widgets/search/search_discovery.dart';
import '../widgets/search/search_scope_bar.dart';
import 'detail_page.dart';
import 'search_shuqi.dart';

typedef SearchPageLoader =
    Future<List<SearchTab>> Function(
      String query, {
      required int tabType,
      required int offset,
    });

/// Query suggestions for the search field.
///
/// Note: 联想词取 `query_result`、热搜词两层嵌套且有空 cell — 见
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
typedef SearchSuggestLoader =
    Future<List<SearchSuggestion>> Function(String query);

/// The hot search board.
typedef HotSearchLoader = Future<HotSearch> Function();

class SearchPage extends StatefulWidget {
  final String? initialQuery;
  final SearchPageLoader? searchLoader;
  final Future<MediaItem?> Function(String id)? idSearchLoader;
  final SearchHistoryRepository? historyStore;

  /// 打开时选中的分类页签。分区入口把语境带进来：短剧分区从漫剧频道进
  /// 搜索落「漫剧」，其余频道落「短剧」；缺省仍是「综合」。
  final SearchCategory initialCategory;

  /// Optional discovery sources. Leaving them null fetches from the backend
  /// unless another loader was injected, which marks the caller as offline (the
  /// rule the other pages follow).
  final SearchSuggestLoader? suggestLoader;
  final HotSearchLoader? hotSearchLoader;

  /// 书旗搜索。留空走后端；注入后视为离线，与 [searchLoader] 同一约定。
  final ShuqiSearchLoader? shuqiSearchLoader;

  const SearchPage({
    super.key,
    this.initialQuery,
    this.searchLoader,
    this.idSearchLoader,
    this.historyStore,
    this.suggestLoader,
    this.hotSearchLoader,
    this.shuqiSearchLoader,
    this.initialCategory = SearchCategory.general,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _paginationThreshold = 480.0;
  static const _categories = SearchCategory.values;
  static const _listViewPreference = 'search_list_view';
  static const _minimumScorePreference = 'search_minimum_score';

  /// The thresholds the dropdown offers; storage may only hold one of these.
  static const _scoreThresholds = <double>[0, 8, 9];

  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );
  List<_SearchFeed> _feeds = [for (final _ in _categories) _SearchFeed()];
  String _query = '';
  String? _idQuery;
  int _tabIndex = 0;
  int _requestGeneration = 0;
  double _minimumScore = 0;
  bool _listView = false;

  /// 搜索来源：false = 番茄（默认），true = 书旗。
  ///
  /// 书旗没有番茄那套综合/小说/短剧分类，切到书旗时结果落在第一个 feed 里，
  /// 分类页签置灰并停止响应点击；退出书旗只能点「番茄」。
  bool _shuqiSource = false;

  /// 进入书旗前停留的番茄分类；点「番茄」时回到这里，而不是重置到综合。
  int _fanqieTab = 0;

  bool _layoutChosen = false;

  /// 版式偏好是否已经从本地读完。读完之前不套用「矮窗口默认列表」规则，
  /// 免得先按窗口给一个默认值、再被存档覆盖。
  bool _layoutPreferenceLoaded = false;

  /// 本地存档里的版式；null 表示用户从没手动选过，按窗口给默认值。
  bool? _savedLayout;
  Future<void> _layoutWrite = Future<void>.value();

  /// Guards against a late preference read overwriting a choice the user
  /// already made while the read was in flight (same contract as
  /// [_layoutChosen]).
  bool _scoreChosen = false;
  Future<void> _scoreWrite = Future<void>.value();

  /// In-flight search / id-lookup. Superseded searches and page disposal cancel
  /// it so a fast typist does not leave a queue of upstream requests behind.
  BackendRequest? _activeRequest;
  List<String> _history = const [];
  bool _historyLoading = true;
  int _historyGeneration = 0;

  /// Live text in the field, which differs from [_query] while it is edited.
  String _draft = '';
  HotSearch _hot = HotSearch.empty;
  List<SearchSuggestion> _suggestions = const [];
  Timer? _suggestDebounce;
  int _suggestGeneration = 0;

  SearchHistoryRepository get _historyStore =>
      widget.historyStore ?? SearchHistoryStore.instance;

  /// The viewer is editing the field rather than reading the executed query.
  bool get _refining => _draft.trim() != _query;

  /// Suggestions are only useful while the text differs from the executed
  /// query, i.e. the user is refining rather than reading results.
  bool get _showSuggestions => _suggestions.isNotEmpty && _refining;

  SearchSuggestLoader get _suggestLoader =>
      widget.suggestLoader ??
      (widget.searchLoader != null || widget.idSearchLoader != null
          ? (_) async => const <SearchSuggestion>[]
          : ApiClient.instance.searchSuggestions);

  HotSearchLoader get _hotLoader =>
      widget.hotSearchLoader ??
      (widget.searchLoader != null || widget.idSearchLoader != null
          ? () async => HotSearch.empty
          : ApiClient.instance.hotSearch);

  @override
  void initState() {
    super.initState();
    // 首帧就停在该页签：分区入口（短剧/漫剧）进来的搜索不该先闪「综合」。
    _tabIndex = _categories.indexOf(widget.initialCategory);
    _scrollController.addListener(_onScroll);
    _loadHistory();
    unawaited(_loadLayout());
    unawaited(_loadMinimumScore());
    unawaited(_loadHotSearch());
    final initial = widget.initialQuery?.trim() ?? '';
    if (initial.isNotEmpty) {
      _ctrl.text = initial;
      _draft = initial;
      _search(initial);
    }
  }

  Future<void> _loadLayout() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      final saved = preferences.get(_listViewPreference);
      _savedLayout = saved is bool ? saved : null;
      _layoutPreferenceLoaded = true;
      if (_layoutChosen) return;
      setState(() => _listView = _savedLayout ?? _defaultListView(context));
    } catch (_) {
      // Search remains usable if local preferences cannot be read.
    }
  }

  /// 没有已保存偏好时的版式：横屏或高度不足 480 的窗口用无封面列表，
  /// 给结果留出更多行。
  bool _defaultListView(BuildContext context) =>
      MediaQuery.orientationOf(context) == Orientation.landscape ||
      MediaQuery.sizeOf(context).height < 480;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 窗口尺寸变化（旋转、拖动桌面窗口）时，只要用户还没手动选过版式，
    // 默认值就跟着窗口走。
    if (_layoutPreferenceLoaded && !_layoutChosen && _savedLayout == null) {
      _listView = _defaultListView(context);
    }
  }

  /// Restores the rating threshold the viewer picked last time.
  ///
  /// The dropdown used to reset to 「评分不限」 on every visit, so a viewer who
  /// only reads well-rated works had to re-pick the threshold after each
  /// search. Only the two offered thresholds are accepted; anything else in
  /// storage is treated as 「不限」 rather than filtered invisibly.
  Future<void> _loadMinimumScore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted || _scoreChosen) return;
      final saved = preferences.getDouble(_minimumScorePreference);
      if (saved == null || !_scoreThresholds.contains(saved)) return;
      setState(() => _minimumScore = saved);
    } catch (_) {
      // Search remains usable if local preferences cannot be read.
    }
  }

  void _selectMinimumScore(double value) {
    setState(() {
      _scoreChosen = true;
      _minimumScore = value;
    });
    // Serialize rapid picks so the final user choice is persisted last.
    _scoreWrite = _scoreWrite.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        if (!await preferences.setDouble(_minimumScorePreference, value)) {
          throw StateError('Search rating threshold was not saved');
        }
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('评分筛选未保存，本次选择仍有效')),
        );
      }
    });
  }

  void _toggleLayout() {
    final value = !_listView;
    setState(() {
      _layoutChosen = true;
      _listView = value;
    });
    // Serialize rapid toggles so the final user choice is persisted last.
    _layoutWrite = _layoutWrite.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        if (!await preferences.setBool(_listViewPreference, value)) {
          throw StateError('Search layout was not saved');
        }
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('视图设置未保存，本次选择仍有效')));
      }
    });
  }

  /// 书旗条目没有上游评分，且评分下拉在书旗模式下禁用；阈值不能过滤整批结果。
  bool _matchesScore(MediaItem item) =>
      _idQuery != null ||
      _shuqiSource ||
      _minimumScore == 0 ||
      (item.score != null && item.score! >= _minimumScore);

  Future<void> _loadHotSearch() async {
    final hot = await _hotLoader();
    if (!mounted || hot.isEmpty) return;
    setState(() => _hot = hot);
  }

  /// Debounced so a fast typist does not issue a request per keystroke.
  void _onQueryChanged(String value) {
    _suggestDebounce?.cancel();
    // Invalidate at the edit, before the debounce window. A response for the
    // previous draft must not become selectable under the new text.
    final generation = ++_suggestGeneration;
    setState(() {
      _draft = value;
      _suggestions = const [];
    });
    final query = value.trim();
    if (query.isEmpty) {
      _showHistory();
      return;
    }
    // 书旗没有番茄的联想词接口；未提交的文字只用来过滤本地历史。
    if (_shuqiSource) return;
    _suggestDebounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_fetchSuggestions(query, generation)),
    );
  }

  Future<void> _fetchSuggestions(String query, int generation) async {
    final suggestions = await _suggestLoader(query);
    // A late response must not overwrite a newer query's suggestions.
    if (!mounted ||
        generation != _suggestGeneration ||
        query != _draft.trim()) {
      return;
    }
    setState(() => _suggestions = suggestions);
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

  Future<void> _search(String q, {bool asKeyword = false}) async {
    final query = normalizeSearchQuery(q);
    if (query.isEmpty) return;
    _suggestDebounce?.cancel();
    if (_ctrl.text != query) {
      _ctrl.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _rememberQuery(query);
    ++_requestGeneration;
    // Picking a suggestion runs a different query than the text typed so far, so
    // the draft follows the executed query; otherwise the suggestion panel would
    // linger over the results it just produced.
    ++_suggestGeneration;
    setState(() {
      _query = query;
      _draft = query;
      _suggestions = const [];
      // 书旗 id 是另一套命名空间，按 id 直查不适用。
      _idQuery = (_shuqiSource || asKeyword) ? null : mediaIdFromSearch(query);
      _feeds = [for (final _ in _categories) _SearchFeed()];
    });
    if (_shuqiSource) {
      _activeRequest?.cancel();
      await _searchShuqi(query, _requestGeneration);
      return;
    }
    await _loadTab(_tabIndex);
  }

  /// 切换搜索来源。进入书旗时记住当前番茄分类并清掉作品 ID 状态；点回
  /// 「番茄」恢复那个分类，避免用户被悄悄重置到综合。
  void _selectSource(bool shuqi) {
    if (shuqi == _shuqiSource) return;
    setState(() {
      if (shuqi) _fanqieTab = _tabIndex;
      _shuqiSource = shuqi;
      _tabIndex = shuqi ? 0 : _fanqieTab;
      // 书旗 id 是另一套命名空间，切来源后 ID 提示与 ID 结果都失效。
      _idQuery = null;
      _suggestions = const [];
      ++_suggestGeneration;
      _feeds = [for (final _ in _categories) _SearchFeed()];
    });
    // 未提交的联想词请求属于番茄，切来源后不该再回来。
    _suggestDebounce?.cancel();
    _activeRequest?.cancel();
    ++_requestGeneration;
    if (_query.isEmpty) return;
    unawaited(
      shuqi ? _searchShuqi(_query, _requestGeneration) : _loadTab(_tabIndex),
    );
  }

  /// 书旗搜索：单次返回、服务端不支持分页，结果全量落在第一个 feed。
  Future<void> _searchShuqi(String query, int generation) async {
    final feed = _feeds[0];
    setState(() { feed.loading = true; feed.error = null; });
    try {
      final loader = widget.shuqiSearchLoader ?? ApiClient.instance.shuqiSearch;
      final items = await loadShuqiSearch(loader, query);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        feed.items..clear()..addAll(items);
        feed.seen
          ..clear()
          ..addAll(items.map((item) => '${item.kind}:${item.id}'));
        feed.hasMore = false; feed.initialized = true; feed.loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        feed.loading = false;
        feed.error = userFacingError(error);
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
    _suggestDebounce?.cancel();
    _activeRequest?.cancel();
    ++_requestGeneration;
    ++_suggestGeneration;
    setState(() {
      _query = '';
      _idQuery = null;
      _draft = '';
      _suggestions = const [];
      _feeds = [for (final _ in _categories) _SearchFeed()];
    });
  }

  void _clearSearchInput() {
    _ctrl.clear();
    _showHistory();
  }

  Future<void> _loadMore() {
    if (_shuqiSource) {
      return _feeds[0].error != null
          ? _searchShuqi(_query, _requestGeneration)
          : Future<void>.value();
    }
    return _loadTab(_tabIndex);
  }

  Future<void> _loadId(String id) async {
    if (_feeds.first.loading || _feeds.first.initialized) return;
    final generation = _requestGeneration;
    setState(() {
      for (final feed in _feeds) {
        feed.loading = true;
        feed.error = null;
      }
    });
    try {
      _activeRequest?.cancel();
      final request = _activeRequest = BackendRequest();
      final item = await ApiClient.instance.withCancellation(
        request,
        () => (widget.idSearchLoader ?? ApiClient.instance.lookupMediaById)(id),
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        for (var index = 0; index < _categories.length; index++) {
          final feed = _feeds[index];
          final kind = _categories[index].kind;
          if (item != null && (kind == null || kind == item.kind)) {
            feed.items.add(item);
          }
          feed.initialized = true;
          feed.loading = false;
          feed.hasMore = false;
        }
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        for (final feed in _feeds) {
          feed.loading = false;
          feed.error = userFacingError(error);
        }
      });
    }
  }

  // Note: 分类来源、游标与请求隔离见 .agents/notes/implemented/bug-fix/2026-09-10-search-categories.md
  Future<void> _loadTab(int index) async {
    if (_shuqiSource) return;
    if (_idQuery != null) return _loadId(_idQuery!);
    final feed = _feeds[index];
    if (_query.isEmpty || feed.loading || (feed.initialized && !feed.hasMore)) {
      return;
    }

    final generation = _requestGeneration;
    final category = _categories[index];
    final offset = feed.nextOffset;
    setState(() {
      feed.loading = true;
      feed.error = null;
    });

    try {
      final loader = widget.searchLoader ?? ApiClient.instance.searchTabs;
      _activeRequest?.cancel();
      final request = _activeRequest = BackendRequest();
      final tabs = await ApiClient.instance.withCancellation(
        request,
        () => loader(_query, tabType: category.tabType, offset: offset),
      );
      if (!mounted || generation != _requestGeneration) return;

      final sources = tabs
          .where(
            (tab) =>
                tab.title == category.sourceTitle ||
                tab.title == category.title,
          )
          .toList();
      final page = separateManjuSearchTabs(sources).firstWhere(
        (tab) =>
            tab.title == category.title ||
            (category == SearchCategory.book &&
                tab.title == category.sourceTitle),
        orElse: () => SearchTab(title: category.title, items: []),
      );
      final before = feed.items.where(_matchesScore).length;
      setState(() {
        for (final item in page.items) {
          if (item.id.isEmpty ||
              (category.kind != null && item.kind != category.kind)) {
            continue;
          }
          if (feed.seen.add('${item.kind}:${item.id}')) feed.items.add(item);
        }
        final next = page.nextOffset;
        feed.hasMore = page.hasMore != false && next != null && next > offset;
        if (feed.hasMore) feed.nextOffset = next!;
        feed.initialized = true;
        feed.loading = false;
      });
      // A filtered-empty or duplicate page can still advance. Leave a manual
      // continuation instead of chaining requests without new visible results.
      if (feed.items.where(_matchesScore).length > before) {
        _scheduleLoadMoreIfNeeded(index, generation);
      }
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        feed.loading = false;
        feed.error = userFacingError(e);
      });
    }
  }

  void _onScroll() {
    if (_idQuery != null) return;
    final feed = _feeds[_tabIndex];
    if (!_scrollController.hasClients ||
        !feed.initialized ||
        feed.error != null) {
      return;
    }
    if (_scrollController.position.extentAfter < _paginationThreshold) {
      _loadMore();
    }
  }

  void _scheduleLoadMoreIfNeeded(int index, int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && index == _tabIndex && generation == _requestGeneration) {
        _onScroll();
      }
    });
  }

  @override
  void dispose() {
    ++_requestGeneration;
    ++_suggestGeneration;
    _activeRequest?.cancel();
    _suggestDebounce?.cancel();
    _scrollController.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feeds[_tabIndex];

    final palette = HomePalette.of(context);

    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: palette.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Container(
          constraints: const BoxConstraints(minHeight: 40),
          margin: const EdgeInsets.only(right: homeGutter),
          decoration: BoxDecoration(
            color: palette.searchBar,
            borderRadius: BorderRadius.circular(20),
          ),
          child: TextField(
            controller: _ctrl,
            autofocus: false,
            textInputAction: TextInputAction.search,
            style: TextStyle(fontSize: 14, color: palette.ink),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索名称或作品 ID',
              hintStyle: TextStyle(fontSize: 13.5, color: palette.muted),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              suffixIconConstraints: const BoxConstraints(minWidth: 48),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _ctrl,
                builder: (context, value, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (value.text.isNotEmpty)
                      IconButton(
                        tooltip: '清空',
                        icon: Icon(
                          LucideIcons.x,
                          size: 16,
                          color: palette.muted,
                        ),
                        onPressed: _clearSearchInput,
                      ),
                    IconButton(
                      tooltip: '搜索',
                      icon: Icon(
                        LucideIcons.search,
                        size: 17,
                        color: HomePalette.accent,
                      ),
                      onPressed: () => _search(_ctrl.text),
                    ),
                  ],
                ),
              ),
            ),
            onChanged: _onQueryChanged,
            onSubmitted: _search,
          ),
        ),
      ),
      body: Column(
        children: [
          SearchScopeBar(
            categories: [for (final category in _categories) category.title],
            selectedIndex: _tabIndex,
            shuqi: _shuqiSource,
            onSelectCategory: _selectTab,
            onSelectSource: _selectSource,
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              // 与首页同一个阅读宽度：非 Windows 压到 840dp 并居中。
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isWindowsDesktop ? double.infinity : 840,
                ),
                child: _content(context, feed),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, _SearchFeed feed) {
    if (_showSuggestions) {
      return SearchSuggestionList(suggestions: _suggestions, onSelect: _search);
    }
    // 输入框里的文字还没执行：只留过滤后的历史，不闪回热搜，也不显示
    // 属于结果区的工具条。
    if (_refining) return _discoveryView(context, showToolbar: false);
    if (_query.isEmpty) return _discoveryView(context, showToolbar: true);
    return _resultsView(context, feed);
  }

  Widget _resultsView(BuildContext context, _SearchFeed feed) {
    if (!feed.initialized && feed.loading) {
      return _resultsShell(
        context,
        const Center(child: CircularProgressIndicator()),
      );
    }
    if (!feed.initialized && feed.error != null) {
      return _resultsShell(
        context,
        Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  feed.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                _paginationFooter(context, feed),
              ],
            ),
          ),
        ),
      );
    }
    final items = feed.items.where(_matchesScore).toList(growable: false);
    if (items.isEmpty) {
      return _resultsShell(
        context,
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _idQuery != null
                    ? (_feeds.first.items.isEmpty
                          ? '未找到该 ID 对应的作品'
                          : '该分类下没有匹配的作品')
                    : (!_shuqiSource && _minimumScore > 0
                          ? '已加载结果中暂无达到评分的作品'
                          : (feed.hasMore ? '当前页暂无匹配结果' : '无结果')),
              ),
              if (_idQuery == null && !_shuqiSource && _minimumScore > 0)
                TextButton(
                  onPressed: () => setState(() => _minimumScore = 0),
                  child: const Text('清除评分筛选'),
                ),
              if (feed.hasMore || feed.loading || feed.error != null)
                _paginationFooter(context, feed),
            ],
          ),
        ),
      );
    }
    return _resultItems(context, feed, items);
  }

  /// 结果态的外壳：工具条是内容区第一行，ID 提示行只在结果态出现。
  /// 空结果 / 首屏加载 / 首屏失败没有可滚动内容，也沿用同一层工具条。
  Widget _resultsShell(BuildContext context, Widget body) => Column(
    children: [
      _toolbar(context),
      if (_idQuery != null)
        SearchIdLookupHint(
          onKeywordSearch: () => _search(_ctrl.text, asKeyword: true),
        ),
      Expanded(child: body),
    ],
  );

  Widget _toolbar(BuildContext context) => SearchContentToolbar(
    shuqi: _shuqiSource,
    scoreEnabled: _idQuery == null,
    minimumScore: _minimumScore,
    onMinimumScore: _selectMinimumScore,
    listView: _listView,
    onToggleLayout: _toggleLayout,
    showRatingHint: _idQuery == null && !_shuqiSource && _minimumScore > 0,
  );

  /// 空查询时的发现区：搜索历史在前、热搜在后（版式在 [SearchDiscoveryView]）。
  Widget _discoveryView(BuildContext context, {required bool showToolbar}) =>
      SearchDiscoveryView(
        leading: showToolbar ? _toolbar(context) : null,
        hot: _shuqiSource ? HotSearch.empty : _hot,
        history: _history,
        historyLoading: _historyLoading,
        filter: normalizeSearchQuery(_ctrl.text).toLowerCase(),
        onSearch: _search,
        onClearHistory: _confirmClearHistory,
        onRemoveHistory: _removeHistory,
      );

  Widget _resultItems(
    BuildContext context,
    _SearchFeed feed,
    List<MediaItem> items,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 网格与首页同一套：16dp 栏距、12dp 列距、HomeMediaCard。
        final width = constraints.maxWidth - homeGutter * 2;
        return CustomScrollView(
          key: ValueKey((
            _requestGeneration,
            _tabIndex,
            _minimumScore,
            _listView,
          )),
          controller: _scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(child: _toolbar(context)),
            if (_idQuery != null)
              SliverToBoxAdapter(
                child: SearchIdLookupHint(
                  onKeywordSearch: () => _search(_ctrl.text, asKeyword: true),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(homeGutter, 12, homeGutter, 0),
              sliver: _listView
                  ? SliverList.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) =>
                          _resultRow(context, items[i]),
                    )
                  : SliverGrid(
                      gridDelegate: homeShelfDelegate(context, width),
                      delegate: SliverChildBuilderDelegate((context, i) {
                        final item = items[i];
                        return HomeMediaCard(
                          item: item,
                          coverWidth: homeShelfCardWidth(context, width),
                          showLength: true,
                          onTap: () => _openItem(item),
                        );
                      }, childCount: items.length),
                    ),
            ),
            if (_idQuery == null)
              SliverToBoxAdapter(child: _paginationFooter(context, feed)),
          ],
        );
      },
    );
  }

  Widget _resultRow(BuildContext context, MediaItem item) {
    final palette = HomePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openItem(item),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 13),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.line, width: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                // Length is what separates a 500-chapter grind from a
                // 100-chapter one, so it belongs next to the kind instead of
                // only on the detail page. Novels carry `word_number`;
                // dramas/manju carry an episode count in `ep`.
                [
                  if (item.author.isNotEmpty) item.author,
                  kindLabels[item.kind] ?? item.kind,
                  if (mediaLengthLabel(item).isNotEmpty) mediaLengthLabel(item),
                  if (item.score != null)
                    '${item.score!.toStringAsFixed(1)}分'
                  // 书旗条目没有上游评分，不再逐行补「暂无评分」。
                  else if (!isShuqiItem(item))
                    '暂无评分',
                ].join(' · '),
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 流尾三态：加载中 / 失败可重试 / 没有更多了。文案与首页流尾一致，字号
  /// 按搜索页的次级信息降到 12sp；文字用次级色，底部让出系统导航栏。
  Widget _paginationFooter(BuildContext context, _SearchFeed feed) {
    final palette = HomePalette.of(context);
    final style = TextStyle(fontSize: 12, height: 1.2, color: palette.muted);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    if (feed.loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.muted,
            ),
          ),
        ),
      );
    }
    if (feed.error != null) {
      return Padding(
        padding: EdgeInsets.only(top: 16, bottom: 24 + safeBottom),
        child: GestureDetector(
          onTap: _loadMore,
          behavior: HitTestBehavior.opaque,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Center(child: Text('加载失败，点击重试', style: style)),
          ),
        ),
      );
    }
    if (!feed.hasMore) {
      return Padding(
        padding: EdgeInsets.only(top: 16, bottom: 24 + safeBottom),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 12, height: 1, color: palette.muted),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('没有更多了', style: style),
              ),
              Container(width: 12, height: 1, color: palette.muted),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: 8, bottom: 24 + safeBottom),
      child: Center(
        child: TextButton(
          onPressed: _loadMore,
          style: TextButton.styleFrom(
            foregroundColor: palette.muted,
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text(
            '加载更多',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }

  void _selectTab(int index) {
    // 书旗来源下分类页签置灰，退出书旗只能点范围条右端的「番茄」。
    if (_shuqiSource || index == _tabIndex) return;
    setState(() => _tabIndex = index);
    if (_query.isEmpty) return;
    final feed = _feeds[index];
    if (!feed.initialized && feed.error == null) {
      _loadTab(index);
    } else {
      _scheduleLoadMoreIfNeeded(index, _requestGeneration);
    }
  }

  void _openItem(MediaItem item) {
    openBookDetail(context, item);
  }
}

/// 搜索页的分类页签。
///
/// 公开是给分区入口用的：短剧分区的搜索要带上频道语境（漫剧频道落「漫剧」、
/// 其余频道落「短剧」），[SearchPage.initialCategory] 直接收这个枚举。
enum SearchCategory {
  general('综合', 1),
  book('小说', 3, 'book'),
  video('短剧', 11, 'video'),
  manju('漫剧', 11, 'manju'),
  manga('漫画', 8, 'manga'),
  audio('听书', 2, 'audio');

  const SearchCategory(this.title, this.tabType, [this.kind]);

  final String title;
  final int tabType;
  final String? kind;

  String get sourceTitle => switch (this) {
    book => '书籍',
    manju => '短剧',
    _ => title,
  };
}

class _SearchFeed {
  final items = <MediaItem>[];
  final seen = <String>{};
  bool initialized = false;
  bool loading = false;
  bool hasMore = false;
  int nextOffset = 0;
  String? error;
}
