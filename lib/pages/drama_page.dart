import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:hive/hive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/digg_store.dart';
import '../services/inline_video_playback.dart';

import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/player_history.dart';
import '../services/shelf_store.dart';
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

  late final InlineVideoPlayback _inline;


  DramaChannel get _current => dramaChannels[_channel];

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
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_inline.dispose());
    _pages.dispose();
    super.dispose();
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
    final channel = dramaChannels[index];
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
              channels: dramaChannels,
              selected: _channel,
              onSelect: _selectChannel,
              onSearch: _openSearch,
            ),
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
                swipeHint: index < items.length - 1 || state.hasMore,
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
    return DecoratedBox(
      // Official `ap3/ap4` root is `@color/ba9=@null`, but a ViewStub
      // inflates `dad.xml` (`BookstoreHeaderBgView`, `app:fh="1.0 0.0"`) so
      // the black-on-white strip can sit over video. The fade below is that
      // header, not a self-invented scrim.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.94),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0, 1],
        ),
      ),
      child: SafeArea(
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
                child: _searchField(context),
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
                    color: Colors.black87,
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
      ),
    );
  }

  Widget _searchField(BuildContext context) => Semantics(
    button: true,
    label: '搜索短剧',
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        key: const Key('drama_search_button'),
        onTap: onSearch,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const Icon(LucideIcons.search, size: 18, color: Color(0x66000000)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '请输入短剧名或主演名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0x66000000),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One tab of the channel strip: 18sp label with a 3dp indicator under it.
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
                        ? const Color(0xFF000000)
                        : const Color(0x1A000000),
                  ),
                ),
                // 官方指示条：高 `app:arw` = 3dp、宽 `app:auw` = 16dp（`ap3.xml`），
                // 在 `SlidingTabLayout.E()` 里按 tab 中心对齐。
                const SizedBox(height: 3),
                Container(
                  width: 16,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFF000000) : Colors.transparent,
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
/// docs/short-drama-decompile-comparison-20260921.md §8
class _DramaFeedCard extends StatelessWidget {
  final MediaItem item;
  final bool opening;
  final bool followed;
  final bool liked;
  final bool swipeHint;
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
    required this.swipeHint,
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
        // 图标 46dp、文字 12sp bold、色 `@color/u`=#ccffffff）。
        // 官方 XML 里 评论(`c7u`) 与 分享(`hbw`) 默认 `gone`，这里同样不显示。
        // 锚在右下、信息层之上：官方这一栏也是沿右缘靠下排列，且顶部被顶栏
        // 的浮层覆盖（`ap3.xml` 的搜索行与频道条）。
        Positioned(
          right: 4,
          bottom: 64,
          child: _RightRail(
            followed: followed,
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
        // Official feed hint: `@string/eal`="上滑查看更多视频", 14sp white on a
        // `@color/sx`=#CC222222 strip (16dp horizontal / 12dp vertical padding),
        // 94dp above the page bottom, auto-hides after 1s (`pp3.f.j()` posts
        // 1000ms). Sources: `SeriesBookMallTabFragment.java:800-804`
        // and `apktool/res/layout/cf_.xml`. (`@string/e6j`=上滑继续观看短剧 belongs to
        // the player page's `BottomContainer`, not here.)
        if (swipeHint && !opening)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 94,
            child: _SwipeUpHint(),
          ),
        // 官方「全屏观看」(`mq3.e` inflate `aqi.xml`) 挂在底部信息槽 H3 上、
        // 水平居中；运行时再把 topMargin 调到画面底边上方 8dp。本页没有官方
        // 那套画面适配，所以锚在信息行之上、水平居中。
        // 它是**唯一**进入全页播放器的入口：`o.java:402-415` 的 `J6()` 把
        // `mq3.e` 加进来，`O4()` 在用系统返回时 `this.V4.callOnClick()`
        // 把它当成「继续播放」按一次。
        if (onFullscreen != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 56,
            child: Center(child: _FullscreenButton(onTap: onFullscreen!)),
          ),
        // 官方底部信息层（`cj3.xml` → `d6g.xml`）：标题 16sp bold 白字 + 8×16dp
        // 箭头（`@drawable/ead`）。官方这张卡上没有那排药丸按钮。
        Positioned(
          left: 12,
          right: 12,
          bottom: 24,
          child: _InfoLine(item: item, onOpen: onTogglePlay),
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
  final bool liked;
  final VoidCallback onFollow;
  final VoidCallback onLike;

  const _RightRail({
    required this.followed,
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
        label: followed ? '已追剧' : '追剧',
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
class _InfoLine extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onOpen;

  const _InfoLine({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onOpen,
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
    );
  }
}



/// 官方「全屏观看」按钮（`aqg.xml`/`aqh.xml`/`aqi.xml` 三变体）。
///
/// 取 `aqi.xml`：圆角 8dp、底 `@color/avv`=#b3262626、左右 padding 16dp、
/// 上下 8dp，图标 20×20dp(`@drawable/f1d`)，文字 14sp bold 白字
/// `@string/dzc`=「全屏观看」，图标与文字间距 4dp。
class _FullscreenButton extends StatelessWidget {
  final VoidCallback onTap;

  const _FullscreenButton({required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '全屏观看',
    child: GestureDetector(
      key: const Key('drama_fullscreen_button'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xB3262626),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Image.asset(
                  'assets/images/drama/fullscreen.webp',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 4),
              const Text(
                '全屏观看',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 14,
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
class _SwipeUpHint extends StatefulWidget {
  const _SwipeUpHint();

  @override
  State<_SwipeUpHint> createState() => _SwipeUpHintState();
}

class _SwipeUpHintState extends State<_SwipeUpHint> {
  bool _visible = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _hide = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Center(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xCC222222)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(LucideIcons.chevron_up, size: 16, color: Colors.white),
              SizedBox(width: 4),
              Text(
                '上滑查看更多视频',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
class _LocalList extends StatelessWidget {
  final DramaChannel channel;
  final void Function(MediaItem item) onOpen;

  const _LocalList({required this.channel, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ShelfStore.instance.listenable,
      builder: (context, _, _) => ValueListenableBuilder<Box<dynamic>>(
        valueListenable: LibraryStore.instance.historyListenable,
        builder: (context, _, _) {
          final fromShelf = channel.source == DramaChannelSource.shelf;
          final items = fromShelf ? _shelfItems() : _historyItems();
          if (items.isEmpty) {
            return _FeedMessage(
              key: Key('drama_${channel.label}_empty'),
              message: '暂无符合条件的短剧',
            );
          }
          return SafeArea(
            child: GridView.builder(
              key: Key('drama_${channel.label}_grid'),
              padding: const EdgeInsets.fromLTRB(16, 96, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: 0.72,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => _DistributeCard(
                key: ValueKey('drama_local_${channel.label}_${items[index].id}'),
                item: items[index],
                onTap: () => onOpen(items[index]),
              ),
            ),
          );
        },
      ),
    );
  }

  List<MediaItem> _shelfItems() => [

    for (final record in ShelfStore.instance.records())
      if (record.item.kind == 'video' || record.item.kind == 'manju')
        record.item,
  ];

  /// 最近 keeps this app's own player history: the entries the player wrote for
  /// short dramas and 漫剧, newest first.
  List<MediaItem> _historyItems() {
    final items = <MediaItem>[];
    for (final entry in LibraryStore.instance.historySnapshot()) {
      final kind = entry['kind']?.toString() ?? '';
      if (kind != 'video' && kind != 'manju') continue;
      items.add(
        MediaItem(
          id: historyContentId(entry),
          title: entry['title']?.toString() ?? '未知作品',
          cover: entry['cover']?.toString() ?? '',
          author: entry['author']?.toString() ?? '',
          badge: '',
          ep: entry['ep']?.toString() ?? '',
          kind: kind,
          seriesId: entry['seriesId']?.toString(),
          episodeId: entry['episodeId']?.toString(),
        ),
      );
    }
    return items;
  }
}

/// Official distribute-list card (`bex.xml`): 7:5 cover, 8dp radius, 14sp
/// single-line title, 9sp top-right episode tag.
class _DistributeCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  const _DistributeCard({super.key, required this.item, required this.onTap});

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
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

