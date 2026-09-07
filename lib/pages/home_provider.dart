import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';

typedef HomepageLoader =
    Future<HomepagePage> Function({int tabType, int offset, String? sessionId});
typedef SearchTabsLoader =
    Future<List<SearchTab>> Function(String query, {int page});

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

/// Mutable pagination state owned by exactly one tab.
class _TabFeed {
  List<MediaItem> items = [];
  int offset = 0;
  String? sessionId;
  int searchPage = 0;
  Map<String, int> searchPages = const {};
  final Set<String> seen = {};
  bool recommendExhausted = false;
  bool hasMore = true;
  bool loaded = false;

  void reset() {
    items = [];
    offset = 0;
    sessionId = null;
    searchPage = 0;
    searchPages = const {};
    seen.clear();
    recommendExhausted = false;
    hasMore = true;
    loaded = false;
  }
}

class _FetchedFeed {
  final List<MediaItem> items;
  final int? nextOffset;
  final String? sessionId;
  final int searchPage;
  final Map<String, int> searchPages;
  final bool recommendExhausted;
  final bool hasMore;

  const _FetchedFeed({
    required this.items,
    required this.nextOffset,
    required this.sessionId,
    required this.searchPage,
    this.searchPages = const {},
    required this.recommendExhausted,
    required this.hasMore,
  });
}

class _Attempt<T> {
  final T? value;
  final Object? error;

  const _Attempt.value(T this.value) : error = null;
  const _Attempt.error(this.error) : value = null;
}

Future<_Attempt<T>> _attempt<T>(Future<T> future) async {
  try {
    return _Attempt<T>.value(await future);
  } catch (error) {
    return _Attempt<T>.error(error);
  }
}

/// Loads and pages the homepage feeds. Each async operation captures its tab
/// and feed before the first await, so switching tabs can never redirect a
/// late response into a different tab's cache.
class HomeNotifier extends Notifier<HomeState> {
  static const tabs = ['全部', '小说', '短剧', '漫画', '听书'];
  static const tabKinds = {
    '小说': 'book',
    '短剧': 'video',
    '漫画': 'manga',
    '听书': 'audio',
  };
  static const tabTypes = {'小说': 2, '短剧': 8, '听书': 5};

  final HomepageLoader _homepageLoader;
  final SearchTabsLoader _searchLoader;

  HomeNotifier({HomepageLoader? homepageLoader, SearchTabsLoader? searchLoader})
    : _homepageLoader = homepageLoader ?? ApiClient.instance.homepagePage,
      _searchLoader = searchLoader ?? ApiClient.instance.searchTabs;

  final Map<int, _TabFeed> _feeds = {};
  int _generation = 0;

  @override
  HomeState build() {
    ++_generation;
    _feeds.clear();
    return const HomeState();
  }

  _TabFeed _feedFor(int tabIndex) => _feeds.putIfAbsent(tabIndex, _TabFeed.new);

  /// Reloads the selected tab from page one.
  Future<void> load() async {
    final tabIndex = state.tabIndex;
    final generation = ++_generation;
    final feed = _feedFor(tabIndex)..reset();
    state = state.copyWith(
      items: const [],
      isLoading: true,
      isLoadMore: false,
      hasMore: true,
      clearError: true,
    );

    try {
      final fetched = await _loadInitial(tabIndex);
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      _applyFetched(feed, fetched, replace: true);
      state = state.copyWith(
        items: feed.items,
        isLoading: false,
        isLoadMore: false,
        hasMore: feed.hasMore,
      );
    } catch (error) {
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      feed.hasMore = false;
      state = state.copyWith(
        error: '$error',
        isLoading: false,
        isLoadMore: false,
        hasMore: false,
      );
    }
  }

  /// Restores a cached tab immediately. Incrementing the generation happens
  /// even on a cache hit, which invalidates requests started by the old tab.
  void selectTab(int index) {
    if (index == state.tabIndex || index < 0 || index >= tabs.length) return;
    ++_generation;
    final cached = _feeds[index];
    state = state.copyWith(
      tabIndex: index,
      items: cached?.items ?? const [],
      isLoading: false,
      isLoadMore: false,
      hasMore: cached?.hasMore ?? true,
      clearError: true,
    );
    if (cached == null || !cached.loaded) load();
  }

  /// Appends the next page to the selected feed.
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    final tabIndex = state.tabIndex;
    final generation = _generation;
    final feed = _feedFor(tabIndex);
    state = state.copyWith(isLoadMore: true, clearError: true);

    try {
      final fetched = await _loadNext(tabIndex, feed);
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      _applyFetched(feed, fetched, replace: false);
      state = state.copyWith(
        items: feed.items,
        isLoadMore: false,
        hasMore: feed.hasMore,
      );
    } catch (_) {
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      // Stop automatic bottom-of-grid retry loops. Pull-to-refresh gives the
      // user an explicit retry path and resets this flag.
      feed.hasMore = false;
      state = state.copyWith(isLoadMore: false, hasMore: false);
    }
  }

  Future<_FetchedFeed> _loadInitial(int tabIndex) async {
    final name = tabs[tabIndex];
    if (name == '全部') return _loadAllInitial();

    final kind = tabKinds[name]!;
    final tabType = tabTypes[name];
    if (tabType == null) {
      final search = await _searchLoader(name);
      final items = _searchItems(search, name, kind);
      return _FetchedFeed(
        items: items,
        nextOffset: null,
        sessionId: null,
        searchPage: 1,
        recommendExhausted: true,
        hasMore: items.isNotEmpty,
      );
    }

    try {
      final page = await _homepageLoader(tabType: tabType);
      final items = _forceKind(page.items, kind);
      final nextOffset = page.nextOffset;
      final canAdvance = nextOffset != null && nextOffset > 0;
      if (items.isNotEmpty || canAdvance) {
        return _FetchedFeed(
          items: items,
          nextOffset: canAdvance ? nextOffset : null,
          sessionId: page.sessionId,
          searchPage: 0,
          recommendExhausted: !canAdvance,
          // Search remains available after recommendations are exhausted.
          hasMore: true,
        );
      }
    } catch (_) {
      // Older backends may not expose recommendations; search below keeps the
      // tab usable.
    }

    final search = await _searchLoader(name);
    final items = _searchItems(search, name, kind);
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: null,
      searchPage: 1,
      recommendExhausted: true,
      hasMore: items.isNotEmpty,
    );
  }

  /// "全部" combines the novel recommendation stream with first pages for
  /// the other supported categories.
  Future<_FetchedFeed> _loadAllInitial() async {
    final recommendationFuture = _attempt(_loadInitial(1));
    final videoFuture = _attempt(_searchLoader('短剧'));
    final mangaFuture = _attempt(_searchLoader('漫画'));
    final audioFuture = _attempt(_searchLoader('听书'));

    final recommendation = await recommendationFuture;
    final video = await videoFuture;
    final manga = await mangaFuture;
    final audio = await audioFuture;
    if (recommendation.value == null &&
        video.value == null &&
        manga.value == null &&
        audio.value == null) {
      throw recommendation.error ??
          video.error ??
          manga.error ??
          audio.error ??
          StateError('首页加载失败');
    }

    final groups = <List<MediaItem>>[
      if (recommendation.value != null) recommendation.value!.items,
      if (video.value != null) _searchItems(video.value!, '短剧', 'video'),
      if (manga.value != null) _searchItems(manga.value!, '漫画', 'manga'),
      if (audio.value != null) _searchItems(audio.value!, '听书', 'audio'),
    ];
    final page = recommendation.value;
    final items = _interleave(groups);
    return _FetchedFeed(
      items: items,
      nextOffset: page?.nextOffset,
      sessionId: page?.sessionId,
      searchPage: 1,
      searchPages: {
        '小说': page?.searchPage ?? 0,
        if (video.value != null) '短剧': 1,
        if (manga.value != null) '漫画': 1,
        if (audio.value != null) '听书': 1,
      },
      recommendExhausted: page?.recommendExhausted ?? true,
      hasMore: items.isNotEmpty || page?.nextOffset != null,
    );
  }

  Future<_FetchedFeed> _loadNext(int tabIndex, _TabFeed feed) async {
    final name = tabs[tabIndex];
    if (name == '全部') return _loadAllNext(feed);

    final kind = tabKinds[name]!;
    final tabType = tabTypes[name];
    if (tabType != null && !feed.recommendExhausted) {
      try {
        final page = await _homepageLoader(
          tabType: tabType,
          offset: feed.offset,
          sessionId: feed.sessionId,
        );
        final items = _forceKind(page.items, kind);
        final nextOffset = page.nextOffset;
        final canAdvance = nextOffset != null && nextOffset > feed.offset;
        // Duplicate or empty pages can still lead to fresh recommendations.
        // Only an advancing cursor is safe to request again.
        if (canAdvance || items.any((item) => _isUnseen(feed, item))) {
          return _FetchedFeed(
            items: items,
            nextOffset: canAdvance ? nextOffset : null,
            sessionId: page.sessionId,
            searchPage: feed.searchPage,
            recommendExhausted: !canAdvance,
            hasMore: true,
          );
        }
      } catch (_) {
        // Fall through to search. A recommendation outage should not make the
        // whole category stop paginating.
      }
    }

    final pageNumber = feed.searchPage + 1;
    final searchTabs = await _searchLoader(name, page: pageNumber);
    final items = _searchItems(searchTabs, name, kind);
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: feed.sessionId,
      searchPage: pageNumber,
      recommendExhausted: true,
      hasMore: items.isNotEmpty,
    );
  }

  Future<_FetchedFeed> _loadAllNext(_TabFeed feed) async {
    final pageNumber = feed.searchPage + 1;
    // Novel recommendations and search have their own cursor. In particular,
    // the first fallback search must start at page one even if the other
    // categories have already loaded several pages.
    final bookFeed = _TabFeed()
      ..offset = feed.offset
      ..sessionId = feed.sessionId
      ..searchPage = feed.searchPages['小说'] ?? 0
      ..recommendExhausted = feed.recommendExhausted;
    bookFeed.seen.addAll(feed.seen);
    final recommendationFuture = _attempt(_loadNext(1, bookFeed));
    final videoPage = (feed.searchPages['短剧'] ?? 0) + 1;
    final mangaPage = (feed.searchPages['漫画'] ?? 0) + 1;
    final audioPage = (feed.searchPages['听书'] ?? 0) + 1;
    final videoFuture = _attempt(_searchLoader('短剧', page: videoPage));
    final mangaFuture = _attempt(_searchLoader('漫画', page: mangaPage));
    final audioFuture = _attempt(_searchLoader('听书', page: audioPage));

    final recommendation = await recommendationFuture;
    final video = await videoFuture;
    final manga = await mangaFuture;
    final audio = await audioFuture;
    if (recommendation.value == null &&
        video.value == null &&
        manga.value == null &&
        audio.value == null) {
      throw recommendation.error ??
          video.error ??
          manga.error ??
          audio.error ??
          StateError('首页分页失败');
    }

    final groups = <List<MediaItem>>[
      if (recommendation.value != null) recommendation.value!.items,
      if (video.value != null) _searchItems(video.value!, '短剧', 'video'),
      if (manga.value != null) _searchItems(manga.value!, '漫画', 'manga'),
      if (audio.value != null) _searchItems(audio.value!, '听书', 'audio'),
    ];
    final recommendationPage = recommendation.value;
    final items = _interleave(groups);
    return _FetchedFeed(
      items: items,
      nextOffset: recommendationPage?.nextOffset,
      sessionId: recommendationPage?.sessionId ?? feed.sessionId,
      searchPage: pageNumber,
      searchPages: {
        ...feed.searchPages,
        if (recommendationPage != null) '小说': recommendationPage.searchPage,
        if (video.value != null) '短剧': videoPage,
        if (manga.value != null) '漫画': mangaPage,
        if (audio.value != null) '听书': audioPage,
      },
      recommendExhausted:
          recommendationPage?.recommendExhausted ?? feed.recommendExhausted,
      hasMore:
          items.isNotEmpty ||
          (recommendationPage != null && recommendationPage.nextOffset != null),
    );
  }

  void _applyFetched(
    _TabFeed feed,
    _FetchedFeed fetched, {
    required bool replace,
  }) {
    final fresh = <MediaItem>[];
    for (final item in fetched.items) {
      final key = '${item.kind}:${item.id}';
      if (item.id.isNotEmpty && feed.seen.add(key)) fresh.add(item);
    }
    feed
      ..items = replace ? fresh : [...feed.items, ...fresh]
      ..offset = fetched.nextOffset ?? feed.offset
      ..sessionId = fetched.sessionId ?? feed.sessionId
      ..searchPage = fetched.searchPage
      ..searchPages = fetched.searchPages
      ..recommendExhausted = fetched.recommendExhausted
      ..hasMore = fetched.hasMore
      ..loaded = true;

    // If a page contained only duplicates and no source has a known cursor,
    // stop cleanly instead of repeatedly requesting the same page.
    if (!replace && fresh.isEmpty && fetched.nextOffset == null) {
      feed.hasMore = false;
    }
  }

  bool _isUnseen(_TabFeed feed, MediaItem item) =>
      item.id.isNotEmpty && !feed.seen.contains('${item.kind}:${item.id}');

  List<MediaItem> _searchItems(
    List<SearchTab> searchTabs,
    String label,
    String kind,
  ) {
    final matching = searchTabs.where(
      (tab) =>
          tab.title.isNotEmpty &&
          (tab.title.contains(label) || label.contains(tab.title)),
    );
    final selected = matching.isEmpty ? searchTabs : matching;
    return selected
        .expand((tab) => tab.items)
        .where((item) => item.kind == kind)
        .toList(growable: false);
  }

  List<MediaItem> _forceKind(List<MediaItem> items, String kind) {
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
        .toList(growable: false);
  }

  /// Round-robin groups so the combined feed does not show a solid block of
  /// one category before the next category begins.
  List<MediaItem> _interleave(List<List<MediaItem>> groups) {
    final result = <MediaItem>[];
    final maxLength = groups.fold<int>(
      0,
      (max, group) => group.length > max ? group.length : max,
    );
    for (var index = 0; index < maxLength; index++) {
      for (final group in groups) {
        if (index < group.length) result.add(group[index]);
      }
    }
    return result;
  }
}

final homeProvider = NotifierProvider<HomeNotifier, HomeState>(
  HomeNotifier.new,
);
