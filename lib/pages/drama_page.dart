import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:hive/hive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';

import '../models/channel_tab.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/drama_mute_preferences.dart';
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
import 'series_pager_physics.dart';

/// One entry of the 短剧 tab's channel strip.
///
/// The official strip is server-driven (`BookstoreTabData.tabItem[]`, rendered
/// by `m0.java:3051-3106`). The server only returns the *seriesmall* strip
/// (推荐/看剧/漫剧/最近/收藏) when the request carries the seriesmall context:
/// `bottom_tab_type=VideoSeriesFeedTab(7)` + `client_req_type=Open(3)`
/// (`SeriesMallVM.java:141-176`). With the bookstore context the same route
/// returns the bookstore strip, whose mappable entries collapse to
/// 看剧(8)/视频(16) — that was the "channel strip shrinks to two tabs" bug.
/// Our proxy now sends the seriesmall context (rust `channel_tabs`), and the
/// five channels below are both the offline fallback and the name backstop for
/// empty server titles. The two the official client fills from the device —
/// 最近 (recent=18, `r73/m2.java:100-103`) and 收藏 (follow=30,
/// `td4/o1.java:179-193`) — are served from our own history and shelf.
/// 预约 (28) has no data source here and is deliberately absent.
///
/// Note: 频道映射与取证的完整理由 — 见
/// .agents/notes/implemented/feature/2026-09-20-official-drama-tab.md
enum DramaChannelSource { feed, history, shelf }

class DramaChannel {
  final String label;

  /// Index into [HomeNotifier.tabs] for [DramaChannelSource.feed].
  final int tabIndex;
  final String kind;
  final DramaChannelSource source;

  /// 官方 `BookstoreTabType` 里这条频道的 `tab_type`。
  ///
  /// 本地表也按官方同义类型标注（即 [ChannelTab.typeOf] 的映射）。两个用途：
  /// 服务端表到达后**按类型续接**当前频道（title 是服务端文案会变，类型才是
  /// 身份），以及换表请求上报 `tab_type` / `last_tab_type`（官方
  /// `SeriesMallVM` 行为）。
  final int? serverType;

  const DramaChannel({
    required this.label,
    required this.tabIndex,
    required this.kind,
    this.source = DramaChannelSource.feed,
    this.serverType,
  });

  bool get isFeed => source == DramaChannelSource.feed;
}

final dramaChannels = <DramaChannel>[
  DramaChannel(
    label: '推荐',
    tabIndex: HomeNotifier.tabs.indexOf('视频'),
    kind: 'video',
    serverType: kChannelVideoFeed,
  ),
  DramaChannel(
    label: '看剧',
    tabIndex: HomeNotifier.tabs.indexOf('短剧'),
    kind: 'video',
    serverType: kChannelVideoEpisode,
  ),
  DramaChannel(
    label: '漫剧',
    tabIndex: HomeNotifier.tabs.indexOf('漫剧'),
    kind: 'manju',
    serverType: kChannelDynamicComic,
  ),
  const DramaChannel(
    label: '最近',
    tabIndex: 0,
    kind: 'video',
    source: DramaChannelSource.history,
    serverType: kChannelRecent,
  ),
  const DramaChannel(
    label: '收藏',
    tabIndex: 0,
    kind: 'video',
    source: DramaChannelSource.shelf,
    serverType: kChannelFollow,
  ),
];

/// 服务端 `tab_type` -> 本地频道（F08：频道表由服务端下发）。
///
/// 官方 `m0.java:3051-3089` 把 `tab_item` 逐条转成频道：名字用服务端 `title`、
/// 类型用 `tab_type`。本地只保留**能真正打开内容**的那些类型；映射不到的类型
/// 返回 null（宁可不显示，也不要放一个点了没反应的频道）。
DramaChannel? serverChannelOf(ChannelTab tab) {
  // 服务端没给名字时用官方同义的中文兜底，避免出现空标签。
  String label(String fallback) =>
      tab.title.trim().isEmpty ? fallback : tab.title;
  switch (tab.type) {
    case kChannelVideoFeed:
      return DramaChannel(
        label: label('推荐'),
        tabIndex: HomeNotifier.tabs.indexOf('视频'),
        kind: 'video',
        serverType: tab.type,
      );
    case kChannelVideoEpisode:
    case kChannelVideo:
      return DramaChannel(
        label: label('看剧'),
        tabIndex: HomeNotifier.tabs.indexOf('短剧'),
        kind: 'video',
        serverType: tab.type,
      );
    case kChannelDynamicComic:
      return DramaChannel(
        label: label('漫剧'),
        tabIndex: HomeNotifier.tabs.indexOf('漫剧'),
        kind: 'manju',
        serverType: tab.type,
      );
    case kChannelRecent:
      return DramaChannel(
        label: label('最近'),
        tabIndex: 0,
        kind: 'video',
        source: DramaChannelSource.history,
        serverType: tab.type,
      );
    case kChannelFollow:
      return DramaChannel(
        label: label('收藏'),
        tabIndex: 0,
        kind: 'video',
        source: DramaChannelSource.shelf,
        serverType: tab.type,
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
  final Future<ChannelTable> Function()? channelLoader;

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

  /// 最近/收藏频道处于官方编辑模式（`S()`）。官方进编辑时把 SeriesMall 的
  /// 悬浮顶栏整个 `gone`（`af()`），由编辑头（全选/标题/完成）顶替——所以
  /// 这个状态必须提升到壳层来藏 [_TopBar]。
  bool _recentEditing = false;

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
    // 预载冷启动静音设置（`_applyPlaybackPrefs` 在会话首卡建播放器时读取；
    // 官方 `video/l.java` 的 `e()`→`g()`，默认 false＝有声起播）。
    unawaited(DramaMutePreferences.instance.load());
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
  /// 官方频道条由 `data.tab_item` 驱动，**但只在映射表确实是短剧语境的条带
  /// 时才替换**。判定特征：「推荐」这条 feed（tab_type 16）以「推荐」命名
  /// ——官方书城页与短剧页把同一条流分别叫 视频/推荐（取证见
  /// test/channel_tab_test.dart 的注释）。书城语境的条带没有最近/收藏、
  /// 把 16 叫视频，整栏换上去会把频道条塌成 看剧/视频 并顶掉默认频道
  /// （2026-09-27 真机回归）。实测本上游对 JSON 表单请求永远回书城条
  /// （bottom_tab_type=7、tab_type=-1/8/24 均不变，loopback 取证），官方
  /// 的短剧条带走的是我们暂未复刻的 protobuf 链路——所以在这台上游上
  /// 替换永不发生，频道条稳定为本地五频道；一旦上游开始下发短剧条带，
  /// F08 的动态配置自动生效。取不到或语境不符都静默保留本地表：频道条
  /// 是底级导航，不该因一次拉取失败把入口收走。
  Future<void> _loadChannels() async {
    if (_channelsRequested) return;
    _channelsRequested = true;
    ChannelTable table;
    try {
      final current = _current;
      table =
          await (widget.channelLoader?.call() ??
              ApiClient.instance.channelTabs(
                // 官方 SeriesMallVM：tabType 传当前频道、lastTabType 传上次选中
                // 频道（SP last_tab_type，无值 -1），服务端据此算 tab_index。
                tabType: current.serverType ?? kChannelVideoFeed,
                lastTabType: current.serverType ?? -1,
              ));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final mapped = <DramaChannel>[];
    for (final tab in table.tabs) {
      final channel = serverChannelOf(tab);
      if (channel != null) mapped.add(channel);
    }
    final isSeriesmallStrip = mapped.any(
      (channel) =>
          channel.serverType == kChannelVideoFeed && channel.label == '推荐',
    );
    if (mapped.length < 2 || !isSeriesmallStrip) return;
    final previous = _channels.isEmpty ? null : _channels[_channel];
    // 频道换了之后下标可能越界。默认选中按三级取：tab_type 对等续接
    // （title 是服务端文案会变，类型才是频道的身份）→ label+source 兜底 →
    // 服务端下发的默认选中下标（官方 `m0.U` 消费 `tab_index` 的行为）。
    var index = -1;
    final previousType = previous?.serverType;
    if (previousType != null) {
      index = mapped.indexWhere(
        (channel) => channel.serverType == previousType,
      );
    }
    if (index < 0 && previous != null) {
      index = mapped.indexWhere(
        (channel) =>
            channel.label == previous.label &&
            channel.source == previous.source,
      );
    }
    if (index < 0) {
      final serverDefault = table.defaultIndex;
      index = serverDefault >= 0 && serverDefault < mapped.length
          ? serverDefault
          : 0;
    }
    setState(() {
      _channels = List.unmodifiable(mapped);
      _channel = index;
      _screenIndex = 0;
    });
    // 频道表换了以后，**订阅流也要跟着换**：否则频道条高亮的是新频道，
    // 下面的 feed 还是旧的，两边对不上。这里复用 `_selectChannel` 的同一条
    // 规则，不另开分支。
    final current = _channels[_channel];
    if (current.isFeed) {
      ref.read(dramaProvider.notifier).selectTab(current.tabIndex);
    } else {
      unawaited(_inline.releaseAll());
    }
    if (_pages.hasClients) _pages.jumpToPage(0);
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
    // 官方看剧(8, CommonDoubleRow 两列)与漫剧(24, CommonThreeRow 三列)频道
    // 都是浅色海报瀑布格（StaggeredFeedTab）；最近/收藏列表也是浅色页；
    // 只有推荐(16)等视频流频道是黑底竖滑播放。状态栏图标亮度跟着页面走。
    final isVideoFlow =
        channel.source == DramaChannelSource.feed &&
        channel.kind != 'manju' &&
        channel.serverType != kChannelVideoEpisode &&
        channel.serverType != kChannelVideo;
    final lightPage = !isVideoFlow;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: lightPage ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: lightPage ? Colors.white : Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              // 最近 and 收藏 are lists in the official client too: the recent
              // list comes from the device's own history and the follow list
              // from the account, so neither is a video feed here either.
              // 看剧/漫剧是浅色海报瀑布格（官方 StaggeredFeedTab，
              // `client_template` 12/13），只有推荐走全屏竖滑播放流。
              child: switch (channel) {
                DramaChannel(source: DramaChannelSource.feed, kind: 'manju') =>
                  _browseGrid(
                    state,
                    items,
                    columns: 3,
                    gridKey: 'drama_manju_grid',
                    titleMaxLines: 1,
                  ),
                DramaChannel(
                  source: DramaChannelSource.feed,
                  serverType: kChannelVideoEpisode,
                ) =>
                  _browseGrid(
                    state,
                    items,
                    columns: 2,
                    gridKey: 'drama_episode_grid',
                    titleMaxLines: 2,
                  ),
                DramaChannel(source: DramaChannelSource.feed) => _feed(
                  state,
                  items,
                ),
                _ => _LocalList(
                  channel: channel,
                  // 官方最近/收藏卡点击都直接进播放页续播，不经过详情页。
                  onOpen: _openDetail,
                  onPlay: _openPlayer,
                  onFind: () => _selectChannel(0),
                  onEditingChanged: (editing) {
                    if (mounted) setState(() => _recentEditing = editing);
                  },
                ),
              },
            ),
            if (_pullDistance > 0)
              Positioned(
                top:
                    MediaQuery.paddingOf(context).top +
                    _searchRowHeight +
                    _stripHeight +
                    8,
                left: 0,
                right: 0,
                child: _PullRefreshHint(
                  armed: _pullDistance >= _pullRefreshTrigger,
                ),
              ),
            // 浅色页的顶栏背板：官方上滑时卡片从一条奶白渐变后面穿过，
            // 搜索框/频道条不会和海报叠在一起（黑页保持透明压在视频上）。
            // 最近频道进编辑后与官方一致：顶栏整个隐藏（`af()` gone）。
            // 纯装饰背板必须放行点击——chips 行官方就落在它的淡出带里。
            if (lightPage && !_recentEditing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: SizedBox(
                    height:
                        MediaQuery.paddingOf(context).top +
                        _searchRowHeight +
                        _stripHeight +
                        56,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xFFFFF3E6),
                            Color(0xFFFFFFFF),
                            Color(0x00FFFFFF),
                          ],
                          stops: [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (!_recentEditing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _TopBar(
                  channels: _channels,
                  selected: _channel,
                  onSelect: _selectChannel,
                  onSearch: _openSearch,
                  // 官方浅色页（看剧/漫剧）的顶栏换浅肤：深色字 + 浅灰搜索框。
                  light: lightPage,
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
      ),
    );
  }

  /// 官方瀑布格频道（StaggeredFeedTab）：漫剧 = `client_template` 13
  /// CommonThreeRow 三列；看剧 = 12 CommonDoubleRow 两列。浅色页，卡 =
  /// 竖版海报 + 片名 + 「分类·集数」，点击直接进播放页（官方
  /// `cv2/c.java:371-376` → `openShortSeriesActivity` → 沉浸播放器）。
  /// 看剧官方副标题带「N万热度」，数据在第二段卡里才有，v1 先用分类·集数。
  Widget _browseGrid(
    HomeState state,
    List<MediaItem> items, {
    required int columns,
    required String gridKey,
    required int titleMaxLines,
  }) {
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
        return const _GridMessage(message: '正在刷新内容', showSpinner: true);
      }
      return _GridMessage(key: Key('$gridKey.empty'), message: '暂无内容');
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onGridScroll,
      child: GridView.builder(
        key: Key(gridKey),
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.paddingOf(context).top +
              _searchRowHeight +
              _stripHeight +
              12,
          12,
          24,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 8,
          mainAxisSpacing: 16,
          // 海报约 5:7 + 片名 + 「分类·集数」；两列格片名可占两行。
          childAspectRatio: columns == 2 ? 0.56 : 0.52,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => _BrowseCard(
          key: ValueKey('$gridKey.${items[index].id}'),
          item: items[index],
          titleMaxLines: titleMaxLines,
          // 官方网格卡点击 = 直接进播放页（cv2/c.java:371-376 →
          // openShortSeriesActivity → ShortSeriesActivity 沉浸播放器），
          // 不经过详情页；详情是播放页里的入口。
          onTap: () => unawaited(_openPlayer(items[index])),
        ),
      ),
    );
  }

  /// 瀑布格的滚动：保留下拉刷新（同一套手势与提示），把 feed 的
  /// 竖滑换页/内联同步换成触底翻页。
  bool _onGridScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is OverscrollNotification && notification.overscroll < 0) {
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
    if (notification is ScrollEndNotification) {
      final shouldRefresh = _pullDistance >= _pullRefreshTrigger;
      if (_pullDistance > 0) {
        setState(() => _pullDistance = 0);
      }
      if (shouldRefresh) {
        unawaited(_refresh());
        return false;
      }
      // 触底翻页：loadMore 自带 isLoadMore/hasMore 门。
      if (notification.metrics.extentAfter < 600) {
        ref.read(dramaProvider.notifier).loadMore();
      }
    }
    return false;
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
      return const _FeedMessage(key: Key('drama_empty'), message: '暂无符合条件的短剧');
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onFeedScroll,
      child: PageView.builder(
        key: const Key('drama_feed'),
        controller: _pages,
        scrollDirection: Axis.vertical,
        // 官方翻页物理：fling 沿方向翻一页、恒速 1600px/s 吸附（100ms/英寸）。
        // 默认 PageScrollPhysics 的弹簧收尾起步猛、收尾硬。
        // Note: 物理对齐依据 — 见
        // .agents/notes/implemented/feature/2026-09-28-series-pager-physics.md
        physics: const SeriesPagerScrollPhysics(),
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
          return _DramaFeedCard(
            item: item,
            opening: _openingId == item.id,
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
      final saved = await PlayerHistory(
        widget.historyStore ?? LibraryStore.instance,
      ).load(contentId);
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
            contentLoader: widget.contentLoader == null
                ? null
                : (episode) => widget.contentLoader!(episode.itemId, tab),
            playerFactory: widget.playerFactory,
            historyStore: widget.historyStore,
            // 官方「观看全集」进播放器**不弹选集面板**：goToSingleFeed 虽然
            // setLaunchCatalogPanel(true)，但消费端 catalogdialog/v2/k.q0()
            // 被 AB `series_view_show_auto`（默认 enabled=false）门住——
            // 默认进播放器续当前集，选集入口是底部目录条（更正 §22）。
            // 进度不需要显式传——上面的 `disposePlayer()` 已把 feed 的
            // 当前集与播放进度写进历史，PlayerPage 从同一条历史续播。
            shortSeries: true,
            aiGenerated: item.aiGenerated,
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

  /// 官方浅色页（漫剧）的顶栏浅肤：深色字、浅灰搜索框。默认 false =
  /// 黑底视频流的浅色字顶栏（书城/短剧语境）。
  final bool light;

  const _TopBar({
    required this.channels,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
    this.light = false,
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
              child: Center(child: _searchField(context, light: light)),
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
                      light: light,
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
                  color: light ? const Color(0xFF1B1B1B) : Colors.white,
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

  Widget _searchField(BuildContext context, {required bool light}) {
    // 官方搜索框（`SearchWordDisplayView` inflate `c5e.xml`）：高 36dp
    // （`@dimen/zl`）、圆角 8dp（`ViewOutlineProvider.setRoundRect(…, 8f)` +
    // `setClipToOutline`）、图标 12dp 距左 16dp、文字距图标 8dp。配色取官方
    // **暗色皮肤**变体（用户设备官方即暗色）：底
    // `skin_color_search_bar_bg_v2_dark`=#1C1C1C、提示 14sp
    // `skin_color_search_bar_text_v2_dark`=#66FFFFFF（服务端 cue word 态更亮，
    // `skin_color_search_word_dark`=#99FFFFFF）、图标 `…_optimize_dark`。
    // 浅色页（漫剧）换浅肤：底 #0F000000、深色字与图标。
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
            color: light ? const Color(0x0F000000) : const Color(0xFF1C1C1C),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.only(left: 16),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: light
                    ? const Icon(
                        LucideIcons.search,
                        size: 12,
                        color: Color(0x99000000),
                      )
                    : Image.asset(
                        'assets/images/drama/search.webp',
                        fit: BoxFit.contain,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '请输入短剧名或主演名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: light
                        ? const Color(0x99000000)
                        : const Color(0x66FFFFFF),
                  ),
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

  /// 浅色页（漫剧）的深色文字变体，见 [_TopBar.light]。
  final bool light;

  const _ChannelTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.light = false,
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
                        ? (light ? const Color(0xFF1B1B1B) : Colors.white)
                        : (light
                              ? const Color(0x99000000)
                              : const Color(0x99FFFFFF)),
                  ),
                ),
                // 官方指示条：高 `app:arw` = 3dp、宽 `app:auw` = 16dp（`ap3.xml`），
                // 在 `SlidingTabLayout.E()` 里按 tab 中心对齐。
                const SizedBox(height: 3),
                Container(
                  width: 16,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected
                        ? (light ? const Color(0xFF1B1B1B) : Colors.white)
                        : Colors.transparent,
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
/// - a seek bar (`cjt.xml`, 16dp) sits at the bottom;
/// - a bottom info line (`cj3.xml`/`d6g.xml`) is the drama title at 16sp bold
///   plus an 8×16dp arrow and, when known, an episode label;
/// - a `VideoGestureDetectLayout` covers the middle for double-tap and
///   long-press.
///
/// 右侧追剧、点赞栏按用户要求移除（2026-09-26）。
/// Note: 进度条/信息层的官方数值出处 —
/// docs/research/short-drama-decompile-comparison-20260921.md §8
class _DramaFeedCard extends StatelessWidget {
  final MediaItem item;
  final bool opening;
  final Widget? video;
  final Widget? errorOverlay;
  final InlineVideoPlayback? playback;
  final VoidCallback? onFullscreen;
  final VoidCallback onTogglePlay;

  const _DramaFeedCard({
    required this.item,
    required this.opening,
    this.video,
    this.errorOverlay,
    this.playback,
    this.onFullscreen,
    required this.onTogglePlay,
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
        // 官方进度条（`cjt.xml`）：整条高 16dp、轨道 1.0dip、滑块 1.5dip，
        // 已播 `@color/agn`=#1affffff、底槽 `@color/b8`=#4dffffff，左右 padding 16dp。
        if (playback != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _SeekBar(playback: playback!),
          ),
        // 官方「取消静音」药丸（feed 变体 `mq3.c` + `bvf.xml`，108×36dp 展开），
        // 不是播放页的 `ck8.xml` 变体（12sp+16dp lottie、3s 定时）。官方出厂
        // 默认**有声**，药丸只在该会话静音时出现；形态细节见 _MuteHint 文档。
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

/// Official mute pill (`mq3.c` + `bvf.xml`).
///
/// 108×36dp 展开态（20dp 静音图标距左 16、「取消静音」14sp 白字距右 12，
/// 背景 `mi`=#4D000000 + 0.5dp #33FFFFFF 描边、圆角 20）；展开 5s 后收回
/// 36dp 圆形图标态（`f(false, true)` 的 300ms 动画）。只在静音播放时出现；
/// 点击取消静音后整个药丸直接消失（`z.y5` 的 `setVisibility(GONE)`），
/// 反馈走 toast。
class _MuteHint extends StatefulWidget {
  final InlineVideoPlayback playback;

  const _MuteHint({required this.playback});

  @override
  State<_MuteHint> createState() => _MuteHintState();
}

class _MuteHintState extends State<_MuteHint> {
  bool _expanded = true;
  Timer? _collapse;

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
    super.dispose();
  }

  void _onMute() {
    if (!mounted || !widget.playback.muted.value) return;
    setState(() => _expanded = true);
    _scheduleCollapse();
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
        if (!widget.playback.muted.value) return const SizedBox.shrink();
        return Semantics(
          button: true,
          label: '取消静音',
          child: GestureDetector(
            key: const Key('drama_mute_hint'),
            onTap: () {
              unawaited(widget.playback.toggleMute());
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已开启声音')),
              );
            },
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _expanded ? 108 : 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0x4D000000),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
              ),
              padding: EdgeInsets.only(left: _expanded ? 16 : 8),
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Image.asset(
                      'assets/images/drama/mute_off.webp',
                      fit: BoxFit.contain,
                    ),
                  ),
                  if (_expanded)
                    // 108dp 内不另留图标与文案的间隙：14sp×4 字 + 16/12 边距
                    // 已占满（官方 bvf.xml 的排布）。
                    Text(
                      '取消静音',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        height: 1.1,
                      ),
                    ),
                  if (_expanded) const SizedBox(width: 12),
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
/// Official recent/follow are **distribute lists**, not a video feed. The
/// recent channel is `LatestShortVideoFragmentImpl` + `LatestTimerVideoRecyclerView`
/// （双列 staggered 网格，无时间分组头——吸顶时间标签 `SwitchTimeLabelView`
/// 在这条链路上恒为 null，「今天/昨天/更早」分组是「我的-浏览历史」页的
/// 形态）。Neither may keep the inline player alive. 最近 reads this app's
/// player history; 收藏 reads existing local shelf records.
///
/// 官方截图第二十三轮 + 反编译对齐：最近 tab 顶部有「全部/短剧/漫剧/其他视频」
/// 筛选 chips（选中橙字浅橙底加粗），卡片封面带「漫剧」左上角标与居中 ▶，
/// 14sp 粗体两行标题，下方灰字「已看到第N集」（本仓库取自播放历史的
/// episode 索引）。「其他视频」无数据源（本地历史只记 短剧/漫剧，恒为空）；
/// 「N播放」渐变角标、「已下架」、Album/PUGC 专属行没有数据源，不做。
/// 漫剧瀑布格的浅色提示（加载/空态）。
class _GridMessage extends StatelessWidget {
  final String message;
  final bool showSpinner;

  const _GridMessage({
    super.key,
    required this.message,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSpinner) ...[
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF1B1B1B),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: Color(0x99000000)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 最近/收藏列表卡（官方 `staggered/b` holder + `ay3.xml`）：整卡白底 8dp
/// 圆角（`m6.c(itemView,8)`）、10:14 封面、居中 24dp ▶（官方 `g5t`，封面加载
/// 成功后才显示，这里恒显）、10sp 白字角标（`B3()`）、14sp 粗体两行标题、
/// 12sp `gray_40` 进度行（`K3()` 的「已看到第N集」）。编辑态：卡底转
/// `#FAFAFA`（`P3` 动画终点）、选中封面盖 `#33000000` 遮罩（`ko`）+ 右下
/// 24dp 勾选框（`x3()`，右 8dp/下 6dp）。
class _HistoryCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  /// 官方 `o.r3`：长按卡片进编辑（并选中该卡）。
  final VoidCallback? onLongPress;

  final bool editing;
  final bool selected;

  /// 左上角角标（最近列表的「漫剧」）；null 不显示。
  final String? tagText;

  /// 「已看到第N集」进度行（收藏页不传）。
  final String? subtitle;

  const _HistoryCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.editing,
    this.onLongPress,
    this.selected = false,
    this.tagText,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: editing ? const Color(0xFFFAFAFA) : Colors.white,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) => StoryCover(
                        item: item,
                        cacheWidth: (constraints.maxWidth * pixelRatio).ceil(),
                        alignment: Alignment.topCenter,
                      ),
                    ),
                    const Center(
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 24,
                        color: Colors.white,
                        shadows: [
                          Shadow(color: Color(0x80000000), blurRadius: 2),
                        ],
                      ),
                    ),
                    if (selected) const ColoredBox(color: Color(0x33000000)),
                    if (tagText != null)
                      Positioned(
                        top: 10,
                        left: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0x66000000),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Text(
                              tagText!,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                height: 1.1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    // 官方勾选框在封面右下（右 8dp/下 6dp），不是右上角。
                    if (editing)
                      Positioned(
                        right: 8,
                        bottom: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? const Color(0xFFFA6725)
                                : Colors.transparent,
                            border: selected
                                ? null
                                : Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: selected
                                ? const Icon(
                                    Icons.check,
                                    size: 18,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        height: 1.25,
                        color: Color(0xFF1B1B1B),
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
                            height: 1.2,
                            color: Color(0x66000000),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 瀑布格卡片：竖版海报（约 5:7）+ 片名 + 「分类·集数」。官方
/// StaggeredFeedTab 的 CommonDoubleRow/ThreeRow 卡（`mw2.c` 供数）在浅色页上的形态。
/// 最近列表的卡带角标/勾选等编辑态，官方本就是另一套 holder
/// （`staggered/b` + `ay3.xml`），见 [_HistoryCard]。
class _BrowseCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  /// 官方两列格片名可换行（看剧），三列格单行省略（漫剧）。
  final int titleMaxLines;

  const _BrowseCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.titleMaxLines,
  });

  /// 官方副标题 = 分类名（tag_info 取前两个）+ 集数（episode_cnt）。
  /// 看剧官方展示「N万热度」（第二段卡才有该数据），v1 先用集数替代。
  String? get _subtitle {
    final cats = item.categories.take(2).join('·');
    final ep = item.ep.trim();
    final epText = RegExp(r'^\d+$').hasMatch(ep) ? '$ep集' : ep;
    final parts = [if (cats.isNotEmpty) cats, if (epText.isNotEmpty) epText];
    if (parts.isEmpty) return null;
    return parts.join('·');
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitle;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) => StoryCover(
                      item: item,
                      cacheWidth: (constraints.maxWidth * pixelRatio).ceil(),
                      alignment: Alignment.topCenter,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: titleMaxLines,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              height: 1.2,
              color: Color(0xFF1B1B1B),
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  color: Color(0x99000000),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 瀑布格频道的浅色空态（官方 `CommonErrorView` 家族）：圆形插画位 +
/// 文案 + 「找视频」跳回推荐流。
class _HistoryEmpty extends StatelessWidget {
  final String message;
  final VoidCallback? onFind;

  /// 官方按钮文案：最近页是 `Fe()` 的「找短剧」，收藏页硬编码「找视频」。
  final String buttonLabel;

  const _HistoryEmpty({
    super.key,
    required this.message,
    this.onFind,
    this.buttonLabel = '找视频',
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 官方是插画资源（纸箱），本地没有同款资产，用同色系圆形占位。
        Container(
          width: 96,
          height: 96,
          decoration: const BoxDecoration(
            color: Color(0xFFFFE9C7),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.inventory_2_outlined,
            size: 40,
            color: Color(0xFFD9A94A),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          message,
          style: const TextStyle(fontSize: 14, color: Color(0x99000000)),
        ),
        if (onFind != null) ...[
          const SizedBox(height: 20),
          GestureDetector(
            key: const Key('drama_history_find'),
            onTap: onFind,
            behavior: HitTestBehavior.opaque,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFFA6725),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                child: Text(
                  // 最近页 = `Fe()`（DynamicComic 开启时「找短剧」）；
                  // 收藏页官方硬编码「找视频」。
                  buttonLabel,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// 官方最近列表页脚：`u4` 页脚件 `a()` 的「已显示全部内容」态
/// （`ae4.xml`：12sp `gray_40`，marginTop 16 / marginBottom 24）。
class _ListEndFooter extends StatelessWidget {
  const _ListEndFooter();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: Text(
        '已显示全部内容',
        style: const TextStyle(fontSize: 12, color: Color(0x66000000)),
      ),
    ),
  );
}

class _LocalList extends StatefulWidget {
  // Note: 最近/收藏两频道按反编译源码对齐官方的证据链与取舍 —
  // 见 .agents/notes/implemented/feature/2026-09-27-recent-tab-decompile-replica.md
  // 与 .agents/notes/implemented/feature/2026-09-27-follow-channel-decompile-replica.md
  final DramaChannel channel;
  final void Function(MediaItem item) onOpen;

  /// 官方最近/收藏卡点击都直接进播放页续播（`staggered/b.I3`、`m0:694` →
  /// `openShortSeriesActivity`）；onOpen 只是测试缝缺省时的详情兜底。
  final Future<void> Function(MediaItem item)? onPlay;

  /// 官方空态按钮（最近「找短剧」/收藏「找视频」）：跳回推荐频道。
  final VoidCallback? onFind;

  /// 编辑模式进出时通知壳层藏/显顶栏（官方 `af()` 把 SeriesMall 顶栏 gone）。
  final ValueChanged<bool>? onEditingChanged;

  const _LocalList({
    required this.channel,
    required this.onOpen,
    this.onPlay,
    this.onFind,
    this.onEditingChanged,
  });

  @override
  State<_LocalList> createState() => _LocalListState();
}

class _LocalListState extends State<_LocalList> {
  /// null = 全部；'video' / 'manju' = 官方 chips 的筛选（仅最近 tab 有）。
  ///
  /// 官方编辑态（`LatestShortVideoFragmentImpl`）：长按卡片进编辑并选中该卡
  /// （`o.r3` → `X5(true, view)` → `m3(position)`），全选/取消全选（`Ke`/`bf`），
  /// 完成（`Le`）退出；删除与追剧都在底部操作条 `v73.k`（`dc1.xml`）上，
  /// 删除前弹「确定删除浏览历史吗？」确认框（`Te`）。
  bool _editing = false;
  final Set<String> _selected = <String>{};

  /// 官方 `f.u()` 的取值：0=全部、1=短剧(genreFilter==1)、2=漫剧、3=其他视频。
  String? _filter;

  @override
  void dispose() {
    // 带着编辑态被拆掉时壳层的顶栏会一直藏着——兜底还原。
    if (_editing) widget.onEditingChanged?.call(false);
    super.dispose();
  }

  void _setEditing(bool value, {String? preselect}) {
    if (_editing == value) return;
    setState(() {
      _editing = value;
      _selected.clear();
      if (value && preselect != null) _selected.add(preselect);
    });
    widget.onEditingChanged?.call(value);
  }

  /// 官方 `Ee()`（编辑头标题）在 DynamicComicContentTypeCompatConfig（线上开）
  /// 下的取值：全部→视频、短剧、漫剧、其他视频。
  String get _filterTitle => switch (_filter) {
    'other' => '其他视频',
    'manju' => '漫剧',
    'video' => '短剧',
    _ => '视频',
  };

  /// 收藏频道官方 `ye()`：全部→「全部」（与最近不同，最近是「视频」）。
  String get _shelfFilterTitle => switch (_filter) {
    'manju' => '漫剧',
    'video' => '短剧',
    'other' => '视频',
    _ => '全部',
  };

  /// 官方 `De()`/`xe()`（已选择后缀）：漫剧/短剧，其余一律「视频」。
  String get _selectionSuffix => switch (_filter) {
    'manju' => '漫剧',
    'video' => '短剧',
    _ => '视频',
  };

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
          // 官方筛选行（最近 = chips `daj.xml`，收藏 = GenreScrollTabLayout，
          // 选中态视觉同源）：全部/短剧/漫剧/其他视频。「其他视频」= 影视综
          // 等视频历史；本地只记 短剧/漫剧，因此恒为空（对应官方空态）。
          final filtered = switch (_filter) {
            null => items,
            'other' => const <MediaItem>[],
            _ => items.where((item) => item.kind == _filter).toList(),
          };
          final editingList = _editing && filtered.isNotEmpty;
          final empty = _HistoryEmpty(
            key: Key('drama_${widget.channel.label}_empty'),
            // 官方空态：最近「暂无浏览历史」；收藏 = 「暂无」+f()+「内容」。
            message: fromShelf ? '暂无收藏内容' : '暂无浏览历史',
            onFind: widget.onFind,
            buttonLabel: fromShelf ? '找视频' : '找短剧',
          );
          final body = filtered.isEmpty
              ? empty
              : GridView.builder(
                  key: Key('drama_${widget.channel.label}_grid'),
                  // 官方 staggered 网格间距（`j0`）：左右 12dp、行/列间距 8dp。
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    // 官方封面 10:14 + 粗体两行标题 + 进度行。
                    childAspectRatio: 0.56,
                  ),
                  // 尾部页脚「已显示全部内容」（官方 `u4.a()`）。
                  itemCount: filtered.length + 1,
                  itemBuilder: (context, index) {
                    if (index == filtered.length) {
                      return const _ListEndFooter();
                    }
                    final item = filtered[index];
                    return _HistoryCard(
                      key: ValueKey(
                        'drama_local_${widget.channel.label}_${item.id}',
                      ),
                      item: item,
                      editing: editingList,
                      selected: _selected.contains(_keyOf(item)),
                      // 官方 `v3()`/m0 角标条件同构：漫剧角标只在非漫剧
                      // 筛选下出现。
                      tagText:
                          item.kind == 'manju' && _filter != 'manju'
                          ? '漫剧'
                          : null,
                      subtitle: fromShelf
                          ? _shelfProgressLabel(item)
                          : _progressLabel(item),
                      onTap: () {
                        if (editingList) {
                          setState(() {
                            final key = _keyOf(item);
                            if (!_selected.add(key)) _selected.remove(key);
                          });
                          return;
                        }
                        // 官方最近/收藏卡点击都直接进播放页续播
                        //（`staggered/b.I3`、m0:694 → openShortSeriesActivity）。
                        final play = widget.onPlay;
                        if (play != null) {
                          unawaited(play(item));
                        } else {
                          widget.onOpen(item);
                        }
                      },
                      // 官方长按进编辑（`o.r3` / 埋点 type=long_press），
                      // 并选中被按的那张卡。
                      onLongPress: filtered.isEmpty
                          ? null
                          : () => _setEditing(true, preselect: _keyOf(item)),
                    );
                  },
                );
          return Column(
            children: [
              if (editingList)
                _editHeader(filtered)
              else if (filtered.isNotEmpty)
                _normalHeader()
              else
                // 空列表：只给悬浮顶栏让位。
                SizedBox(height: MediaQuery.paddingOf(context).top + 76),
              Expanded(child: body),
              if (editingList) _bottomBar(filtered),
            ],
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

  /// 非编辑态顶区（官方 `daj.xml` + `c4e.xml`）：可横滑的 chips 行
  /// （14h/7v、圆角 6dp）+ 右侧「编辑」（14sp 粗体；官方 chips 行
  /// marginEnd 52dp 给它让位）。悬浮顶栏（搜索 38 + 频道条 38）仍然压在
  /// 页面上方，chips 行要整体让到它下面。
  Widget _normalHeader() {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      padding: EdgeInsets.fromLTRB(12, top + 84, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const Key('drama_recent_filter'),
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _filterChip(null, '全部'),
                  const SizedBox(width: 6),
                  _filterChip('video', '短剧'),
                  const SizedBox(width: 6),
                  _filterChip('manju', '漫剧'),
                  const SizedBox(width: 6),
                  _filterChip('other', '其他视频'),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            key: const Key('drama_recent_edit'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _setEditing(true),
            child: const Text(
              '编辑',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B1B1B),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 官方编辑头（`c4f.xml` 的 `cvl`）：左「全选/取消全选」、右「完成」
  /// （16sp），中间当前筛选名（18sp 粗体）+「已选择 N 个xx」（12sp
  /// `gray_40`，0 个时隐藏，`Ua()`）。官方进编辑把悬浮顶栏整个藏掉，
  /// 这里因此自带状态栏内边距。
  Widget _editHeader(List<MediaItem> filtered) {
    final allSelected = _selected.length == filtered.length;
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      key: const Key('drama_recent_edit_header'),
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(22, top + 4, 22, 4),
      child: SizedBox(
        height: 56,
        child: Stack(
          children: [
            Row(
              children: [
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
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFF1B1B1B),
                    ),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setEditing(false),
                  child: const Text(
                    '完成',
                    style: TextStyle(fontSize: 16, color: Color(0xFF1B1B1B)),
                  ),
                ),
              ],
            ),
            Align(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    // 最近 `Ee()`：全部→「视频」；收藏 `ye()`：全部→「全部」。
                    fromShelfEdit ? _shelfFilterTitle : _filterTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1B1B1B),
                    ),
                  ),
                  if (_selected.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '已选择 ${_selected.length} 个$_selectionSuffix',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0x66000000),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 官方底部操作条：白底 + 0.5dp `gray_06` 分隔线，无选中时整体 30% 透明
  /// （`Q1()`）。最近 = `v73.k`（`dc1.xml`）：「追剧/追漫」（按筛选取名）+
  /// 红色「删除」；收藏 = `bb3.p0`：**只有**红色「删除」（都已在书架，没有
  /// 追剧动作）。
  Widget _bottomBar(List<MediaItem> filtered) {
    final enabled = _selected.isNotEmpty;
    return DecoratedBox(
      key: Key(
        fromShelfEdit ? 'drama_shelf_bottom_bar' : 'drama_recent_bottom_bar',
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: const Color(0xFF1B1B1B).withAlpha(15)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!fromShelfEdit) ...[
                _barAction(
                  key: const Key('drama_recent_follow'),
                  label: _filter == 'manju' ? '追漫' : '追剧',
                  color: const Color(0xFF1B1B1B),
                  enabled: enabled,
                  onTap: enabled
                      ? () => unawaited(_followSelected(filtered))
                      : null,
                ),
                const SizedBox(width: 40),
              ],
              _barAction(
                key: Key(fromShelfEdit ? 'drama_shelf_delete' : 'drama_recent_delete'),
                label: '删除',
                color: const Color(0xFFF43207),
                enabled: enabled,
                onTap: enabled ? _confirmDelete : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get fromShelfEdit =>
      widget.channel.source == DramaChannelSource.shelf;

  Widget _barAction({
    required Key key,
    required String label,
    required Color color,
    required bool enabled,
    required VoidCallback? onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.3,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(label, style: TextStyle(fontSize: 14, color: color)),
        ),
      ),
    );
  }

  /// 官方 `P0`：选中的作品批量追剧入书架。已在书架的跳过；全部都追过时只
  /// 提示「视频已加入追剧」（`h0.b()`），成功后按筛选给
  /// 「追剧/追漫后可在书架找到…」（`u7` → `h0.i()`），300ms 后退出编辑。
  Future<void> _followSelected(List<MediaItem> filtered) async {
    final targets = [
      for (final item in filtered)
        if (_selected.contains(_keyOf(item)) &&
            !ShelfStore.instance.containsItem(item))
          item,
    ];
    if (targets.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('视频已加入追剧')));
      return;
    }
    for (final item in targets) {
      await ShelfStore.instance.add(item);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _filter == 'manju' ? '追漫后可在书架找到该漫剧' : '追剧后可在书架找到该短剧',
        ),
      ),
    );
    Timer(const Duration(milliseconds: 300), () {
      if (mounted) _setEditing(false);
    });
  }

  /// 官方删除前先确认（最近 `Te()`：标题「确定删除浏览历史吗？」、
  /// 确认/取消；收藏 `re()`→`hy2.d0`：标题「确认删除吗？」、按钮文案
  /// 「删除」）。成功 Toast「删除成功」/失败「删除失败」，500ms 后退出
  /// 编辑（`P2`/`pb` 的 `postInForeground(500)`）。
  Future<void> _confirmDelete() async {
    final fromShelf = fromShelfEdit;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(fromShelf ? '确认删除吗？' : '确定删除浏览历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: Key(
              fromShelf ? 'drama_shelf_delete_confirm' : 'drama_recent_delete_confirm',
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(fromShelf ? '删除' : '确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final selected = _selected.toSet();
    var removed = 0;
    if (fromShelf) {
      // 官方收藏删除 = 取消追剧记录（`xz2.c` 的 seriesId 维度）；
      // 本地对应从 ShelfStore 摘掉，键与加入时一致（seriesId 优先）。
      final store = ShelfStore.instance;
      final keys = <String>[];
      for (final item in _shelfItems()) {
        if (selected.contains(_keyOf(item))) {
          if (store.containsItem(item)) removed++;
          keys.add(ShelfStore.keyOf(item));
        }
      }
      await store.removeKeys(keys);
    } else {
      // 只删选中的记录：按 kind+contentId 精确匹配，其它记录一律不动。
      removed = await LibraryStore.instance.removeHistoryEntries(
        _targets.where(
          (target) => selected.contains('${target.kind}:${target.contentId}'),
        ),
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(removed > 0 ? '删除成功' : '删除失败')));
    // 官方删除两条路径都在 500ms 后退编辑（`ThreadUtils.postInForeground(500)`）。
    Timer(const Duration(milliseconds: 500), () {
      if (mounted) _setEditing(false);
    });
  }

  Widget _filterChip(String? kind, String label) {
    final selected = _filter == kind;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _filter = kind),
      child: DecoratedBox(
        // 官方 `c4e.xml` + `f.s()`：选中浅橙底橙字加粗，未选中浅灰底深字。
        decoration: BoxDecoration(
          color: selected ? const Color(0x1AFA6725) : const Color(0x08000000),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected
                  ? const Color(0xFFFA6725)
                  : const Color(0xFF1B1B1B),
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _historyEntries() =>
      LibraryStore.instance.historySnapshot().where((entry) {
        final kind = entry['kind']?.toString() ?? '';
        return kind == 'video' || kind == 'manju';
      }).toList();

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

  /// 收藏卡官方进度行 `F3()`：`%s集/%s集`（已看集数 = 播放下标+1，总数 =
  /// 收藏时的剧集数）。本地收藏记录不存进度，总数取 item.ep，已看数从播放
  /// 历史按剧 id 反查；两边都缺就不显示。
  String? _shelfProgressLabel(MediaItem item) {
    final total = int.tryParse(item.ep.trim());
    final seriesId = item.seriesId ?? item.id;
    var seen = 0;
    var hasSeen = false;
    for (final entry in _historyEntries()) {
      final entrySeries =
          entry['seriesId']?.toString() ?? historyContentId(entry);
      if (entrySeries != seriesId) continue;
      final index = entry['episode'];
      if (index is num) {
        seen = index.toInt() + 1;
        hasSeen = true;
      }
      break;
    }
    if (total == null && !hasSeen) return null;
    if (total == null) return '$seen集';
    return '$seen集/$total集';
  }
}
