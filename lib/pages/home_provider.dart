import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/home_feed_cache.dart';
import '../services/user_facing_error.dart';

typedef HomepageLoader =
    Future<HomepagePage> Function({int tabType, int offset, String? sessionId});
typedef SearchTabsLoader =
    Future<List<SearchTab>> Function(String query, {int page});
typedef CategorySearchLoader = Future<List<SearchTab>> Function({int offset});

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
  Map<String, int> searchOffsets = const {};
  bool manjuSearchExhausted = false;
  bool mangaSearchExhausted = false;
  final Set<String> seen = {};
  bool recommendExhausted = false;
  bool hasMore = true;
  bool loaded = false;

  /// The card the user is currently on, reported by the page as it renders
  /// feeds. Persisted with the snapshot so the next cold start can resume from
  /// it (officially the landing cache keeps one video plus its position,
  /// `recordNextVideoData`, and consumes it once on the first response).
  String? lastVid;

  /// Set when a load seeded its list from the snapshot's resume point; the
  /// first network response then appends instead of replacing (official
  /// `onMoreDataLoaded` path, `Te` → `uf`), and is cleared right after.
  String? resumedVid;

  void reset() {
    items = [];
    offset = 0;
    sessionId = null;
    searchPage = 0;
    searchPages = const {};
    searchOffsets = const {};
    manjuSearchExhausted = false;
    mangaSearchExhausted = false;
    seen.clear();
    recommendExhausted = false;
    hasMore = true;
    loaded = false;
    // A cancelled load must not leave its resume intent behind; lastVid is
    // deliberately kept — it tracks the card on screen across refreshes.
    resumedVid = null;
  }
}

class _FetchedFeed {
  final List<MediaItem> items;
  final int? nextOffset;
  final String? sessionId;
  final int searchPage;
  final Map<String, int> searchPages;
  final Map<String, int> searchOffsets;
  final bool manjuSearchExhausted;
  final bool mangaSearchExhausted;
  final bool searchCanAdvance;
  final bool recommendExhausted;
  final bool hasMore;

  const _FetchedFeed({
    required this.items,
    required this.nextOffset,
    required this.sessionId,
    required this.searchPage,
    this.searchPages = const {},
    this.searchOffsets = const {},
    this.manjuSearchExhausted = false,
    this.mangaSearchExhausted = false,
    this.searchCanAdvance = false,
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

/// The manju group of the combined feed, with the search cursor state that
/// continues it once the uncursored recommendation stream runs out.
typedef _AllManjuGroup = ({
  List<MediaItem> items,
  int? searchOffset,
  bool searchCanAdvance,
  bool searchExhausted,
  bool hasMore,
});

/// Loads and pages the homepage feeds. Each async operation captures its tab
/// and feed before the first await, so switching tabs can never redirect a
/// late response into a different tab's cache.
class HomeNotifier extends Notifier<HomeState> {
  static const tabs = ['全部', '小说', '短剧', '漫剧', '漫画', '听书', '视频'];
  static const tabKinds = {
    '小说': 'book',
    '短剧': 'video',
    '漫剧': 'manju',
    '漫画': 'manga',
    '听书': 'audio',
    // The 短剧 tab's 推荐 channel. `BookstoreTabType.video_feed = 16`; the
    // bookstore strip happens to label 16 「视频」, while the seriesmall tab
    // shows the same feed under 「推荐」 (用户截图与 ap3.xml 的兜底名都如此).
    '视频': 'video',
  };
  static const tabTypes = {
    '小说': 2,
    '短剧': 8,
    '漫剧': 24,
    '听书': 5,
    '视频': 16,
  };

  final HomepageLoader _homepageLoader;
  final SearchTabsLoader _searchLoader;
  final CategorySearchLoader _mangaSearchLoader;
  final CategorySearchLoader _manjuSearchLoader;
  final HomeFeedCache? _feedCache;
  final int initialTabIndex;

  HomeNotifier({
    HomepageLoader? homepageLoader,
    SearchTabsLoader? searchLoader,
    CategorySearchLoader? mangaSearchLoader,
    CategorySearchLoader? manjuSearchLoader,
    HomeFeedCache? feedCache,
    this.initialTabIndex = 0,
  }) : _feedCache = feedCache ?? HomeFeedCache.instance,
       _homepageLoader = homepageLoader ?? ApiClient.instance.homepagePage,
       _searchLoader = searchLoader ?? ApiClient.instance.searchTabs,
       _mangaSearchLoader =
           mangaSearchLoader ??
           (searchLoader == null
               ? _searchManga
               : ({int offset = 0}) =>
                     searchLoader('漫画', page: offset ~/ 10 + 1)),
       _manjuSearchLoader =
           manjuSearchLoader ??
           (searchLoader == null
               ? _searchManju
               : ({int offset = 0}) =>
                     searchLoader('漫剧', page: offset ~/ 10 + 1));

  static Future<List<SearchTab>> _searchManga({int offset = 0}) =>
      ApiClient.instance.searchTabs('漫画', tabType: 8, offset: offset);

  static Future<List<SearchTab>> _searchManju({int offset = 0}) =>
      ApiClient.instance.searchTabs('漫剧', tabType: 11, offset: offset);

  Future<List<SearchTab>> _searchByType(
    String name, {
    int page = 1,
    int offset = 0,
  }) => switch (name) {
    '漫画' => _mangaSearchLoader(offset: offset),
    '漫剧' => _manjuSearchLoader(offset: offset),
    _ => _searchLoader(name, page: page),
  };

  final Map<int, _TabFeed> _feeds = {};
  int _generation = 0;

  /// In-flight feed request. Cancelled when a newer load supersedes it, when
  /// the tab changes, and on dispose, so leaving the page stops the upstream
  /// work instead of only ignoring its result.
  BackendRequest? _activeRequest;

  /// The category this feed opens on. The home page starts on 全部; a page that
  /// is locked to one channel starts on that channel and never shows the strip.
  @override
  HomeState build() {
    ++_generation;
    // Leaving the page (or rebuilding the provider) stops whatever is in
    // flight instead of only ignoring its result.
    ref.onDispose(() => _activeRequest?.cancel());
    _activeRequest?.cancel();
    _feeds.clear();
    return HomeState(tabIndex: initialTabIndex);
  }

  _TabFeed _feedFor(int tabIndex) => _feeds.putIfAbsent(tabIndex, _TabFeed.new);

  /// Reloads the selected tab from page one.
  ///
  /// A manual refresh (pull-to-refresh, error retry) always replaces the list
  /// (official `SaasClientReqType.Refresh` path). A background first load may
  /// resume from the snapshot's last viewed card: the list is trimmed to start
  /// at that card and the network response is appended after it, so the video
  /// on screen never flips to a different one (official landing-cache flow,
  /// `Se` → `sf(listOf(cache))` + `Te` → `uf` append).
  Future<void> load({bool manualRefresh = false}) async {
    final tabIndex = state.tabIndex;
    final generation = ++_generation;
    final feed = _feedFor(tabIndex)..reset();
    // Stale-while-revalidate: show the last rendered cards while the network
    // refresh runs. The cursors stay reset, so the response replaces page one.
    final snapshot = manualRefresh ? null : _feedCache?.load(tabIndex);
    if (snapshot != null) {
      final resumeIndex = snapshot.lastVid == null
          ? -1
          : snapshot.items.indexWhere((item) => item.id == snapshot.lastVid);
      if (resumeIndex > 0) {
        // Resume from the card the user was last on: earlier cards are
        // dropped, matching the official single-video landing cache.
        feed.items = snapshot.items.sublist(resumeIndex);
        feed.resumedVid = snapshot.lastVid;
        // Seed the reported position too: if the user never swipes this
        // session, the next save keeps the same resume point.
        feed.lastVid = snapshot.lastVid;
      } else if (resumeIndex == 0) {
        // Resume point is already the first card; nothing to trim, but the
        // response must still append instead of replacing the visible card.
        feed.resumedVid = snapshot.lastVid;
        feed.lastVid = snapshot.lastVid;
        feed.items = snapshot.items;
      } else {
        // No resume point (or it fell out of the snapshot): show the full
        // snapshot and let the response replace it wholesale, as before.
        feed.items = snapshot.items;
      }
      if (feed.resumedVid != null) {
        // Every snapshot card counts as seen (the client-side equivalent of
        // the official `filterIds` request parameter): a fresh response that
        // still contains them is deduplicated away on append.
        for (final item in snapshot.items) {
          if (item.id.isNotEmpty) feed.seen.add('${item.kind}:${item.id}');
        }
      }
    }
    state = state.copyWith(
      items: feed.items,
      isLoading: true,
      isLoadMore: false,
      hasMore: true,
      clearError: true,
    );

    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();

    try {
      final fetched = await ApiClient.instance.withCancellation(
        request,
        () => _loadInitial(tabIndex),
      );
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
        final resume = feed.resumedVid != null;
      feed.resumedVid = null;
      _applyFetched(feed, fetched, replace: !resume);
      state = state.copyWith(
        items: feed.items,
        isLoading: false,
        isLoadMore: false,
        hasMore: feed.hasMore,
      );
      // 上报只在翻页时发生：看第一张卡没滑动就没有 lastVid——兜底用
      // 当前列表首卡（它就是本次会话实际展示的第一张），让续接链在
      // 下一次冷启动成立。
      final savedVid = feed.lastVid ?? (feed.items.isEmpty ? null : feed.items.first.id);
      unawaited(
        _feedCache?.save(
          tabIndex,
          feed.items,
          hasMore: feed.hasMore,
          lastVid: savedVid,
        ),
      );
    } catch (error) {
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      feed.hasMore = false;
      // The seeded snapshot (or nothing, on a cold start) stays on screen;
      // the error surface only takes over when there is nothing to show.
      state = state.copyWith(
        error: userFacingError(error),
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
    _activeRequest?.cancel();
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

    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();

    try {
      final fetched = await ApiClient.instance.withCancellation(
        request,
        () => _loadNext(tabIndex, feed),
      );
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
      final savedVid = feed.lastVid ?? (feed.items.isEmpty ? null : feed.items.first.id);
      unawaited(
        _feedCache?.save(
          tabIndex,
          feed.items,
          hasMore: feed.hasMore,
          lastVid: savedVid,
        ),
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

  /// Records the card currently on screen so the next snapshot save can store
  /// the resume point. The page reports this as the user swipes.
  void noteCurrentVid(String vid) {
    if (vid.isEmpty) return;
    _feedFor(state.tabIndex).lastVid = vid;
  }

  Future<_FetchedFeed> _loadInitial(int tabIndex) async {
    final name = tabs[tabIndex];
    if (name == '全部') return _loadAllInitial();

    final kind = tabKinds[name]!;
    final tabType = tabTypes[name];
    if (tabType != null) {
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
    }

    final search = await _searchByType(name);
    final items = _searchItems(search, name, kind);
    final progress = _searchProgress(search, name, items, offset: 0);
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: null,
      searchPage: 1,
      searchOffsets: {
        if (progress.nextOffset != null) name: progress.nextOffset!,
      },
      searchCanAdvance: progress.hasCursor,
      recommendExhausted: true,
      hasMore: progress.hasMore,
    );
  }

  /// "全部" combines the novel recommendation stream with first pages for
  /// the other supported categories.
  Future<_FetchedFeed> _loadAllInitial() async {
    final recommendationFuture = _attempt(_loadInitial(1));
    final videoFuture = _attempt(_searchLoader('短剧'));
    final manjuFuture = _attempt(_loadAllManju());
    final mangaFuture = _attempt(_mangaSearchLoader());
    final audioFuture = _attempt(_searchLoader('听书'));

    final recommendation = await recommendationFuture;
    final video = await videoFuture;
    final manju = await manjuFuture;
    final manga = await mangaFuture;
    final audio = await audioFuture;
    if (recommendation.value == null &&
        video.value == null &&
        manju.value == null &&
        manga.value == null &&
        audio.value == null) {
      throw recommendation.error ??
          video.error ??
          manju.error ??
          manga.error ??
          audio.error ??
          StateError('首页加载失败');
    }

    final manjuGroup = manju.value;
    final manjuItems = manjuGroup?.items ?? const <MediaItem>[];
    final mangaItems = _searchItems(manga.value ?? [], '漫画', 'manga');
    final mangaProgress = _searchProgress(
      manga.value ?? [],
      '漫画',
      mangaItems,
      offset: 0,
    );
    final groups = <List<MediaItem>>[
      if (recommendation.value != null) recommendation.value!.items,
      if (video.value != null) _searchItems(video.value!, '短剧', 'video'),
      manjuItems,
      mangaItems,
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
        if (audio.value != null) '听书': 1,
      },
      searchOffsets: {
        if (manjuGroup?.searchOffset != null) '漫剧': manjuGroup!.searchOffset!,
        if (mangaProgress.nextOffset != null) '漫画': mangaProgress.nextOffset!,
      },
      searchCanAdvance:
          (manjuGroup?.searchCanAdvance ?? false) || mangaProgress.hasCursor,
      manjuSearchExhausted: manjuGroup?.searchExhausted ?? false,
      mangaSearchExhausted: manga.value != null && !mangaProgress.hasMore,
      recommendExhausted: page?.recommendExhausted ?? true,
      hasMore:
          items.isNotEmpty ||
          page?.nextOffset != null ||
          (manjuGroup?.hasMore ?? false) ||
          mangaProgress.hasMore,
    );
  }

  /// The manju group of the combined feed.
  ///
  /// Prefers the dedicated manju stream (`tab_type=24`) over search, for the
  /// same reason the 漫剧 tab already does: the upstream attaches cover badges
  /// to that stream's cards, while search cells carry mostly uncoloured genre
  /// labels. The stream has no page cursor, so search still serves the pages
  /// after the first.
  Future<_AllManjuGroup> _loadAllManju() async {
    try {
      final page = await _homepageLoader(tabType: tabTypes['漫剧']!);
      final items = _forceKind(page.items, 'manju');
      if (items.isNotEmpty) {
        return (
          items: items,
          // Search has not been consulted yet, so paging starts at its first
          // page and there is still a source to advance to.
          searchOffset: 0,
          searchCanAdvance: true,
          searchExhausted: false,
          hasMore: true,
        );
      }
    } catch (_) {
      // Older backends may not expose the stream; fall through to search.
    }
    final tabs = await _manjuSearchLoader();
    final items = _searchItems(tabs, '漫剧', 'manju');
    final progress = _searchProgress(tabs, '漫剧', items, offset: 0);
    return (
      items: items,
      searchOffset: progress.nextOffset,
      searchCanAdvance: progress.hasCursor,
      searchExhausted: !progress.hasMore,
      hasMore: progress.hasMore,
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
    final searchOffset = feed.searchOffsets[name] ?? 0;
    final searchTabs = await _searchByType(
      name,
      page: pageNumber,
      offset: searchOffset,
    );
    final items = _searchItems(searchTabs, name, kind);
    final progress = _searchProgress(
      searchTabs,
      name,
      items,
      offset: searchOffset,
    );
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: feed.sessionId,
      searchPage: pageNumber,
      searchOffsets: {
        ...feed.searchOffsets,
        if (progress.nextOffset != null) name: progress.nextOffset!,
      },
      searchCanAdvance: progress.hasCursor,
      recommendExhausted: true,
      hasMore: progress.hasMore,
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
    final audioPage = (feed.searchPages['听书'] ?? 0) + 1;
    final videoFuture = _attempt(_searchLoader('短剧', page: videoPage));
    final manjuOffset = feed.searchOffsets['漫剧'] ?? 0;
    final manjuFuture = feed.manjuSearchExhausted
        ? Future.value(const _Attempt<List<SearchTab>>.value([]))
        : _attempt(_manjuSearchLoader(offset: manjuOffset));
    final mangaOffset = feed.searchOffsets['漫画'] ?? 0;
    final mangaFuture = feed.mangaSearchExhausted
        ? Future.value(const _Attempt<List<SearchTab>>.value([]))
        : _attempt(_mangaSearchLoader(offset: mangaOffset));
    final audioFuture = _attempt(_searchLoader('听书', page: audioPage));

    final recommendation = await recommendationFuture;
    final video = await videoFuture;
    final manju = await manjuFuture;
    final manga = await mangaFuture;
    final audio = await audioFuture;
    if (recommendation.value == null &&
        video.value == null &&
        manju.value == null &&
        manga.value == null &&
        audio.value == null) {
      throw recommendation.error ??
          video.error ??
          manju.error ??
          manga.error ??
          audio.error ??
          StateError('首页分页失败');
    }

    final manjuItems = _searchItems(manju.value ?? [], '漫剧', 'manju');
    final manjuProgress = _searchProgress(
      manju.value ?? [],
      '漫剧',
      manjuItems,
      offset: manjuOffset,
    );
    final mangaItems = _searchItems(manga.value ?? [], '漫画', 'manga');
    final mangaProgress = _searchProgress(
      manga.value ?? [],
      '漫画',
      mangaItems,
      offset: mangaOffset,
    );
    final groups = <List<MediaItem>>[
      if (recommendation.value != null) recommendation.value!.items,
      if (video.value != null) _searchItems(video.value!, '短剧', 'video'),
      manjuItems,
      mangaItems,
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
        if (audio.value != null) '听书': audioPage,
      },
      searchOffsets: {
        ...feed.searchOffsets,
        if (manjuProgress.nextOffset != null) '漫剧': manjuProgress.nextOffset!,
        if (mangaProgress.nextOffset != null) '漫画': mangaProgress.nextOffset!,
      },
      searchCanAdvance: manjuProgress.hasCursor || mangaProgress.hasCursor,
      manjuSearchExhausted:
          feed.manjuSearchExhausted ||
          (manju.value != null && !manjuProgress.hasMore),
      mangaSearchExhausted:
          feed.mangaSearchExhausted ||
          (manga.value != null && !mangaProgress.hasMore),
      recommendExhausted:
          recommendationPage?.recommendExhausted ?? feed.recommendExhausted,
      hasMore:
          items.isNotEmpty ||
          (recommendationPage != null &&
              recommendationPage.nextOffset != null) ||
          manjuProgress.hasMore ||
          mangaProgress.hasMore,
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
      ..searchOffsets = fetched.searchOffsets
      ..manjuSearchExhausted = fetched.manjuSearchExhausted
      ..mangaSearchExhausted = fetched.mangaSearchExhausted
      ..recommendExhausted = fetched.recommendExhausted
      ..hasMore = fetched.hasMore
      ..loaded = true;

    // If a page contained only duplicates and no source has a known cursor,
    // stop cleanly instead of repeatedly requesting the same page.
    if (!replace &&
        fresh.isEmpty &&
        fetched.nextOffset == null &&
        !fetched.searchCanAdvance) {
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
    searchTabs = separateManjuSearchTabs(searchTabs);
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

  // Note: 首页漫画与漫剧都保留 v1 搜索游标，重复页不等于结束；见
  // .agents/notes/implemented/bug-fix/2026-09-10-search-categories.md
  ({bool hasMore, int? nextOffset, bool hasCursor}) _searchProgress(
    List<SearchTab> tabs,
    String label,
    List<MediaItem> items, {
    required int offset,
  }) {
    if (label != '漫剧' && label != '漫画') {
      return (hasMore: items.isNotEmpty, nextOffset: null, hasCursor: false);
    }
    for (final tab in separateManjuSearchTabs(tabs)) {
      if (tab.title != label ||
          (tab.hasMore == null && tab.nextOffset == null)) {
        continue;
      }
      final next = tab.nextOffset;
      final advances = tab.hasMore != false && next != null && next > offset;
      return (
        hasMore: advances,
        nextOffset: advances ? next : null,
        hasCursor: advances,
      );
    }
    // Compatibility with loaders lacking cursor metadata. The dedicated
    // category search requests ten results; known upstream cursors win above.
    return (
      hasMore: items.isNotEmpty,
      nextOffset: items.isEmpty ? null : offset + 10,
      hasCursor: false,
    );
  }

  List<MediaItem> _forceKind(List<MediaItem> items, String kind) {
    // copyWith rather than a hand-written rebuild: rebuilding by hand dropped
    // the cover badge (and would drop any future field) on every home tab.
    return items
        .where((item) => item.kind != 'manju' || kind == 'manju')
        .map((item) => item.copyWith(kind: kind))
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

// Note: 底部导航的短剧目的地用第二个 HomeNotifier 实例而不是复用 homeProvider，
// 理由与被否掉的方案见
// .agents/notes/implemented/feature/2026-09-20-bottom-short-drama-tab.md

/// Index of 短剧 inside [HomeNotifier.tabs].
final dramaTabIndex = HomeNotifier.tabs.indexOf('短剧');

/// The bottom navigation's 短剧 destination.
///
/// It is a second instance of the same notifier rather than a category of
/// [homeProvider]: two tabs watching one provider would move together, so
/// switching the home page to 听书 would replace the 短剧 tab's feed as well.
final dramaProvider = NotifierProvider<HomeNotifier, HomeState>(
  () => HomeNotifier(initialTabIndex: dramaTabIndex),
);
