import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';

/// Immutable view-model of the home recommendation feed.
class HomeState {
  final List<MediaItem> items;
  final int tabIndex;
  final bool isLoading;
  final bool isLoadMore;
  final bool hasMore;
  final String? error;

  const HomeState({
    this.items = const [],
    this.tabIndex = 0,
    this.isLoading = false,
    this.isLoadMore = false,
    this.hasMore = true,
    this.error,
  });

  HomeState copyWith({
    List<MediaItem>? items,
    int? tabIndex,
    bool? isLoading,
    bool? isLoadMore,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) {
    return HomeState(
      items: items ?? this.items,
      tabIndex: tabIndex ?? this.tabIndex,
      isLoading: isLoading ?? this.isLoading,
      isLoadMore: isLoadMore ?? this.isLoadMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Loads and pages the homepage recommendation feeds (tab_type=2 default
/// novel feed plus the 短剧=8 / 听书=5 dedicated feeds).
class HomeNotifier extends Notifier<HomeState> {
  static const tabs = ['全部', '小说', '短剧', '漫画', '听书'];
  static const tabKinds = {
    '小说': 'book',
    '短剧': 'video',
    '漫画': 'manga',
    '听书': 'audio',
  };
  // Upstream recommend tabs that carry non-novel content. The default
  // tab_type=2 feed only contains novels; 看剧=8 / 听书=5 return real
  // video / audio cards.
  static const tabTypes = {'短剧': 8, '听书': 5};

  int _offset = 0;
  String? _sessionId;
  final Set<String> _seen = {};
  bool _recommendExhausted = false;
  // Bumped on every load/selectTab so a slow in-flight response can't
  // overwrite a newer tab's feed.
  int _generation = 0;

  @override
  HomeState build() => const HomeState();

  String get _tabName => tabs[state.tabIndex];

  /// Reloads the current tab from page one.
  Future<void> load() async {
    final generation = ++_generation;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      hasMore: true,
    );
    _offset = 0;
    _sessionId = null;
    _seen.clear();
    _recommendExhausted = false;

    try {
      List<MediaItem> all;
      final tabType = tabTypes[_tabName];
      if (tabType != null) {
        all = await _loadTabRecommend(tabType: tabType, page: 1);
      } else {
        try {
          final d = await ApiClient.instance.homepageRecommend(offset: 0);
          all = await _parseHomepage(d);
        } catch (_) {
          // Older  binaries may not expose the recommendation route yet;
          // keep the home page useful with a normal search fallback.
          final d = await ApiClient.instance.search('推荐');
          final tabs = await parseSearchTabsAsync(d);
          all = tabs.expand((tab) => tab.items).toList();
          state = state.copyWith(hasMore: false);
        }
      }
      if (generation != _generation) return; // a newer load superseded us
      state = state.copyWith(items: all, isLoading: false);
    } catch (e) {
      if (generation != _generation) return;
      state = state.copyWith(error: '$e', isLoading: false);
    }
  }

  /// Switches to another content tab and reloads its feed.
  void selectTab(int index) {
    if (index == state.tabIndex) return;
    state = state.copyWith(tabIndex: index, items: const []);
    load();
  }

  /// Appends the next page to the current feed.
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    final generation = _generation;
    state = state.copyWith(isLoadMore: true);

    try {
      List<MediaItem> fresh;
      final tabType = tabTypes[_tabName];
      if (tabType != null) {
        final kind = tabKinds[_tabName];
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
            sessionId: _sessionId,
          );
          fresh = await _parseHomepage(d);
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
        final d = await ApiClient.instance.homepageRecommend(
          offset: _offset,
          sessionId: _sessionId,
        );
        fresh = await _parseHomepage(d);
      }

      if (generation != _generation) return; // a reload superseded us
      state = state.copyWith(
        items: [...state.items, ...fresh],
        isLoadMore: false,
      );
    } catch (_) {
      if (generation != _generation) return;
      state = state.copyWith(isLoadMore: false, hasMore: false);
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
    final kind = tabKinds[_tabName];
    List<MediaItem> items;
    try {
      final d = await ApiClient.instance.homepageRecommend(
        tabType: tabType,
        offset: 0,
      );
      items = await _parseHomepage(d);
      if (items.isEmpty) {
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

  /// Searches the tab name and returns items matching the tab's kind.
  Future<List<MediaItem>> _loadTabSearch({
    required int tabType,
    required int page,
  }) async {
    final keyword = _tabName;
    final kind = tabKinds[keyword];
    final d = await ApiClient.instance.search(keyword, page: page);
    final tabs = await parseSearchTabsAsync(d);
    final all = tabs.expand((tab) => tab.items).toList();
    final fresh = <MediaItem>[];
    for (final item in all) {
      if (kind != null && item.kind != kind) continue;
      final key = '${item.kind}:${item.id}';
      if (_seen.add(key)) fresh.add(item);
    }
    if (fresh.isEmpty) state = state.copyWith(hasMore: false);
    return fresh;
  }

  /// Parses a homepage recommend payload, dedupes items and updates the
  /// pagination cursor. The upstream `has_more` flag is unreliable, so we
  /// keep paging while a page still yields new items. The session_id must be
  /// echoed back on the next page: the upstream binds it to the device that
  /// opened it, and the backend pins that device so paging works.
  ///
  /// The heavy recursive card extraction runs on a background isolate; the
  /// cursor scan is cheap so it stays on the UI isolate.
  Future<List<MediaItem>> _parseHomepage(Map<String, dynamic> d) async {
    final parsed = await parseMediaItemsAsync(d);
    final fresh = <MediaItem>[];
    for (final item in parsed) {
      final key = '${item.kind}:${item.id}';
      if (_seen.add(key)) fresh.add(item);
    }
    final data = d['data'];
    if (data is Map) {
      final tabItem = data['tab_item'];
      // Scan every tab for a usable next_offset. The first tab_item is often
      // an empty "推荐" shell with no cursor, while the real content tab
      // (e.g. 看剧) carries it — reading only the first would wrongly stop
      // paging. The session_id lives on the content tab too.
      if (tabItem is List) {
        var advanced = false;
        for (final t in tabItem) {
          if (t is! Map) continue;
          final no = t['next_offset'];
          final s = t['session_id'];
          if (s is String && s.isNotEmpty) _sessionId = s;
          if (no is num && no.toInt() > _offset) {
            _offset = no.toInt();
            advanced = true;
          }
        }
        if (!advanced) state = state.copyWith(hasMore: false);
      }
    }
    if (fresh.isEmpty) state = state.copyWith(hasMore: false);
    return fresh;
  }
}

final homeProvider = NotifierProvider<HomeNotifier, HomeState>(
  HomeNotifier.new,
);
