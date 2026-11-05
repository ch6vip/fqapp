import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../models/media_id.dart';
import '../models/search_discovery.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/desktop_platform.dart';
import '../services/search_history_store.dart';
import '../services/user_facing_error.dart';
import '../widgets/search/search_discovery.dart';
import '../widgets/search/search_media_tile.dart';
import '../widgets/search/search_score_filter.dart';
import '../widgets/wenku/wenku_ui.dart';
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

/// fqapp opens search as a route rather than upstream's in-shell overlay. The
/// route keeps upstream's 420ms `ArchivePlaneTransition` (diagonal incoming
/// sheet) instead of the platform page slide.
class SearchRoute<T> extends PageRouteBuilder<T> {
  SearchRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: WenkuMotion.enter,
        reverseTransitionDuration: WenkuMotion.exit,
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, _, child) =>
            MediaQuery.disableAnimationsOf(context)
            ? child
            : ArchivePlaneTransition(animation: animation, child: child),
      );
}

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

  /// Upstream search results are always `NovelRow` lists; the cover grid is
  /// an opt-in that fqapp persists.
  bool _listView = true;

  /// 搜索来源：false = 番茄（默认），true = 书旗。
  ///
  /// 书旗没有番茄那套综合/小说/短剧分类，切到书旗时结果落在第一个 feed 里，
  /// 分类页签置灰并停止响应点击；退出书旗只能点「番茄」。
  bool _shuqiSource = false;

  /// The 书旗 source is the segmented control's last value.
  static const _shuqiSegment = -1;

  /// 进入书旗前停留的番茄分类；点「番茄」时回到这里，而不是重置到综合。
  int _fanqieTab = 0;

  bool _layoutChosen = false;

  /// 本地存档里的版式；null 表示用户从没手动选过，保持上游默认列表。
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
      if (_layoutChosen || _savedLayout == null) return;
      setState(() => _listView = _savedLayout!);
    } catch (_) {
      // Search remains usable if local preferences cannot be read.
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('评分筛选未保存，本次选择仍有效')));
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
    setState(() {
      feed.loading = true;
      feed.error = null;
    });
    try {
      final loader = widget.shuqiSearchLoader ?? ApiClient.instance.shuqiSearch;
      final items = await loadShuqiSearch(loader, query);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        feed.items
          ..clear()
          ..addAll(items);
        feed.seen
          ..clear()
          ..addAll(items.map((item) => '${item.kind}:${item.id}'));
        feed.hasMore = false;
        feed.initialized = true;
        feed.loading = false;
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
    return Builder(
      builder: (context) => WenkuPage(
        extraHeight: _tabsHeight(context),
        header: Builder(builder: (context) => _header(context)),
        child: Builder(
          builder: (context) => Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isWindowsDesktop ? double.infinity : 840,
              ),
              // Upstream pads the whole search plane by the tab height, so
              // the scroll viewport starts below the search capsule and rows
              // only pass under the segmented tabs.
              child: Padding(
                padding: EdgeInsets.only(top: _tabsHeight(context)),
                child: _content(context, feed),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Upstream `_searchTabsHeight`: a 48dp-minimum segmented row plus its
  /// vertical gutters.
  double _tabsHeight(BuildContext context) =>
      math.max(48, MediaQuery.textScalerOf(context).scale(14) * 1.4 + 12) + 16;

  /// Upstream body inset inside the padded plane (status bar + toolbar + 20).
  double _bodyTopInset(BuildContext context) =>
      MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight + 20;

  Widget _header(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: isWindowsDesktop ? double.infinity : 840,
      ),
      child: Column(
        children: [
          SizedBox(
            height: FrostedHeader.toolbarHeight,
            child: Center(child: _searchBar(context)),
          ),
          SizedBox(height: _tabsHeight(context), child: _tabs(context)),
        ],
      ),
    ),
  );

  /// Upstream expanded search plate: one 46dp glass capsule holding a 44dp
  /// search glyph, the embedded field and a 46dp close button.
  Widget _searchBar(BuildContext context) => LiquidGlass(
    key: const ValueKey('expanded-search-bar'),
    radius: 23,
    elevated: false,
    touchPosition: .94,
    child: SizedBox(
      height: 46,
      child: Row(
        children: [
          const SizedBox(
            width: 44,
            child: ArchiveIcon(CupertinoIcons.search, size: 19),
          ),
          Expanded(
            child: AppSearchField(
              inputKey: const Key('search-input'),
              embedded: true,
              showLeading: false,
              autofocus: widget.initialQuery == null,
              controller: _ctrl,
              hint: _shuqiSource ? '搜索书旗书名或作者' : '搜索名称或作品 ID',
              clearTooltip: '清空',
              onChanged: _onQueryChanged,
              onSubmitted: _search,
            ),
          ),
          SizedBox(
            width: 46,
            height: 46,
            child: ArchiveIconButton(
              key: const ValueKey('inline-search-close'),
              tooltip: '收起搜索',
              onPressed: () => Navigator.maybePop(context),
              icon: const ArchiveIcon(CupertinoIcons.xmark, size: 17),
            ),
          ),
        ],
      ),
    ),
  );

  /// Upstream search tabs: one full-width archive segmented control. fqapp's
  /// content categories and the 书旗 source share it; 书旗 has no categories,
  /// so it is the last segment rather than a separate switch.
  Widget _tabs(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 4),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Upstream has four search fields; fqapp has seven segments. When
        // large text no longer fits one line per cell, keep each label on one
        // line and let the row scroll instead of wrapping characters.
        final labels = [
          for (final category in _categories) category.title,
          '书旗',
        ];
        final scaler = MediaQuery.textScalerOf(context);
        var widest = 0.0;
        for (final label in labels) {
          final painter = TextPainter(
            text: TextSpan(
              text: label,
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            textScaler: scaler,
            textDirection: Directionality.of(context),
            maxLines: 1,
          )..layout();
          widest = math.max(widest, painter.width);
          painter.dispose();
        }
        // AppGlassSegments cells are (width - 8 - 2 * gutter) / n wide with
        // a 4dp minimum gutter; a label needs its own width plus the 12dp
        // inset the control already budgets vertically.
        final needed = (widest + 12) * labels.length + 16;
        final segments = _segments(context);
        if (needed <= constraints.maxWidth) return segments;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: needed, child: segments),
        );
      },
    ),
  );

  Widget _segments(BuildContext context) => WenkuControls.segments<int>(
    context,
    key: const Key('search-category-tabs'),
    groupValue: _shuqiSource ? _shuqiSegment : _tabIndex,
    children: {
      for (var index = 0; index < _categories.length; index++)
        index: Text(_categories[index].title),
      _shuqiSegment: const Text('书旗'),
    },
    onValueChanged: (value) {
      if (value == null) return;
      if (value == _shuqiSegment) {
        _selectSource(true);
        return;
      }
      if (_shuqiSource) {
        _fanqieTab = value;
        _selectSource(false);
      } else {
        _selectTab(value);
      }
    },
  );

  Widget _content(BuildContext context, _SearchFeed feed) {
    if (_showSuggestions) {
      return SearchSuggestionList(
        suggestions: _suggestions,
        onSelect: _search,
        topInset: _bodyTopInset(context),
      );
    }
    // 输入框里的文字还没执行：只留过滤后的历史，不闪回热搜。
    if (_refining || _query.isEmpty) return _discoveryView(context);
    return LoadedContentSequence(
      generation: feed.initialized
          ? (_requestGeneration, _tabIndex, _shuqiSource)
          : null,
      child: _resultsView(context, feed),
    );
  }

  Widget _resultsView(BuildContext context, _SearchFeed feed) {
    if (!feed.initialized && feed.loading) {
      // Upstream SearchSkeleton carries its own safe-top + 76 inset.
      return const SearchSkeleton();
    }
    if (!feed.initialized && feed.error != null) {
      return _notice(
        context,
        ContentNotice(
          icon: CupertinoIcons.wifi_exclamationmark,
          title: '搜索失败，请稍后重试',
          message: feed.error,
          onRetry: _loadMore,
        ),
      );
    }
    final items = feed.items.where(_matchesScore).toList(growable: false);
    if (items.isEmpty) {
      final filtered = _idQuery == null && !_shuqiSource && _minimumScore > 0;
      final notice = ContentNotice(
        icon: CupertinoIcons.search,
        title: _idQuery != null
            ? (_feeds.first.items.isEmpty ? '未找到该 ID 对应的作品' : '该分类下没有匹配的作品')
            : filtered
            ? '已加载结果中暂无达到评分的作品'
            : '没有找到相关故事',
        message: _idQuery != null
            ? null
            : filtered
            ? '筛选只作用于已加载结果，未评分作品不计入。'
            : '试试更短的名称或作者名',
        onRetry: filtered ? () => _selectMinimumScore(0) : null,
        actionLabel: '清除评分筛选',
        secondaryAction: _idQuery != null
            // A missing ID can still be searched as a keyword.
            ? GlassTextButton(
                onPressed: () => _search(_ctrl.text, asKeyword: true),
                child: const AppText('按关键词搜索'),
              )
            : feed.hasMore
            ? GlassTextButton(
                onPressed: feed.loading ? null : _loadMore,
                child: AppText(feed.loading ? '正在加载…' : '加载更多'),
              )
            : null,
      );
      // Keep the heading (and its rating filter) when filtering leaves no
      // rows, so the threshold can still be changed in place.
      if (!filtered) return _notice(context, notice);
      return Padding(
        padding: EdgeInsets.only(top: _bodyTopInset(context)),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: _resultsHeading(context, 0),
            ),
            Expanded(child: notice),
          ],
        ),
      );
    }
    return _resultItems(context, feed, items);
  }

  Widget _notice(BuildContext context, Widget notice) => Padding(
    padding: EdgeInsets.only(top: _bodyTopInset(context) - 20),
    child: notice,
  );

  /// 空查询时的发现区：最近搜索在前、热搜在后（版式在 [SearchDiscoveryView]）。
  Widget _discoveryView(BuildContext context) => SearchDiscoveryView(
    topInset: _bodyTopInset(context),
    hot: _shuqiSource ? HotSearch.empty : _hot,
    history: _history,
    historyLoading: _historyLoading,
    filter: normalizeSearchQuery(_ctrl.text).toLowerCase(),
    onSearch: _search,
    onClearHistory: _confirmClearHistory,
    onRemoveHistory: _removeHistory,
  );

  /// Upstream `InlineSearchResults._buildResults`: a leading heading row,
  /// the responsive collection, then `FeedFooter`. fqapp's rating filter and
  /// layout switch sit on the heading row instead of a separate toolbar.
  Widget _resultItems(
    BuildContext context,
    _SearchFeed feed,
    List<MediaItem> items,
  ) => BookCollectionView.builder(
    controller: _scrollController,
    key: PageStorageKey((
      'search-results',
      _requestGeneration,
      _tabIndex,
      _shuqiSource,
      _minimumScore,
      _listView,
    )),
    leadingCount: 1,
    trailingCount: 1,
    grid: !_listView,
    physics: const AlwaysScrollableScrollPhysics(),
    padding: EdgeInsets.fromLTRB(
      22,
      _bodyTopInset(context),
      22,
      // Search covers the dock, so only the safe area is cleared (upstream
      // `InlineSearchResults`).
      MediaQuery.paddingOf(context).bottom + 24,
    ),
    itemCount: items.length + 2,
    itemBuilder: (context, index) {
      if (index == 0) {
        return LoadedContentItem(
          index: 0,
          child: _resultsHeading(context, items.length),
        );
      }
      // ID lookups have no pages, so they get no end marker.
      if (index == items.length + 1) {
        return _idQuery == null
            ? _footer(context, feed)
            : const SizedBox(height: 20);
      }
      final item = items[index - 1];
      return LoadedContentItem(
        key: ValueKey((item.kind, item.id)),
        index: index,
        placeholder: _listView
            ? const BookRowSkeleton()
            : const BookGridSkeleton(),
        child: _listView
            ? SearchNovelRow(
                key: ValueKey(('search-row', item.kind, item.id)),
                item: item,
                onTap: () => _openItem(item),
              )
            : SearchBookGridTile(
                key: ValueKey(('search-grid', item.kind, item.id)),
                item: item,
                onTap: () => _openItem(item),
              ),
      );
    },
  );

  Widget _resultsHeading(BuildContext context, int count) {
    final scheme = Theme.of(context).colorScheme;
    final secondary = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: 13,
      height: 1.6,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Semantics(
                container: true,
                header: true,
                child: AppText(
                  // Upstream says 已显示 when results are filtered locally: the
                  // count only covers loaded pages and grows while paging.
                  _idQuery == null && !_shuqiSource && _minimumScore > 0
                      ? '已显示 $count 个结果'
                      : '找到 $count 个结果',
                  maxLines: 1,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_shuqiSource)
                    AppText('不提供评分', style: secondary)
                  else
                    SearchScoreFilter(
                      enabled: _idQuery == null,
                      minimumScore: _minimumScore,
                      onChanged: _selectMinimumScore,
                    ),
                  ArchiveIconButton(
                    key: const Key('search-layout-toggle'),
                    tooltip: _listView ? '切换为封面视图' : '切换为列表视图',
                    onPressed: _toggleLayout,
                    icon: ArchiveIcon(
                      _listView
                          ? CupertinoIcons.square_grid_2x2
                          : CupertinoIcons.list_bullet,
                      size: 19,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (_idQuery != null)
            Row(
              children: [
                Expanded(child: AppText('按作品 ID 查找', style: secondary)),
                GlassTextButton(
                  compact: true,
                  onPressed: () => _search(_ctrl.text, asKeyword: true),
                  child: const AppText('按关键词搜索'),
                ),
              ],
            )
          else if (!_shuqiSource && _minimumScore > 0)
            AppText('筛选已加载结果，未评分作品不计入；可继续加载更多。', style: secondary),
        ],
      ),
    );
  }

  /// Upstream `FeedFooter`: skeleton while paging, a glass retry/continue
  /// button, and a plain 12sp end marker.
  Widget _footer(BuildContext context, _SearchFeed feed) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 12,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (feed.loading)
            BookCollectionSkeleton(rows: 2, label: '正在加载更多结果', grid: !_listView)
          else if (feed.error != null) ...[
            AppText('加载下一页失败', style: style),
            GlassTextButton(onPressed: _loadMore, child: const AppText('重试')),
          ] else if (_idQuery == null && feed.hasMore)
            GlassTextButton(onPressed: _loadMore, child: const AppText('加载更多'))
          else
            AppText('已经到底了', style: style),
        ],
      ),
    );
  }

  void _selectTab(int index) {
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
