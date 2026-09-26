import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:hive/hive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';

import '../models/book_detail.dart' show formatCounter;
import '../models/channel_tab.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/digg_store.dart';
import '../services/inline_video_playback.dart';

import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/player_history.dart';
import '../services/shelf_store.dart';
import '../services/swipe_guide_store.dart';
import '../services/user_facing_error.dart';
import '../services/media_history_store.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/player/player_video_layout.dart';
import 'detail_page.dart';
import 'home_provider.dart';
import 'player_page.dart';
import 'search_page.dart';

/// One channel of the 短剧 tab.
///
/// The official tab hosts several channels behind one strip and names them from
/// One entry of the 短剧 tab's channel strip.
///
/// The official strip is server-driven (`BookstoreTabData.tabItem[]`, rendered
/// by `m0.java:3051-3106`), but the backend we ship exposes the *bookstore*
/// strip (`/recommend/homepage` returns 推荐/小说/听书/看剧/经典/短篇/知识/漫画/
/// 新书/商城 for tab_type=8), not the seriesmall one, and it has no seriesmall
/// tab route at all. So the five channels below are the official ones by
/// `BookstoreTabType` with their real tab types, and the two that the official
/// client fills from the device — 最近 (recent=18, `r73/m2.java:100-103`) and
/// 收藏 (follow=30, `td4/o1.java:179-193`) — are served from our own history
/// and shelf. 预约 (28) has no data source here and is deliberately absent.
///
/// Note: 频道映射与"为什么不是服务端列表"的完整理由 — 见
/// .agents/notes/implemented/feature/2026-09-20-official-drama-tab.md
enum DramaChannelSource { feed, history, shelf }

class DramaChannel {
  final String label;

  /// Index into [HomeNotifier.tabs] for [DramaChannelSource.feed].
  final int tabIndex;
  final String kind;
  final DramaChannelSource source;

  const DramaChannel({
    required this.label,
    required this.tabIndex,
    required this.kind,
    this.source = DramaChannelSource.feed,
  });

  bool get isFeed => source == DramaChannelSource.feed;
}

final dramaChannels = <DramaChannel>[
  DramaChannel(
    label: '推荐',
    tabIndex: HomeNotifier.tabs.indexOf('视频'),
    kind: 'video',
  ),
  DramaChannel(
    label: '看剧',
    tabIndex: HomeNotifier.tabs.indexOf('短剧'),
    kind: 'video',
  ),
  DramaChannel(
    label: '漫剧',
    tabIndex: HomeNotifier.tabs.indexOf('漫剧'),
    kind: 'manju',
  ),
  const DramaChannel(
    label: '最近',
    tabIndex: 0,
    kind: 'video',
    source: DramaChannelSource.history,
  ),
  const DramaChannel(
    label: '收藏',
    tabIndex: 0,
    kind: 'video',
    source: DramaChannelSource.shelf,
  ),
];

/// 服务端 `tab_type` -> 本地频道（F08：频道表由服务端下发）。
///
/// 官方 `m0.java:3051-3089` 把 `tab_item` 逐条转成频道：名字用服务端 `title`、
/// 类型用 `tab_type`。本地只保留**能真正打开内容**的那些类型；映射不到的类型
/// 返回 null（宁可不显示，也不要放一个点了没反应的频道）。
DramaChannel? serverChannelOf(ChannelTab tab) {
  // 服务端没给名字时用官方同义的中文兜底，避免出现空标签。
  String label(String fallback) => tab.title.trim().isEmpty ? fallback : tab.title;
  switch (tab.type) {
    case kChannelVideoFeed:
      return DramaChannel(
        label: label('推荐'),
        tabIndex: HomeNotifier.tabs.indexOf('视频'),
        kind: 'video',
      );
    case kChannelVideoEpisode:
    case kChannelVideo:
      return DramaChannel(
        label: label('看剧'),
        tabIndex: HomeNotifier.tabs.indexOf('短剧'),
        kind: 'video',
      );
    case kChannelDynamicComic:
      return DramaChannel(
        label: label('漫剧'),
        tabIndex: HomeNotifier.tabs.indexOf('漫剧'),
        kind: 'manju',
      );
    case kChannelRecent:
      return DramaChannel(
        label: label('最近'),
        tabIndex: 0,
        kind: 'video',
        source: DramaChannelSource.history,
      );
    case kChannelFollow:
      return DramaChannel(
        label: label('收藏'),
        tabIndex: 0,
        kind: 'video',
        source: DramaChannelSource.shelf,
      );
    default:
      return null;
  }
}

/// The bottom navigation's 短剧 destination, laid out like the official
/// `SeriesMallFragment`: a full-screen vertical feed of dramas with a floating
/// top bar (search row + channel strip) over it.
///
/// It reads [dramaProvider] rather than [homeProvider], so the home page's own
/// category strip can never move this feed. Layout numbers come from the
/// official 7.0.9.32 layouts (`ap4.xml`, `cjc.xml`, `cjq.xml`, `cjt.xml`,
/// `d6g.xml`, `d62.xml`, `cf_.xml`, `aq0.xml`, `aqi.xml`).
///
/// Note: 官方首屏形态与卡片尺寸的出处 — 见
/// .agents/notes/implemented/feature/2026-09-20-official-drama-tab.md
/// 与 .agents/notes/implemented/feature/2026-09-21-drama-remaining-ui-alignment.md


class DramaPage extends ConsumerStatefulWidget {
  const DramaPage({
    super.key,
    this.directoryLoader,
    this.contentLoader,
    this.playerFactory,
    this.historyStore,
    this.searchPageBuilder,
    this.channelLoader,
  });

  /// Test seams. The official feed plays the on-screen card inline and still
  /// opens the full player from a tap, which needs the series directory first.
  final Future<List<List<Chapter>>> Function(String id, String tab)?
  directoryLoader;
  final Future<Map<String, dynamic>> Function(String itemId, String tab)?
  contentLoader;
  final NativePlayer Function()? playerFactory;
  final ReaderStore? historyStore;
  final Widget Function()? searchPageBuilder;

  /// 服务端频道表加载器（测试缝）。默认走 `ApiClient.channelTabs()`。
  final Future<List<ChannelTab>> Function()? channelLoader;

  @override
  ConsumerState<DramaPage> createState() => _DramaPageState();
}

class _DramaPageState extends ConsumerState<DramaPage>
    with WidgetsBindingObserver {


  static const _searchRowHeight = 38.0;
  static const _stripHeight = 38.0;
  static const _pullRefreshTrigger = 64.0;


  final PageController _pages = PageController();
  int _channel = 0;
  String? _openingId;

  /// 当前生效的频道条。默认是本地表；拉到服务端频道表后按服务端配置替换
  /// （F08 要求「不以静态频道表替代动态配置」）。
  List<DramaChannel> _channels = dramaChannels;

  /// 是否已经尝试过服务端频道表（避免重复请求）。
  bool _channelsRequested = false;

  /// Index of the page the viewer is on, the only card that may mount a
  /// texture.
  int _screenIndex = 0;

  /// True between the feed's scroll start and end notifications.
  bool _paging = false;

  /// Whether the containing route still shows this page (TickerMode). The bottom
  /// bar mutes a hidden destination instead of unmounting it.
  bool _tickerEnabled = true;

  /// True while a route we pushed is on top of the feed.
  bool _modalOpen = false;
  bool _syncScheduled = false;

  /// Downward overscroll on the first card, in logical pixels. Official
  /// `aq0.xml` shows 「下拉刷新内容」 (`@string/dhk`) while this is in flight.
  double _pullDistance = 0;

  /// 「上滑查看更多视频」guide（官方 `pp3.f` + `cf_.xml`）。官方行为：
  /// **每台设备只弹一次**（SharedPreferences `series_show_user_guide`，
  /// `wp3/d0.java`），停留约 **8 秒**（`j()` 是 1s 重复计数、`v()` 把计数
  /// 置 8，不是笔记第二轮误读的「1s 后消失」），**300ms 淡入 / 300ms 淡出**，
  /// 频道横滑一开始就立即收起（`onPageScrolled` → `m()`）。
  bool _guideMounted = false;
  bool _guideVisible = false;
  Timer? _guideFadeIn;
  Timer? _guideTick;
  Timer? _guideFadeOut;

  late final InlineVideoPlayback _inline;


  DramaChannel get _current => _channels[_channel];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inline = InlineVideoPlayback(
      directoryLoader: widget.directoryLoader,
      contentLoader: widget.contentLoader,
      playerFactory: widget.playerFactory,
      historyStore: widget.historyStore,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(dramaProvider.notifier).load();
      if (mounted) unawaited(_loadChannels());
      if (mounted) _showGuide();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_inline.dispose());
    _guideFadeIn?.cancel();
    _guideTick?.cancel();
    _guideFadeOut?.cancel();
    _pages.dispose();
    super.dispose();
  }

  /// 拉服务端频道表（F08）。
  ///
  /// 官方频道条由 `data.tab_item` 驱动，所以这里以服务端为准；**但只在
  /// 映射出至少两个频道时替换**——一个频道就能替代整条栏的话，
  /// 网络抖动或半截响应会把用户锁死在单一频道里。取不到就静默保留本地表。
  Future<void> _loadChannels() async {
    if (_channelsRequested) return;
    _channelsRequested = true;
    List<ChannelTab> tabs;
    try {
      tabs = await (widget.channelLoader?.call() ??
          ApiClient.instance.channelTabs());
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final mapped = <DramaChannel>[];
    for (final tab in tabs) {
      final channel = serverChannelOf(tab);
      if (channel != null) mapped.add(channel);
    }
    if (mapped.length < 2) return;
    final previous = _channels.isEmpty ? null : _channels[_channel];
    setState(() {
      _channels = List.unmodifiable(mapped);
      // 频道换了之后下标可能越界：尽量停在「同一条」频道上。
      final index = previous == null
          ? 0
          : _channels.indexWhere(
              (channel) =>
                  channel.label == previous.label &&
                  channel.source == previous.source,
            );
      _channel = index < 0 ? 0 : index;
    });
  }

  /// 进 tab 后弹一次引导。官方在 `onCreateContent` 里 `Ge()`，且被
  /// `!wp3.d0.c()`（本仓库 `SwipeGuideStore`）与频道可见性双重门控；
  /// `onShow()` 一触发就写回标记，之后再也不弹。
  void _showGuide() {
    if (!mounted || _guideMounted) return;
    if (!_current.isFeed) return;
    if (SwipeGuideStore.instance.shown) return;
    unawaited(SwipeGuideStore.instance.markShown());
    setState(() {
      _guideMounted = true;
      _guideVisible = true;
    });
    // 官方 8 次计数从淡入完成（`w()` 在 fade-in 的 withEndAction 里 `j()`）
    // 之后才开始走。
    _guideFadeIn?.cancel();
    _guideFadeIn = Timer(const Duration(milliseconds: 300), () {
      _guideTick?.cancel();
      var ticks = 8;
      _guideTick = Timer.periodic(const Duration(seconds: 1), (_) {
        ticks--;
        if (ticks <= 0) _hideGuide();
      });
    });
  }

  /// 300ms 淡出后从树上摘掉。官方 `t()`：fade-out withEndAction → `x()` remove。
  void _hideGuide() {
    _guideFadeIn?.cancel();
    _guideTick?.cancel();
    if (!_guideMounted || !_guideVisible) return;
    setState(() => _guideVisible = false);
    _guideFadeOut?.cancel();
    _guideFadeOut = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _guideMounted = false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_tickerEnabled && !_modalOpen) {
        _resumeInline();
        _scheduleInlineSync();
      }
    } else {
      // A video must never keep playing from the background.
      unawaited(_inline.pause());
    }
  }

  /// The bottom bar mutes hidden destinations rather than unmounting them, so
  /// the feed has to stop its own playback.
  void _syncTickerMode() {
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled == _tickerEnabled) return;
    _tickerEnabled = enabled;
    if (enabled) {
      _resumeInline();
    } else {
      unawaited(_inline.pause());
    }
  }

  List<MediaItem> _visibleItems(HomeState state) => state.items
      .where((item) => item.kind == _current.kind)
      .toList(growable: false);

  /// The feed reacts to its own builds: items arrive asynchronously, and a
  /// channel switch, a refresh or a returning route can all change what the
  /// on-screen card is.
  void _scheduleInlineSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      _syncInline();
    });
  }

  /// The card the viewer is on, or null when there is nothing to play.
  ///
  /// A local channel (最近 / 收藏) has no feed, and returning null there is what
  /// makes [_syncInline] release the inline player instead of leaving it
  /// decoding behind a list.
  MediaItem? _currentItem() {
    if (!_current.isFeed) return null;
    final items = _visibleItems(ref.read(dramaProvider));
    if (items.isEmpty) return null;
    return items[_screenIndex.clamp(0, items.length - 1)];
  }

  void _syncInline() {
    // A refresh that swaps the feed out mid-drag never sends ScrollEnd, so the
    // latch is also cleared whenever the pager is demonstrably idle.
    final scrolling =
        _pages.hasClients && _pages.position.isScrollingNotifier.value;
    if (_paging && !scrolling) _paging = false;
    if (!mounted || !_tickerEnabled || _modalOpen || _paging) return;
    // Never start a video under the full page player's loading overlay.
    if (_openingId != null) return;
    final item = _currentItem();
    if (item == null) {
      // Nothing to play on this page: `release()` parks the current player, so
      // a drama the viewer swipes back to is still in the pool.
      if (_inline.activeId.value != null) unawaited(_inline.release());
      return;
    }
    // The session sets its target synchronously, so a card that is already
    // playing (or starting) is never kicked off again.
    if (_inline.activeId.value == item.id) return;
    unawaited(_inline.activate(item));
  }

  void _selectChannel(int index) {
    if (index == _channel) return;
    final channel = _channels[index];
    // 官方横向频道 pager 一滚动就收起引导（`onPageScrolled` → `pp3.f.m()`）；
    // 这里的等价动作是切频道。
    _hideGuide();
    setState(() {
      _channel = index;
      _screenIndex = 0;
    });
    // Local channels read this device's own data; switching the provider would
    // silently load a feed nobody asked for.
    if (channel.isFeed) {
      ref.read(dramaProvider.notifier).selectTab(channel.tabIndex);
    } else {
      // A local channel has no video: destroy the player and empty the pool.
      unawaited(_inline.releaseAll());
    }
    if (_pages.hasClients) _pages.jumpToPage(0);
  }

  /// A vertical drag pauses first: the new card may only start after the feed
  /// settles, otherwise two episodes overlap during the swipe.
  ///
  /// Official refresh is a pull-down on the first page (`aq0.xml`
  /// `PullToRefreshDetectLayout` + `@string/dhk`=「下拉刷新内容」), not the
  /// 20dp search icon. Overscroll on page 0 is therefore consumed here.
  bool _onFeedScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is OverscrollNotification &&
        _screenIndex == 0 &&
        notification.overscroll < 0) {
      setState(() {
        _pullDistance = (_pullDistance - notification.overscroll).clamp(
          0,
          _pullRefreshTrigger,
        );
      });
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        _pullDistance > 0 &&
        (notification.scrollDelta ?? 0) > 0) {
      setState(() {
        _pullDistance = (_pullDistance - notification.scrollDelta!).clamp(
          0,
          _pullRefreshTrigger,
        );
      });
    }
    if (notification is ScrollStartNotification) {
      _paging = true;
      unawaited(_inline.pause());
    } else if (notification is ScrollEndNotification) {
      final shouldRefresh = _pullDistance >= _pullRefreshTrigger;
      if (_pullDistance > 0) {
        setState(() => _pullDistance = 0);
      }
      if (shouldRefresh) {
        unawaited(_refresh());
      }
      _paging = false;
      // A drag that snaps back to the same card only needs its playback back;
      // a drag that landed elsewhere starts the new card.
      if (_currentItem()?.id == _inline.activeId.value) {
        _resumeInline();
      } else {
        _syncInline();
      }
    }
    return false;
  }

  Future<void> _refresh() => ref.read(dramaProvider.notifier).load();

  /// 官方单击语义：**暂停 / 继续当前这条视频**，不跳任何界面。
  ///
  /// 唯一的单击监听器是 `jq3/x` 的内部类 `q`（`fp3.f` 子类，注册点
  /// `jq3/x.java:4131`）。`onSingleTapConfirmed`（`:2194-2225`）在未命中
  /// 拖拽/锁屏分支时调用 `x.t7()` → `o.D7()`（`:604-616`，逐个通知
  /// view manager `l()`，全屏管理器 `l()` 就是 `d().pause()`）以及
  /// `o8()`（`:1704-1721`，`isPlaying() → pause()`，否则 `resume()`）。
  /// 全页播放页只由「全屏观看」按钮进入。
  void _togglePlay() {
    final item = _currentItem();
    if (item == null) return;
    // A tap while the feed is still settling, a route is on top, or the full
    // page player is loading must not fight the state machine.
    if (_modalOpen || _paging || _openingId != null) return;
    if (_inline.activeId.value != item.id) {
      unawaited(_inline.activate(item));
      return;
    }
    if (_inline.playing.value) {
      unawaited(_inline.pause());
    } else {
      unawaited(_inline.resume());
    }
  }


  /// Restarting is only allowed while the feed is really the visible surface:
  /// a route may still sit on top of it, a drag may still be in flight, or the
  /// full page player may be loading.
  void _resumeInline() {
    if (_modalOpen || _paging || _openingId != null) return;
    if (_currentItem()?.id == _inline.activeId.value) {
      unawaited(_inline.resume());
    } else {
      _syncInline();
    }
  }

  /// Any route pushed over the feed stops the video; the feed restarts it when
  /// the route pops and the page is visible again.
  Future<void> _pushOverFeed(Future<void> Function() push) async {
    // Destroyed rather than parked: the route on top can start a player of its
    // own (查看剧集 → detail → 选集 pushes the full page player), and two
    // native players must never be alive at the same time. The pool is emptied
    // for the same reason.
    await _inline.disposePlayer();
    if (!mounted) return;
    _modalOpen = true;
    try {
      await push();
    } finally {
      _modalOpen = false;
      if (mounted && _tickerEnabled) _resumeInline();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dramaProvider);
    final channel = _current;
    final items = _visibleItems(state);
    _syncTickerMode();
    _scheduleInlineSync();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            // 最近 and 收藏 are lists in the official client too: the recent
            // list comes from the device's own history and the follow list from
            // the account, so neither is a video feed here either.
            child: channel.isFeed
                ? _feed(state, items)
                : _LocalList(channel: channel, onOpen: _openDetail),
          ),
          if (_pullDistance > 0)
            Positioned(
              top: MediaQuery.paddingOf(context).top +
                  _searchRowHeight +
                  _stripHeight +
                  8,
              left: 0,
              right: 0,
              child: _PullRefreshHint(
                armed: _pullDistance >= _pullRefreshTrigger,
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              channels: _channels,
              selected: _channel,
              onSelect: _selectChannel,
              onSearch: _openSearch,
            ),
          ),
          // 「上滑查看更多视频」：官方挂在全屏容器上、`gravity=bottom|center`
          // + bottomMargin 94dp（`pp3.f.n()`）。注意官方主界面（`d5.xml`）的
          // 底部 tab（50dp）是**悬浮压在 feed 上的**，所以 94dp 从 tab 底边算，
          // 提示悬在 tab 栏上方约 44dp。本页 feed 止步于 NavigationBar 顶边，
          // 同一视觉位置 = 94 - 官方 tab 高 50 = **44dp**。
          if (_guideMounted)
            Positioned(
              left: 16,
              right: 16,
              bottom: 44,
              child: _SwipeUpHint(visible: _guideVisible),
            ),
        ],
      ),
    );
  }

  Widget _feed(HomeState state, List<MediaItem> items) {
    if (state.error != null) {
      return _FeedMessage(
        key: const Key('drama_error'),
        message: '网络异常，请稍后再试',
        actionLabel: '点击重试',
        onAction: _refresh,
      );
    }
    if (items.isEmpty) {
      if (state.isLoading || state.hasMore) {
        return const _FeedMessage(message: '正在刷新内容', showSpinner: true);

      }
      // Official single-column feed logs + hides loading on an empty list
      // (`SeriesBookMallTabFragment`); it has no dedicated empty card. The
      // copy `@string/d0n` still exists as a shared empty string, so the
      // page shows that and nothing else.
      return const _FeedMessage(
        key: Key('drama_empty'),
        message: '暂无符合条件的短剧',
      );
    }


    return NotificationListener<ScrollNotification>(
      onNotification: _onFeedScroll,
      child: PageView.builder(
        key: const Key('drama_feed'),
        controller: _pages,
        scrollDirection: Axis.vertical,
        itemCount: items.length,
        onPageChanged: (index) {
          // The page that owns the texture is decided by `_screenIndex`, so it
          // has to go through setState: without it the card list is never
          // rebuilt, `video` stays on the first page and every page after it
          // keeps showing its cover even though the session has already
          // switched to the new drama.
          setState(() => _screenIndex = index);

          // Two cards of runway, so a swipe never lands on an empty page.
          if (index >= items.length - 2) {
            ref.read(dramaProvider.notifier).loadMore();
          }
          // Only after the drag settles: starting mid-swipe would overlap the
          // episode the finger is still covering.
          if (!_paging) _syncInline();
        },
        itemBuilder: (context, index) {
          final item = items[index];
          // Only the card on screen may own a texture. The layer itself waits
          // for this drama to be the session's target.
          final onScreen = index == _screenIndex;
          // The follow state comes from the store, so it is read through the
          // store's own listenable: a 追剧 tap must flip the button immediately,
          // and a removal from the shelf page must flip it back here too.
          // Both the follow state and the like come from stores, so they are read
          // through each store's own listenable: a 追剧 / 点赞 tap must flip its
          // button immediately, and a removal elsewhere must flip it back.
          return ValueListenableBuilder<int>(
            valueListenable: ShelfStore.instance.listenable,
            builder: (context, _, _) => ValueListenableBuilder<int>(
              valueListenable: DiggStore.instance.listenable,
              builder: (context, _, _) => _DramaFeedCard(
                item: item,
                opening: _openingId == item.id,
                followed: ShelfStore.instance.containsItem(item),
                liked: DiggStore.instance.containsItem(item),
                playback: onScreen ? _inline : null,
                video: onScreen
                    ? _InlineVideoLayer(item: item, playback: _inline)
                    : null,
                errorOverlay: onScreen
                    ? _InlineVideoError(
                        item: item,
                        playback: _inline,
                        onRetry: () => unawaited(_inline.activate(item)),
                      )
                    : null,
                // 全屏观看 = 唯一进全页播放器的入口；单击画面只切播放/暂停。
                onFullscreen: () => _openPlayer(item),
                onTogglePlay: _togglePlay,
                onFollow: () => _toggleFollow(item),
                onLike: () => _toggleLike(item),

              ),
            ),
          );
        },
      ),
    );
  }

  /// The official card opens the play page directly
  /// (`VideoInfiniteHolderV3` → `ShortSeriesLaunchArgs`), so the directory is
  /// fetched here and the player is pushed with the resume episode selected.
  Future<void> _openPlayer(MediaItem item) async {
    if (_openingId != null) return;
    setState(() => _openingId = item.id);
    // The full page player creates its own native instance, so the inline one
    // has to be gone — and its release awaited — before the route is pushed.
    // `disposePlayer` (not `release`) frees it instead of parking it, so the
    // pool cannot keep a second decoder alive across the push.
    await _inline.disposePlayer();
    if (!mounted) return;
    _modalOpen = true;
    final contentId = item.seriesId ?? item.id;
    final tab = item.kind == 'manju' ? '漫剧' : '短剧';
    try {
      final loader = widget.directoryLoader;
      // `tab` is a named parameter of the client, so the real call passes it by
      // name; a positional tear-off would degrade into a dynamic call.
      var volumes = loader != null
          ? await loader(contentId, tab)
          : await ApiClient.instance.directoryChapters(contentId, tab: tab);
      if (volumes.isEmpty && item.episodeId != null) {
        // A search result can be a single episode rather than a whole series.
        volumes = [
          [
            Chapter(
              itemId: item.episodeId!,
              title: item.title,
              volumeName: '剧集',
            ),
          ],
        ];
      }
      final eps = volumes.expand((volume) => volume).toList(growable: false);
      if (eps.isEmpty) throw const ApiException('剧集列表暂时无法加载');
      final saved = await PlayerHistory(LibraryStore.instance).load(contentId);
      final index = (resumeEpisodeIndex(saved, eps) ?? 0).clamp(
        0,
        eps.length - 1,
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            bookId: contentId,
            kind: item.kind,
            title: item.title,
            cover: item.cover,
            eps: eps,
            startIndex: index.toInt(),
            // 官方「观看全集」进播放器**不弹选集面板**：goToSingleFeed 虽然
            // setLaunchCatalogPanel(true)，但消费端 catalogdialog/v2/k.q0()
            // 被 AB `series_view_show_auto`（默认 enabled=false）门住——
            // 默认进播放器续当前集，选集入口是底部目录条（更正 §22）。
            // 进度不需要显式传——上面的 `disposePlayer()` 已把 feed 的
            // 当前集与播放进度写进历史，PlayerPage 从同一条历史续播。
            shortSeries: true,
            // 播放页沉浸式信息层（官方截图）：右栏追剧计数、AI 声明行、
            // 追剧/点赞写本地 store（feed 右栏同一条链路）。
            followerCount: item.followerCount,
            aiGenerated: item.aiGenerated,
            onFollow: () => unawaited(_toggleFollow(item)),
            onLike: () => unawaited(_toggleLike(item)),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingError(error))));
      }
    } finally {
      _modalOpen = false;
      if (mounted) {
        setState(() => _openingId = null);
        // Coming back to the same card restarts it; a swipe while the player
        // was open targets the newest on-screen card instead.
        _syncInline();
      }
    }
  }

  void _openDetail(MediaItem item) {
    unawaited(
      _pushOverFeed(
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => DetailPage(item: item)),
        ),
      ),
    );
  }

  Future<void> _toggleFollow(MediaItem item) async {
    if (!ShelfStore.instance.isReady) return;
    final followed = await ShelfStore.instance.toggle(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(followed ? '已追剧，可在「书架-短剧」查看' : '已取消追剧')),
    );
  }

  /// 官方「点赞」(`SeriesDiggView`, 右侧栏第二项)：成功后 toast
  /// 「点赞成功，可在「我的-我的点赞」查看」(`@string/bzl`)，取消时
  /// 「已赞，可在[我的-赞过的短剧]中查看」(`@string/bzk`) 的反向。
  /// 本仓库没有账号侧点赞接口，因此只保存状态（见 DiggStore 的说明）。
  Future<void> _toggleLike(MediaItem item) async {
    if (!DiggStore.instance.isReady) return;
    final liked = await DiggStore.instance.toggle(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(liked ? '点赞成功，可在「我的-我的点赞」查看' : '已取消点赞'),
      ),
    );
  }

  void _openSearch() {
    unawaited(
      _pushOverFeed(
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                widget.searchPageBuilder?.call() ?? const SearchPage(),
          ),
        ),
      ),
    );
  }
}

/// The floating top bar: a 44dp search row over a 38dp channel strip, both on a
/// light scrim so the official black-on-white text stays readable over video.
class _TopBar extends StatelessWidget {
  final List<DramaChannel> channels;
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;

  const _TopBar({
    required this.channels,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    // 官方 `ap4.xml` 根背景 `@color/ba9`=@null：整个顶栏**透明**，直接压在
    // 全屏视频流上（截图里频道条后面就是黑底画面）。xml 里的白色 ViewStub
    // `dad.xml` 不是渐变条，是 `BookstoreHeaderBgView`——书城频道的**每频道
    // 一张 CDN 头图**分页（`app:fh="1.0 0.0"` 只是头图自身的淡出），且受
    // `SearchBoxStyleOpt` 门控；短剧 feed 上没有它。文字用白色系与深色背景
    // 对比（截图：选中「推荐」白字加粗，未选中半透明白）。
    return SafeArea(
      bottom: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Official compressed header `ap4.xml`: search row is 38dp,
          // `marginStart/End` 16dp, no `paddingTop` (that 6dp belongs to
          // uncompressed `ap3.xml`).
          SizedBox(
            height: _DramaPageState._searchRowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // 官方 `ap4.xml` 的搜索行 38dp、框体 36dp（`c5e.xml` `@dimen/zl`），
              // 垂直居中。
              child: Center(child: _searchField(context)),
            ),
          ),

          SizedBox(
            height: _DramaPageState._stripHeight,
            child: Row(
              children: [
                Expanded(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: channels.length,
                    itemBuilder: (context, index) => _ChannelTab(
                      label: channels[index].label,
                      selected: index == selected,
                      onTap: () => onSelect(index),
                    ),
                  ),
                ),
                // 官方 `ap3.xml` 的 `@id/h4f`：频道条右端一枚 20×20dp 图标，
                // 右边距 16dp（`layout_marginEnd`），点击进搜索
                // （`SeriesMallFragment.Xh()` 把 `clickEvent(this.i)` 接到
                // `Of(...)` → `openBookSearchActivity`）。它**不是刷新按钮**：
                // 官方刷新是下拉手势（频道页 `aq0.xml` 的
                // `PullToRefreshDetectLayout` ＋「下拉刷新内容」`@string/dhk`）。
                IconButton(
                  key: const Key('drama_strip_search_button'),
                  tooltip: '搜索短剧',
                  onPressed: onSearch,
                  iconSize: 20,
                  color: Colors.white,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 20,
                    height: 20,
                  ),
                  icon: const Icon(LucideIcons.search),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    // 官方搜索框（`SearchWordDisplayView` inflate `c5e.xml`）：高 36dp
    // （`@dimen/zl`）、圆角 8dp（`ViewOutlineProvider.setRoundRect(…, 8f)` +
    // `setClipToOutline`）、图标 12dp 距左 16dp、文字距图标 8dp。配色取官方
    // **暗色皮肤**变体（用户设备官方即暗色）：底
    // `skin_color_search_bar_bg_v2_dark`=#1C1C1C、提示 14sp
    // `skin_color_search_bar_text_v2_dark`=#66FFFFFF（服务端 cue word 态更亮，
    // `skin_color_search_word_dark`=#99FFFFFF）、图标 `…_optimize_dark`。
    return Semantics(
      button: true,
      label: '搜索短剧',
      child: GestureDetector(
        key: const Key('drama_search_button'),
        onTap: onSearch,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1C),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.only(left: 16),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: Image.asset(
                  'assets/images/drama/search.webp',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '请输入短剧名或主演名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: Color(0x66FFFFFF)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tab of the channel strip: 18sp label with a 3dp indicator under it.
///
/// The strip floats over the video feed (`ap4.xml` 根背景 @null)，文字用白色系：
/// 选中纯白加粗、未选中半透明白（官方 `app:aui/avn` 指向的
/// `skin_color_black_light` 是皮肤资源，截图里短剧 feed 上呈现为深色背景上
/// 的白字，与皮肤暗色变体一致）。
class _ChannelTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChannelTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          // 官方 `ap3.xml`：tab 内边距 `app:avb` = 16dp（TabCompress 开）／20dp（关），
          // 文字 18sp（`app:avq`/`app:av5`）。这里取压缩态 16dp。
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected
                        ? Colors.white
                        : const Color(0x99FFFFFF),
                  ),
                ),
                // 官方指示条：高 `app:arw` = 3dp、宽 `app:auw` = 16dp（`ap3.xml`），
                // 在 `SlidingTabLayout.E()` 里按 tab 中心对齐。
                const SizedBox(height: 3),
                Container(
                  width: 16,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One full-screen card of the feed, matching the official `cjc.xml` holder.
///
/// `video` replaces the card's cover on the page the viewer is on: the inline
/// session owns that rectangle, and only one card ever receives it.
///
/// Layout of the official card (`cjc.xml` + the layers `o.java` injects):
/// - the video plane is a 12dp-rounded `RoundFrameLayout`;
/// - a RIGHT RAIL (`cjq.xml`) holds 追剧 / 点赞 (评论 and 分享 ship `gone` in the
///   official layout, so they are not shown here either);
/// - a seek bar (`cjt.xml`, 16dp) sits at the bottom;
/// - a bottom info line (`cj3.xml`/`d6g.xml`) is the drama title at 16sp bold
///   plus an 8×16dp arrow and, when known, an episode label;
/// - a `VideoGestureDetectLayout` covers the middle for double-tap and
///   long-press.
///
/// Note: 右侧栏/进度条/信息层的官方数值出处 —
/// docs/research/short-drama-decompile-comparison-20260921.md §8
class _DramaFeedCard extends StatelessWidget {
  final MediaItem item;
  final bool opening;
  final bool followed;
  final bool liked;
  final Widget? video;
  final Widget? errorOverlay;
  final InlineVideoPlayback? playback;
  final VoidCallback? onFullscreen;
  final VoidCallback onTogglePlay;
  final VoidCallback onFollow;
  final VoidCallback onLike;


  const _DramaFeedCard({
    required this.item,
    required this.opening,
    required this.followed,
    required this.liked,
    this.video,
    this.errorOverlay,
    this.playback,
    this.onFullscreen,
    required this.onTogglePlay,
    required this.onFollow,
    required this.onLike,
  });


  /// Whether the viewer may drive this card: only the on-screen page owns the
  /// player, so only it shows a seek bar (and only it reacts to gestures).
  bool get _interactive => playback != null;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // 官方 `cjc.xml`（预加载表 `ci3.a` 命名 `short_series_single_holder`，就是短剧底
        // tab 的单列卡）：视频面是一个 `RoundFrameLayout`，圆角 `app:a0t` → `@dimen/a1t`
        // = 12dp。它的兄弟变体 cj9/cj_/cja/cjb 都没写圆角属性，所以 12dp 只属于这张卡。
        // 只包视频面本身：官方的信息层是它的**兄弟**（`o.java` 把 H3 = `@id/h_b` 加在根
        // RelativeLayout 上），同样不被裁。
        // 官方同处还有 `layout_marginBottom="@dimen/a5r"` = 92dp，那是给它**自己的**底部
        // 导航让位；本页的 `NavigationBar` 挂在 Scaffold body 之外、已经占掉那一段，
        // 再留一次会凭空多出 92dp 空白，故不重复。
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child:
              video ??
              StoryCover(
                item: item,
                cacheWidth: (size.width * pixelRatio).ceil(),
                alignment: Alignment.topCenter,
              ),
        ),
        // 官方 `cjk.xml`：底部 **280dp** 高的渐变遮罩，`@drawable/yp` 是
        // `@color/oc`(#01000000) → `@color/ak`(#80000000)、angle 270。
        // 铺满整卡会把封面上半也压暗，所以只盖底部 280dp。
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 280,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x01000000), Color(0x80000000)],
              ),
            ),
          ),
        ),
        // 官方 `VideoGestureDetectLayout`（`cjc.xml:7`，`marginTop=70dp` /
        // 官方 `VideoGestureDetectLayout`（`cjc.xml:7`，`marginTop=70dp` /
        // `marginBottom=180dp`）：单击、长按、左右滑动由同一个层转发。
        //
        // **单击 = 播放/暂停当前视频，不跳任何页面。**
        // 官方唯一的单击监听器是 `jq3/x.java` 的内部类 `q`（`fp3.f` 子类），
        // 在 `jq3/x.java:4131` 由 `videoGestureDetectLayout.o(this.V4)` 注册到这张
        // 卡上。它的 `onSingleTapConfirmed`（`:2194-2225`）只做两件事：
        // `x.t7()` → `o.D7()` → 通知各 view manager `l()`（暂停），以及
        // `o8()`（`:1704-1721`，`d().pause()` / `d().resume()`）。
        // 全页播放页只由「全屏观看」(`mq3.e` / `aqi.xml`) 进入。
        Positioned(
          top: 70,
          left: 0,
          right: 0,
          bottom: 180,
          child: _CardGestures(
            key: ValueKey('drama_card_${item.kind}_${item.id}'),
            enabled: _interactive,
            onTap: onTogglePlay,
            onLongPressStart: () => unawaited(playback?.setRate(2.0)),
            onLongPressEnd: () => unawaited(playback?.setRate(1.0)),
            onHorizontalDrag: playback == null
                ? null
                : (fraction) {
                    final total = playback!.duration.value;
                    if (total <= Duration.zero) return;
                    unawaited(
                      playback!.seek(
                        Duration(
                          milliseconds: (total.inMilliseconds * fraction)
                              .round()
                              .clamp(0, total.inMilliseconds),
                        ),
                      ),
                    );
                  },
          ),
        ),
        // Above the card's tap target, so the retry button wins its own taps.
        ?errorOverlay,
        // 官方右侧竖向操作栏（`cjq.xml`，由 `rightview.a` inflate）：
        // 头像 41.5dp（本仓库无账号侧数据，省略）、追剧、点赞（间距 12dp，
        // 图标 46dp、文字 12sp bold、色 `@color/u`=#ccffffff）。追剧按钮下的
        // 文字在有 `followed_cnt` 时就是它（官方截图上是「4.6万」这样的计数）。
        // 官方 XML 里 评论(`c7u`) 与 分享(`hbw`) 默认 `gone`，这里同样不显示。
        // 锚在右下、信息层之上：官方这一栏也是沿右缘靠下排列，且顶部被顶栏
        // 的浮层覆盖（`ap3.xml` 的搜索行与频道条）。
        Positioned(
          right: 4,
          bottom: 64,
          child: _RightRail(
            followed: followed,
            followerCount: item.followerCount,
            liked: liked,
            onFollow: onFollow,
            onLike: onLike,
          ),
        ),
        // 官方进度条（`cjt.xml`）：整条高 16dp、轨道 1.0dip、滑块 1.5dip，
        // 已播 `@color/agn`=#1affffff、底槽 `@color/b8`=#4dffffff，左右 padding 16dp。
        if (playback != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _SeekBar(playback: playback!),
          ),
        // 官方「取消静音」提示（`ck8.xml`，`ShortVideoMuteView`）：圆角 8dp、
        // 底色 `@color/yb`=#66404040，左侧 16dp 图标 + 12sp 白字
        // `@string/e8d`=「取消静音」（开启后 `@string/e8k`=「已开启声音」）。
        // 官方 feed 默认静音起播，所以这一条只在静音时出现。
        if (playback != null)
          Positioned(
            left: 12,
            bottom: 132,
            child: _MuteHint(playback: playback!),
          ),
        // 官方倍速提示（`cjx.xml`）：高 83dp、16sp bold 白字
        // `@string/ec6`=「2倍速快进中」，长按期间显示。
        if (playback != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 180,
            child: _RateHint(playback: playback!),
          ),
        // 官方底部信息层（`cj3.xml` 整体）：最上是居中的「观看全集」药丸行
        // （`nk3.c` inflate `ad9.xml`，在 RelativeLayout 里 CENTER_IN_PARENT），
        // 然后是标题行（`d6g.xml`）、分类 chip 行（`d6f.xml` 的 `hdm`）、
        // 集数简介行（`m6` ShortSeriesExtendTextView）。整块挂在信息槽 `H3` 上。
        Positioned(
          left: 12,
          right: 12,
          bottom: 20,
          child: _InfoPanel(
            item: item,
            playback: playback,
            onOpen: onTogglePlay,
            onFullscreen: onFullscreen,
          ),
        ),

        if (opening)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x8C000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 14),
                    Text(
                      '视频加载中，请稍后',
                      style: TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The official card's tap / long-press / horizontal-seek plane.
///
/// 单击 = 播放/暂停。官方卡上**没有双击手势**：`jq3/x` 注册的监听器
/// （`fp3.f` 子类 `q`）继承了 `SimpleOnGestureListener.onDoubleTap` 的默认实现，
/// 而真正处理双击点赞的是另一条链路（`o.z7` → `lh3.a.onDoubleTap`），本仓库
/// 不实现点赞，所以这里也不注册双击。
///
/// Long-press is a 2× fast-forward held only for the duration of the press:
/// `VideoGestureDetectLayout.onLongPress` forwards to the speed layer, which
/// shows 「2倍速快进中」 (`@string/ec6`, `cjx.xml`) while held. Horizontal
/// drag seeks (`o.java:K6` mounts the drag helper with `bottomMargin=138dp`).
class _CardGestures extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final ValueChanged<double>? onHorizontalDrag;

  const _CardGestures({
    super.key,
    required this.enabled,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    this.onHorizontalDrag,
  });


  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.expand();
    return LayoutBuilder(
      builder: (context, constraints) {
        void seekTo(double dx) {
          final width = constraints.maxWidth;
          if (width <= 0 || onHorizontalDrag == null) return;
          onHorizontalDrag!((dx / width).clamp(0.0, 1.0));
        }

        return GestureDetector(
          key: const Key('drama_card_gestures'),
          // opaque：整块手势区必须自己吃指针，否则下方没有别的接收者，
          // 上滑翻页仍由外层 `PageView` 的竖直拖动竞技场接管。
          behavior: HitTestBehavior.opaque,
          // 没有双击手势了，单击立即派发（不再等双击窗口）。
          onTap: onTap,
          onLongPressStart: (_) => onLongPressStart(),
          onLongPressEnd: (_) => onLongPressEnd(),
          onLongPressCancel: onLongPressEnd,
          onHorizontalDragStart: onHorizontalDrag == null
              ? null
              : (details) => seekTo(details.localPosition.dx),
          onHorizontalDragUpdate: onHorizontalDrag == null
              ? null
              : (details) => seekTo(details.localPosition.dx),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}


/// Official mute hint (`ck8.xml` / `mq3.c`).
///
/// Expanded = 108dp, 16dp icon inset, 12sp 「取消静音」. After 5s it collapses
/// to the 36dp icon (`mq3.c.f(false, true)`). Tapping unmutes; the official
/// follow-up copy is `@string/e8k`=「已开启声音」, shown briefly then gone.
class _MuteHint extends StatefulWidget {
  final InlineVideoPlayback playback;

  const _MuteHint({required this.playback});

  @override
  State<_MuteHint> createState() => _MuteHintState();
}

class _MuteHintState extends State<_MuteHint> {
  bool _expanded = true;
  bool _justUnmuted = false;
  Timer? _collapse;
  Timer? _unmutedHide;

  @override
  void initState() {
    super.initState();
    widget.playback.muted.addListener(_onMute);
    _scheduleCollapse();
  }

  @override
  void dispose() {
    widget.playback.muted.removeListener(_onMute);
    _collapse?.cancel();
    _unmutedHide?.cancel();
    super.dispose();
  }

  void _onMute() {
    if (!mounted) return;
    if (widget.playback.muted.value) {
      setState(() {
        _justUnmuted = false;
        _expanded = true;
      });
      _scheduleCollapse();
      return;
    }
    _collapse?.cancel();
    setState(() {
      _justUnmuted = true;
      _expanded = true;
    });
    _unmutedHide?.cancel();
    _unmutedHide = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _justUnmuted = false);
    });
  }

  void _scheduleCollapse() {
    _collapse?.cancel();
    _collapse = Timer(const Duration(seconds: 5), () {
      if (mounted && widget.playback.muted.value) {
        setState(() => _expanded = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.playback.muted,
      builder: (context, _) {
        final muted = widget.playback.muted.value;
        if (!muted && !_justUnmuted) return const SizedBox.shrink();
        final label = muted ? '取消静音' : '已开启声音';
        return Semantics(
          button: muted,
          label: label,
          child: GestureDetector(
            key: const Key('drama_mute_hint'),
            onTap: muted ? () => unawaited(widget.playback.toggleMute()) : null,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _expanded ? 108 : 36,
              decoration: BoxDecoration(
                color: const Color(0x66404040),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: EdgeInsets.only(
                left: _expanded ? 8 : 10,
                right: 8,
                top: 8,
                bottom: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Image.asset(
                      muted
                          ? 'assets/images/drama/mute_off.webp'
                          : 'assets/images/drama/mute_on.webp',
                      fit: BoxFit.contain,
                    ),
                  ),
                  if (_expanded) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}


/// 官方「2倍速快进中」提示（`cjx.xml`）：高 83dp、黑底 `@color/d_`、
/// 左侧 32dp Lottie + 16sp bold 白字 `@string/ec6`。本仓库没有那份
/// `video_speed_2x_v2.json`，用同尺寸的倍速图标占位，高度与官方一致。
class _RateHint extends StatelessWidget {
  final InlineVideoPlayback playback;

  const _RateHint({required this.playback});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback.rate,
    builder: (context, _) {
      if (playback.rate.value <= 1.0) return const SizedBox.shrink();
      return Center(
        child: SizedBox(
          height: 83,
          child: DecoratedBox(
            key: const Key('drama_rate_hint'),
            decoration: const BoxDecoration(color: Color(0xFF000000)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: Image.asset(
                      'assets/images/drama/fullscreen.webp',
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(width: 9),
                  const Text(
                    '2倍速快进中',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The official right-hand rail (`cjq.xml`).
///
/// Only 追剧 and 点赞 appear: 评论 (`c7u`) and 分享 (`hbw`) ship with
/// `android:visibility="gone"` in the official layout, and the avatar
/// (`ViewStub` → `bk3.xml`) needs account data this app does not have.
/// Item geometry: 46×46dp icon, 12sp bold label in `@color/u`=#ccffffff,
/// 12dp between items.
class _RightRail extends StatelessWidget {
  final bool followed;
  final int followerCount;
  final bool liked;
  final VoidCallback onFollow;
  final VoidCallback onLike;

  const _RightRail({
    required this.followed,
    required this.followerCount,
    required this.liked,
    required this.onFollow,
    required this.onLike,
  });
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _RailButton(
        key: const Key('drama_follow_button'),
        asset: 'assets/images/drama/rail_follow.webp',
        // 官方截图：星标下显示的是追剧人数（如「4.6万」）。没有 followed_cnt
        // 的卡退回「追剧/已追剧」文案。
        label: switch ((followerCount, followed)) {
          (> 0, _) => formatCounter('$followerCount'),
          (_, true) => '已追剧',
          _ => '追剧',
        },
        onTap: onFollow,
      ),
      const SizedBox(height: 12),
      _RailButton(
        key: const Key('drama_like_button'),
        asset: 'assets/images/drama/rail_digg.webp',
        label: liked ? '已赞' : '点赞',
        onTap: onLike,
      ),
    ],
  );
}

class _RailButton extends StatelessWidget {
  final String asset;
  final String label;
  final VoidCallback onTap;

  const _RailButton({
    super.key,
    required this.asset,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: Image.asset(asset, fit: BoxFit.contain),
          ),
          SizedBox(
            width: 46,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.1,
                fontWeight: FontWeight.bold,
                color: Color(0xCCFFFFFF),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The card's seek bar, matching `cjt.xml`.
///
/// Geometry from the layout: the strip is `@dimen/a0f`=16dp tall, the track is
/// `app:abt`=1.0dip with a 1.5dip thumb, horizontal padding is 16dp, the played
/// colour is `@color/agn`=#1affffff and the remaining track `@color/b8`=#4dffffff.
/// Dragging follows `ExpandSeekBarDragFrameLayout`: horizontal only, so the bar
/// never steals the page's vertical swipe.
class _SeekBar extends StatelessWidget {
  final InlineVideoPlayback playback;

  const _SeekBar({required this.playback});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([playback.position, playback.duration]),
    builder: (context, _) {
      final total = playback.duration.value;
      if (total <= Duration.zero) return const SizedBox(height: 16);
      final progress =
          (playback.position.value.inMilliseconds / total.inMilliseconds).clamp(
            0.0,
            1.0,
          );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          height: 16,
          child: _SeekTrack(
            progress: progress,
            onSeek: (fraction) => unawaited(
              playback.seek(
                Duration(
                  milliseconds: (total.inMilliseconds * fraction).round(),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SeekTrack extends StatelessWidget {
  final double progress;
  final ValueChanged<double> onSeek;

  const _SeekTrack({required this.progress, required this.onSeek});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      void seekTo(double dx) =>
          onSeek(width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0));
      return GestureDetector(
        key: const Key('drama_seek_bar'),
        behavior: HitTestBehavior.opaque,
        // Horizontal only: the vertical axis stays with the PageView, so the
        // bar cannot block a page swipe.
        onHorizontalDragStart: (details) => seekTo(details.localPosition.dx),
        onHorizontalDragUpdate: (details) => seekTo(details.localPosition.dx),
        onTapDown: (details) => seekTo(details.localPosition.dx),
        child: Center(
          child: SizedBox(
            height: 16,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // `cjt.xml`: `app:pj`=@color/agn=#1affffff 是**底槽**（未播），
                // `app:awc`=@color/b8=#4dffffff 是**已播**段。对照 `cw7.xml`
                // 的 pj=#4dffffff / awc=#ccffffff 可知 awc 才是进度色。
                Container(height: 1, color: const Color(0x1AFFFFFF)),
                FractionallySizedBox(
                  widthFactor: progress,
                  child: Container(height: 1, color: const Color(0x4DFFFFFF)),
                ),
                Align(
                  alignment: Alignment(progress * 2 - 1, 0),
                  child: Container(
                    // Official thumb `app:ah6`=1.5dip sits in a 72×72 drag
                    // layer (`cjt.xml:8`). Visual size is the 1.5dp disc;
                    // the 16dp strip is the hit target.
                    width: 1.5,
                    height: 1.5,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),

              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The official bottom info line (`cj3.xml` → `d6g.xml`): 16sp bold title +
/// 8×16dp arrow (`@drawable/ead`). The 24×32 cover, 9sp episode badge and
/// 10sp tag all ship `gone` and only light up at runtime, so they stay off
/// here. 「全屏观看」 is a sibling overlay (`mq3.e` / `aqi.xml`), not a
/// child of this row.
/// 官方底部信息层（`cj3.xml` 的 `hdq` 段落，由 `ql3.c0` inflate `d6f.xml`）：
///
/// - **药丸行**：`nk3.c` inflate `ad9.xml`，在 RelativeLayout 里
///   `CENTER_IN_PARENT` 居中、挂在标题行上方。药丸本体高 30dp、左右 padding
///   17dp、背景 `@drawable/adu`=#1AFFFFFF 圆角 20dp、文字 14sp bold 白字；
///   集数 >1 时文案 `@string/e7v`=「观看全集·%s集」（`nk3.c.d()` 用
///   `episodeCnt` 填），否则 `@string/e7w`=「观看全片」。点击日志
///   「watch_full_episodes」→ 进全页播放器（`nk3.c.e` → `zf3.c.s`）。
///   右侧 30×30dp 圆形全屏钮（图标 `@drawable/f1d`，背景 `@drawable/a4r`
///   =#1AFFFFFF、marginStart 12dp、padding 5dp）只在**横版片源**显示
///   （`vk3.a.a`：`!saasVideoData.isVertical()` 才可见），点击走
///   `zf3.c.w(…, "horizontal", …)`，同样进全页播放器。
/// - **标题行**：`d6g.xml`，16sp bold 白字 + 8×16dp 箭头（`@drawable/ead`）。
/// - **分类 chip 行**：`d6f.xml` 的 `hdm`（marginTop 4dp、marginBottom 12dp、
///   divider `@drawable/aai`），chip 由 `ql3.c0.V()` 运行时构造：12sp 白字、
///   背景 `@color/ags`=#33FFFFFF、圆角 2dp、padding 6/2/6/2。
/// - **简介行**：`m6` `ShortSeriesExtendTextView`：14sp、`@color/bb8`→
///   `@color/u`=#CCFFFFFF、最多 2 行（`app:amo=2`），截断时点「展开」。
///   文案按官方截图为「第1集丨简介」——feed 卡从第 1 集起播。
class _InfoPanel extends StatefulWidget {
  final MediaItem item;
  final InlineVideoPlayback? playback;
  final VoidCallback onOpen;
  final VoidCallback? onFullscreen;

  const _InfoPanel({
    required this.item,
    required this.playback,
    required this.onOpen,
    required this.onFullscreen,
  });

  @override
  State<_InfoPanel> createState() => _InfoPanelState();
}

class _InfoPanelState extends State<_InfoPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.onFullscreen != null) ...[
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _EpisodePill(item: item, onTap: widget.onFullscreen!),
                if (widget.playback != null) ...[
                  const SizedBox(width: 12),
                  _FullscreenRoundButton(
                    playback: widget.playback!,
                    onTap: widget.onFullscreen!,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        // 标题行：官方 `d6g.xml`。点击 = 播放/暂停（与卡片手势层同一语义）。
        GestureDetector(
          onTap: widget.onOpen,
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [Shadow(color: Colors.black45, blurRadius: 8)],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 8,
                height: 16,
                child: Image.asset(
                  'assets/images/drama/info_arrow.webp',
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        ),
        if (item.categories.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              for (final category in item.categories.take(3))
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    category,
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (item.intro.isNotEmpty)
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(
                    '第1集丨${item.intro}',
                    maxLines: _expanded ? 20 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ),
                if (!_expanded) ...[
                  const SizedBox(width: 8),
                  const Text(
                    '展开',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// 官方「观看全集·N集」药丸（`ad9.xml` 的 `@id/cz1`，文案 `nk3.c.d()`）。
class _EpisodePill extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  const _EpisodePill({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final count = int.tryParse(item.ep) ?? 0;
    // `nk3.c.d()`：episodeCnt > 1 → `@string/e7v`=「观看全集·%s集」，
    // 否则 `@string/e7w`=「观看全片」。
    final label = count > 1 ? '观看全集·$count集' : '观看全片';
    return GestureDetector(
      key: const Key('drama_episode_pill'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 17),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 官方 30×30dp 圆形全屏钮（`ad9.xml` 的 `@id/dgu`）。官方只在横版片源上
/// 显示（`vk3.a.a`：非 vertical 才可见），这里用解码尺寸比例（≥1.666，
/// 同 `VideoFit.landscapeRatio`）作代理；解码前不显示。
class _FullscreenRoundButton extends StatelessWidget {
  final InlineVideoPlayback playback;
  final VoidCallback onTap;

  const _FullscreenRoundButton({required this.playback, required this.onTap});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Size>(
    valueListenable: playback.videoSize,
    builder: (context, size, _) {
      final landscape =
          size.width > 0 &&
          size.height > 0 &&
          size.width / size.height >= PlayerVideoLayout.landscapeRatio;
      if (!landscape) return const SizedBox.shrink();
      return GestureDetector(
        key: const Key('drama_fullscreen_button'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 30,
          height: 30,
          padding: const EdgeInsets.all(5),
          decoration: const BoxDecoration(
            color: Color(0x1AFFFFFF),
            shape: BoxShape.circle,
          ),
          child: Image.asset(
            'assets/images/drama/fullscreen.webp',
            fit: BoxFit.contain,
          ),
        ),
      );
    },
  );
}


/// Official `d62.xml` / `cf_.xml` / `aq0.xml` surfaces of the feed.
class _FeedMessage extends StatelessWidget {
  final String message;
  final String? actionLabel;
  final Future<void> Function()? onAction;
  final bool showSpinner;

  const _FeedMessage({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.showSpinner = false,
  });


  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xCC000000),
    child: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSpinner) ...[
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: onAction == null ? 16 : 14,
                  color: Colors.white,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[

                const SizedBox(height: 16),
                GestureDetector(
                  onTap: onAction,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 76,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white38),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      actionLabel!,
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Official `cf_.xml` swipe-up hint: 14sp white on `#CC222222`, 16/12dp
/// padding, auto-hides after 1s (`pp3.f.j()` posts 1000ms).
/// 「上滑查看更多视频」（`@string/eal`），对齐官方 `pp3.f` + `cf_.xml`：
///
/// - 条：`@color/sx`=#CC222222 底、横 16dp / 纵 12dp 内边距、内容水平居中；
/// - 文字 14sp（`@dimen/r0`）白字（`@color/al`），与箭头间距 4dp；
/// - 箭头：16×16dp **Lottie 循环动画** `more_wonderful_series_up_arrow.json`
///   （官方 `autoPlay+loop`；原资源填充是橙色，官方用 `LottieValueCallback`
///   强制刷成 `@color/al`=#ffffffff，本仓库直接把资源里的填充改成白色）；
/// - 显隐：300ms 淡入（`v()`）/ 300ms 淡出（`t()`），淡出完才摘掉。
class _SwipeUpHint extends StatelessWidget {
  final bool visible;

  const _SwipeUpHint({required this.visible});

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    duration: const Duration(milliseconds: 300),
    opacity: visible ? 1 : 0,
    child: Center(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xCC222222)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Lottie.asset(
                'assets/lottie/up_arrow.json',
                width: 16,
                height: 16,
                repeat: true,
                animate: true,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 4),
              const Text(
                '上滑查看更多视频',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Official `aq0.xml` pull-to-refresh strip: 16sp white 「下拉刷新内容」.
class _PullRefreshHint extends StatelessWidget {
  final bool armed;

  const _PullRefreshHint({required this.armed});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        height: 22,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              armed ? '正在刷新内容' : '下拉刷新内容',
              style: const TextStyle(fontSize: 16, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// The video rectangle of the on-screen card.
///
/// The native surface producer cannot be cropped or resized by a Flutter rect,
/// so the rectangle is computed here and the overflow is clipped by the
/// enclosing [Stack] (hard edge) and the 12dp [ClipRRect] above it. Display
/// mode is the official one: `cq3/o` (VideoViewHelper) fills the frame for a
/// portrait source and crops a few percent off each side (`:181`, `:91-98`),
/// while a wide source (ratio ≥ `landscapeRatio`) is pinned to the frame's
/// width and letterboxes (`:201-226`). The cover stays in front of the picture
/// until the first frame really arrives — `create` completing only means a
/// texture and decoder were allocated.
class _InlineVideoLayer extends StatelessWidget {
  final MediaItem item;
  final InlineVideoPlayback playback;

  const _InlineVideoLayer({required this.item, required this.playback});

  @override
  Widget build(BuildContext context) {
    // The video box is measured from this card's own constraints, not from
    // `MediaQuery`, which is the window rather than the box the card got. The
    // full page player lays its video out the same way (LayoutBuilder, see
    // `video_player_chrome.dart`), and it keeps the letterbox right when the
    // feed is not the whole window.
    return LayoutBuilder(
      builder: (context, constraints) {
        final window = constraints.biggest;
        final cacheWidth =
            (window.width * MediaQuery.devicePixelRatioOf(context)).ceil();
        return AnimatedBuilder(
          animation: Listenable.merge([
            playback.activeId,
            playback.textureId,
            playback.firstFrame,
            playback.rotation,
            playback.videoSize,
          ]),
          builder: (context, _) {
            final cover = StoryCover(
              key: ValueKey('drama_inline_cover_${item.kind}_${item.id}'),
              item: item,
              cacheWidth: cacheWidth,
              alignment: Alignment.topCenter,
            );
            // A card the session is not playing (yet) shows its cover only.
            if (playback.activeId.value != item.id) return cover;
            final textureId = playback.textureId.value;
            final layout = PlayerVideoLayout.calculate(
              window: window,
              insets: EdgeInsets.zero,
              // The decoder's own size, so a landscape drama keeps its aspect
              // instead of being squeezed into the 9:16 fallback. `calculate`
              // uses that fallback while the size is still unknown (0×0).
              videoSize: playback.videoSize.value,
              panelFraction: 0,
              fullScreen: true,
              // Official display mode for a feed card: fill the frame unless
              // the source is wide enough to be pinned to its width. The
              // overflow is clipped by the ClipRRect above this layer.
              fit: VideoFit.fillFrame,
            );
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                const ColoredBox(color: Colors.black),
                if (textureId != null)
                  Positioned.fromRect(
                    rect: layout.video,
                    child: RotatedBox(
                      quarterTurns: playback.rotation.value,
                      child: Texture(
                        key: ValueKey(
                          'drama_inline_texture_${item.kind}_${item.id}',
                        ),
                        textureId: textureId,
                      ),
                    ),
                  ),
                if (textureId == null || !playback.firstFrame.value) cover,
              ],
            );
          },
        );
      },
    );
  }
}

/// The card's failure state: the cover stays, official `d62.xml` copy is
/// shown (`@string/f0g` + `@string/b43` 76×28dp) and the retry button
/// re-activates this card's drama.
class _InlineVideoError extends StatelessWidget {
  final MediaItem item;
  final InlineVideoPlayback playback;
  final VoidCallback onRetry;

  const _InlineVideoError({
    required this.item,
    required this.playback,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: AnimatedBuilder(
      animation: Listenable.merge([playback.activeId, playback.error]),
      builder: (context, _) {
        final detail = playback.error.value;
        if (detail == null || playback.activeId.value != item.id) {
          return const SizedBox.shrink();
        }
        return ColoredBox(
          color: const Color(0xCC000000),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '网络异常，请稍后再试',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    key: ValueKey('drama_inline_retry_${item.kind}_${item.id}'),
                    onTap: onRetry,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 76,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white38),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '点击重试',
                        style: TextStyle(fontSize: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// 最近 / 收藏: the two channels the official client fills from the device.
///
/// Official recent/follow are **distribute lists**, not a video feed
/// (`bex.xml`: 7:5 cover, 8dp radius, 14sp single-line title, 9sp corner
/// tag). Neither may keep the inline player alive. 最近 reads this app's
/// player history; 收藏 reads the local shelf the 追剧 button writes.
///
/// 官方截图第二十三轮：最近 tab 顶部有「全部/短剧/漫剧」筛选 chips（选中
/// 橙字浅橙底），卡片封面带「漫剧」左上角标与居中半透明 ▶，标题两行，
/// 下方灰字「已看到第N集」（本仓库取自播放历史的 episode 索引）。「其他
/// 视频」无数据源、「编辑」多选管理不做。
class _LocalList extends StatefulWidget {
  final DramaChannel channel;
  final void Function(MediaItem item) onOpen;

  const _LocalList({required this.channel, required this.onOpen});

  @override
  State<_LocalList> createState() => _LocalListState();
}

class _LocalListState extends State<_LocalList> {
  /// null = 全部；'video' / 'manju' = 官方 chips 的筛选（仅最近 tab 有）。
  ///
  /// 官方编辑模式（`LatestShortVideoFragmentImpl`）：`Me()` 进编辑、
  /// `Le()` 完成、`Ke()` 全选/取消全选、`ue()` 删除（先弹
  /// 「确定删除浏览历史吗？」确认框）。多选态在下方的 `_selected` 里。
  bool _editing = false;
  final Set<String> _selected = <String>{};
  /// 官方 `f.u()` 的取值：1=短剧(genreFilter==1)、2=漫剧、3=视频（其他视频）。
  String? _filter;

  @override
  Widget build(BuildContext context) {
    final fromShelf = widget.channel.source == DramaChannelSource.shelf;
    return ValueListenableBuilder<int>(
      valueListenable: ShelfStore.instance.listenable,
      builder: (context, _, _) => ValueListenableBuilder<Box<dynamic>>(
        valueListenable: LibraryStore.instance.historyListenable,
        builder: (context, _, _) {
          final entries = fromShelf ? null : _historyEntries();
          final items = fromShelf ? _shelfItems() : _itemsOf(entries!);
          final filtered = _filter == null
              ? items
              : items.where((item) => item.kind == _filter).toList();
          final body = filtered.isEmpty
              ? _FeedMessage(
                  key: Key('drama_${widget.channel.label}_empty'),
                  message: '暂无符合条件的短剧',
                )
              : GridView.builder(
                  key: Key('drama_${widget.channel.label}_grid'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.62,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) => _DistributeCard(
                    key: ValueKey(
                      'drama_local_${widget.channel.label}_${filtered[index].id}',
                    ),
                    item: filtered[index],
                    subtitle: fromShelf
                        ? null
                        : _progressLabel(filtered[index]),
                    selected: _selected.contains(_keyOf(filtered[index])),
                    onTap: () {
                      if (_editing) {
                        setState(() {
                          final key = _keyOf(filtered[index]);
                          if (!_selected.add(key)) _selected.remove(key);
                        });
                        return;
                      }
                      widget.onOpen(filtered[index]);
                    },
                  ),
                );
          final shelfMode = fromShelf;
          return SafeArea(
            child: Column(
              children: [
                // 官方编辑头（`editHeaderLayout`）：全选/取消全选 + 删除，
                // 右上角「编辑/完成」。收藏频道没有这套（官方只在浏览历史有）。
                if (!shelfMode && filtered.isNotEmpty)
                  _editHeader(filtered),
                if (!fromShelf) ...[
                  // 官方 chips 行：固定在悬浮顶栏之下（grid 的 padding 让位）。
                  Padding(
                    key: const Key('drama_recent_filter'),
                    padding: const EdgeInsets.fromLTRB(16, 96, 16, 8),
                    child: Row(
                      children: [
                        _filterChip(null, '全部'),
                        const SizedBox(width: 8),
                        _filterChip('video', '短剧'),
                        const SizedBox(width: 8),
                        _filterChip('manju', '漫剧'),
                      ],
                    ),
                  ),
                ] else
                  const SizedBox(height: 96),
                Expanded(child: body),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 官方删除要按**记录身份**（kind + contentId），不能用下标。
  String _keyOf(MediaItem item) => '${item.kind}:${item.id}';

  List<({String contentId, String kind})> get _targets => [
    for (final entry in _historyEntries())
      (
        contentId: historyContentId(entry),
        kind: entry['kind']?.toString() ?? 'video',
      ),
  ];

  /// 官方编辑头（`editHeaderLayout`）：进编辑后顶部换成「全选」+「删除」，
  /// 未进编辑时只显示「编辑」。收藏频道没有这套。
  Widget _editHeader(List<MediaItem> filtered) {
    final allSelected =
        _editing && _selected.length == filtered.length && filtered.isNotEmpty;
    return Padding(
      key: const Key('drama_recent_edit_header'),
      padding: const EdgeInsets.fromLTRB(16, 96, 16, 0),
      child: Row(
        children: [
          if (_editing) ...[
            GestureDetector(
              key: const Key('drama_recent_select_all'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(filtered.map(_keyOf));
                }
              }),
              child: Text(
                allSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 14, color: Color(0xFFFA6725)),
              ),
            ),
            const Spacer(),
            GestureDetector(
              key: const Key('drama_recent_delete'),
              behavior: HitTestBehavior.opaque,
              onTap: _selected.isEmpty ? null : _confirmDelete,
              child: Text(
                '删除',
                style: TextStyle(
                  fontSize: 14,
                  color: _selected.isEmpty
                      ? const Color(0x66FFFFFF)
                      : const Color(0xFFFA6725),
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
          GestureDetector(
            key: const Key('drama_recent_edit'),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() {
              _editing = !_editing;
              if (!_editing) _selected.clear();
            }),
            child: Text(
              _editing ? '完成' : '编辑',
              style: const TextStyle(fontSize: 14, color: Color(0xB3FFFFFF)),
            ),
          ),
        ],
      ),
    );
  }

  /// 官方删除前先确认（`Te()` 的 `ConfirmDialogBuilder`，标题
  /// 「确定删除浏览历史吗？」，确认后删除并 Toast「删除成功」）。
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确定删除浏览历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('drama_recent_delete_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final selected = _selected.toSet();
    // 只删选中的记录：按 kind+contentId 精确匹配，其它记录一律不动。
    final removed = await LibraryStore.instance.removeHistoryEntries(
      _targets.where((target) => selected.contains(
        '${target.kind}:${target.contentId}',
      )),
    );
    if (!mounted) return;
    setState(() {
      _selected.clear();
      if (removed == 0) _editing = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(removed > 0 ? '删除成功' : '删除失败')),
    );
  }

  Widget _filterChip(String? kind, String label) {
    final selected = _filter == kind;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _filter = kind),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? const Color(0x1AFA6725) : const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: selected ? const Color(0xFFFA6725) : const Color(0xB3FFFFFF),
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _historyEntries() => LibraryStore
      .instance
      .historySnapshot()
      .where((entry) {
        final kind = entry['kind']?.toString() ?? '';
        return kind == 'video' || kind == 'manju';
      })
      .toList();

  List<MediaItem> _itemsOf(List<Map<String, dynamic>> entries) => [
    for (final entry in entries)
      MediaItem(
        id: historyContentId(entry),
        title: entry['title']?.toString() ?? '未知作品',
        cover: entry['cover']?.toString() ?? '',
        author: entry['author']?.toString() ?? '',
        badge: '',
        ep: entry['ep']?.toString() ?? '',
        kind: entry['kind']?.toString() ?? 'video',
        seriesId: entry['seriesId']?.toString(),
        episodeId: entry['episodeId']?.toString(),
      ),
  ];

  List<MediaItem> _shelfItems() => [

    for (final record in ShelfStore.instance.records())
      if (record.item.kind == 'video' || record.item.kind == 'manju')
        record.item,
  ];

  /// 「已看到第N集」：播放历史里的 episode 是 0 起下标。
  String? _progressLabel(MediaItem item) {
    for (final entry in _historyEntries()) {
      if (historyContentId(entry) != item.id) continue;
      final index = entry['episode'];
      if (index is num) return '已看到第${index.toInt() + 1}集';
      return null;
    }
    return null;
  }
}

/// Official distribute-list card (`bex.xml`): 7:5 cover, 8dp radius, 14sp
/// title, 9sp corner tag. 官方截图第二十三轮（最近 tab）：漫剧左上角标、
/// 居中半透明 ▶、标题两行、下方灰字「已看到第N集」。
class _DistributeCard extends StatelessWidget {
  final MediaItem item;
  final String? subtitle;
  final VoidCallback onTap;

  /// 编辑模式下的多选态（官方编辑态卡片右上角打勾）。
  final bool selected;

  const _DistributeCard({
    super.key,
    required this.item,
    required this.onTap,
    this.subtitle,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 7 / 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) => StoryCover(
                      item: item,
                      cacheWidth: (constraints.maxWidth * pixelRatio).ceil(),
                    ),
                  ),
                  if (item.kind == 'manju')
                    Positioned(
                      top: 6,
                      left: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x99000000),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            '漫剧',
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  const Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 40,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                  if (item.ep.isNotEmpty)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            item.ep,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 编辑态多选框（右上角，官方选中打勾）。
                  if (selected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0xFFFA6725),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.check, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9499A0),
                  height: 1.2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

