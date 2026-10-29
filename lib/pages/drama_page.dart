import '../widgets/video_player_chrome.dart';
import '../services/desktop_platform.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';

import '../models/channel_tab.dart';
import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/drama_channel_preferences.dart';
import '../services/drama_mute_preferences.dart';
import '../services/episode_source_cache.dart';
import '../services/inline_video_playback.dart';

import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/player_history.dart';
import '../services/player_style_config.dart';
import '../services/shelf_store.dart';
import '../services/short_series_font_scale.dart';
import '../services/swipe_guide_store.dart';
import '../services/user_facing_error.dart';
import '../services/media_history_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/playlet_danmaku_layer.dart';
import '../widgets/player/playlet_danmaku_loader.dart';
import '../widgets/player/playlet_danmaku_settings.dart';
import '../widgets/player/playlet_font_scale_sheet.dart';
import '../widgets/player/playlet_hot_comment_bar.dart';
import '../widgets/player/playlet_more_panel.dart';
import '../widgets/player/playlet_more_panel_light.dart';
import '../widgets/player/playlet_option_sheet.dart';
import '../widgets/player/playlet_quick_catalog_sheet.dart';
import '../widgets/player/player_toast.dart';
import '../widgets/player/player_video_layout.dart';
import '../widgets/tab_swipe_area.dart';
import 'detail_page.dart';
import 'drama_download_sheet.dart';
import 'home_provider.dart';
import 'listen_mode_page.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'series_detail_page.dart';
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

  // Note: 海报格曾在背后起播，播放资格按渲染形态收口 — 见
  // .agents/notes/implemented/bug-fix/2026-09-28-drama-grid-background-audio.md
  bool get playsInline =>
      isFeed &&
      kind != 'manju' &&
      serverType != kChannelVideoEpisode &&
      serverType != kChannelVideo;
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

/// 当前短剧频道是不是浅色页（看剧 / 漫剧 / 最近 / 收藏）。
///
/// 壳层的悬浮 dock 与系统导航栏跟着它换肤：推荐频道压在全屏视频流上，
/// 保持深色玻璃；浅色页则回到主题画布，否则浅色外观下页面是奶白、
/// dock 还是一条黑的。
final ValueNotifier<bool> dramaLightPageNotifier = ValueNotifier<bool>(false);

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

/// 搜索行高度（首页 `fua` 的 51dp）：6dp 上留白 + 36dp 框体 + 9dp 下留白。
/// 原先沿用 `ap4.xml` 的 38dp，上下只剩 1dp，频道标签几乎贴着搜索框。
const _dramaSearchRowHeight = 51.0;

/// 频道条基础高度；大字号下由 [_dramaStripHeightFor] 抬高。
const _dramaStripBaseHeight = 38.0;

/// 频道条在大字号下随选中字号一起长高：24sp 放大后若仍锁死 38dp，会和
/// 3dp 指示条一起撞破条带。思路同首页 tab 条的 textScale 补偿。
///
/// 与 [_dramaSearchRowHeight] 一样放在文件顶层：顶栏是两处（悬浮层本身与
/// 依赖它的列表留白）共用的布局契约，不该藏在页面 State 里。
double _dramaStripHeightFor(BuildContext context) {
  final text = MediaQuery.textScalerOf(context).scale(24) * 1.1 + 6;
  return text > _dramaStripBaseHeight ? text + 4 : _dramaStripBaseHeight;
}

/// 悬浮顶栏（搜索行 + 频道条）在状态栏下方占的高度。
///
/// 顶栏是 `Stack` 里的悬浮层，不占页面布局：feed 的下拉提示、网格的顶部
/// 留白、最近/收藏的筛选行都得自己让出这段高度。桌面端不渲染搜索行
/// （搜索入口收敛到频道条右端图标），比手机端少一个 [_dramaSearchRowHeight]。
double dramaTopChromeHeight(BuildContext context) =>
    (isWindowsDesktop ? 0.0 : _dramaSearchRowHeight) +
    _dramaStripHeightFor(context);

/// 频道条的定位锚点：条数变化时只增删尾部，保留已有 index 的 `GlobalKey`。
///
/// 全部重建会让每个标签的 Element 换新：大字号选中过渡动画被打断，整条
/// 频道条闪一下（服务端频道表替换本地表时就能看到）。抽成纯函数也让这条
/// 规则可被单测直接钉住。
@visibleForTesting
List<GlobalKey> syncChannelTabKeys(List<GlobalKey> current, int count) {
  if (current.length == count) return current;
  return [
    for (var index = 0; index < count; index++)
      index < current.length
          ? current[index]
          : GlobalKey(debugLabel: 'drama_channel_$index'),
  ];
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
    this.hotCommentsLoader,
    this.seriesDetailLoader,
    this.seriesCommentLoader,
    this.bottomInset,
  });

  /// Test seams. The official feed plays the on-screen card inline and still
  /// opens the full player from a tap, which needs the series directory first.
  final Future<List<List<Chapter>>> Function(String id, String tab)?
  directoryLoader;
  final Future<Map<String, dynamic>> Function(String itemId, String tab)?
  contentLoader;
  final NativePlayer Function()? playerFactory;
  final ReaderStore? historyStore;

  /// 分区搜索页的构造缝。带上默认分类（短剧/漫剧），测试可断言落点；
  /// 缺省打开 [SearchPage]。
  final Widget Function(SearchCategory category)? searchPageBuilder;

  /// 服务端频道表加载器（测试缝）。默认走 `ApiClient.channelTabs()`。
  final Future<ChannelTable> Function()? channelLoader;

  /// 热评列表加载器（测试缝）。官方 feed 卡信息槽的热评行
  /// （`cj3.xml` 的 `InfoPanelHotCommentView`）与评论计数同源，缺省走
  /// `ApiClient.playletHotComments`（评论列表的 `hotOf` 本地筛选）。
  final Future<List<PlayletComment>> Function(String seriesId)?
  hotCommentsLoader;

  /// 详情页数据加载器（测试缝）。标题行「剧名 >」打开的 SeriesDetailPage
  /// 缺省走 `ApiClient.seriesDetail`；与 [hotCommentsLoader] 同一套缝。
  final Future<SeriesDetail> Function(String seriesId)? seriesDetailLoader;

  /// 详情页剧评加载器（测试缝）。缺省走 `ApiClient.playletComments`。
  final Future<PlayletCommentPage> Function(String seriesId)?
  seriesCommentLoader;

  /// 底部避让间距（主界面悬浮液态玻璃底栏），null 时按 context 动态计算。
  final double? bottomInset;

  @override
  ConsumerState<DramaPage> createState() => _DramaPageState();
}

class _DramaPageState extends ConsumerState<DramaPage>
    with WidgetsBindingObserver {
  static const _pullRefreshTrigger = 64.0;

  /// 顶栏在本页内容上方占的高度：移动端是搜索行 + 频道条两行；桌面端
  /// 不渲染搜索行——分区搜索入口收敛到频道条右端的搜索图标（壳层全局
  /// 搜索在短剧分区也隐藏），只占频道条一行，把垂直空间还给视频/网格。
  double get _topChromeHeight => dramaTopChromeHeight(context);

  double _effectiveBottomInset(BuildContext context) {
    if (widget.bottomInset != null) return widget.bottomInset!;
    // Scaffold(extendBody: true) 已将底栏高度自动合入 MediaQuery.padding.bottom，
    // 直接使用即可，避免二次叠加导致短剧 feed 控件悬空过高。
    return MediaQuery.paddingOf(context).bottom;
  }

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

  /// 上次滚轮切剧的时刻（桌面 feed）：一格滚轮常连发多个信号事件，
  /// 冷却内的都丢弃，保证一次滚动只切一条。
  DateTime? _lastWheelSwitchAt;

  /// Whether the containing route still shows this page (TickerMode). The bottom
  /// bar mutes a hidden destination instead of unmounting it.
  bool _tickerEnabled = true;

  /// True while a route we pushed is on top of the feed.
  bool _modalOpen = false;

  /// 内联播放器当前这次暂停是不是生命周期可见性分支（hidden/paused）造成
  /// 的，而不是用户手动暂停的。只有可见性暂停可以被随后的「回到 active」
  /// 撤销；手动暂停是用户意图，生命周期噪声不许推翻——Windows 上点一下别
  /// 的窗口只发 inactive，而桌面端把 inactive 算作 active，不分开记账的话
  /// 用户一暂停、一切窗视频就自己播回来；Android 退到后台再回前台同样会走
  /// active 分支，无条件续播也会把手动暂停拉起。
  bool _inlineVisibilityPaused = false;

  /// 长按中带打开的更多面板还在屏上（面板不销毁 inline 播放器，视频在
  /// 面板后面继续播，同官方 dialog；只挡掉手势与翻页）。
  bool _feedPanelOpen = false;
  bool _syncScheduled = false;

  /// feed 清屏播放（官方面板「清屏播放」行的会话态，与全页 chrome 的
  /// `_clearScreen` 同语义：不落盘，退出走面板的「退出清屏」行）。清屏
  /// 只作用于在屏卡：渐变遮罩、信息层、进度条与静音药丸整批隐藏。
  bool _feedClearScreen = false;

  /// 面板「字体大小」行级联打开的字号弹层（官方 `jm3.t0.m`：先关面板
  /// 再开弹层，`_modalOpen` 计账在弹层方法内部）。
  bool _pendingFeedFontScale = false;

  /// 面板「弹幕设置」行级联打开的设置面板（官方 `jm3.e`：先关面板
  /// 再开设置面板，与字号行同款级联，避免 `_modalOpen` 计账互相覆盖）。
  bool _pendingFeedDanmakuSettings = false;

  /// 面板「倍速」/「清晰度」入口行级联打开的档位弹层。feed 卡片没有播放页
  /// 那条显示当前档的底栏，长按面板是它唯一的换档入口，所以这两项在面板里
  /// 留行、点开弹层（与播放页「底栏直连档位弹层」同一份
  /// [showPlayletRateSheet] / [showPlayletQualitySheet]）。
  bool _pendingFeedRate = false;
  bool _pendingFeedQuality = false;

  /// feed 弹幕（官方信息流同样渲染弹幕，面板有开关行）：时间轴、取数
  /// 调度器与全局配置都复用播放页的那一套（CRIT-009 的时间字段约定在
  /// 模型层已固化）。vid -> seriesId 随每次切集登记，取数时按 vid 取，
  /// 在飞的旧请求不会拿到新剧的 seriesId。
  final DanmakuTimeline _feedDanmaku = DanmakuTimeline();
  bool _feedDanmakuEnabled = DanmakuPreference.defaultEnabled;
  DanmakuSettings _feedDanmakuSettings = const DanmakuSettings();
  final Map<String, String> _feedDanmakuSeriesIds = {};
  BackendRequest? _feedDanmakuFlight;
  Timer? _feedDanmakuTimer;

  /// 在屏卡的热评（官方 `SeriesHotCommentView`：holder 绑定时按剧拉评论
  /// 列表再本地筛「热评」，best-effort，拉不到就不显示行）。键为剧 id，
  /// 值先置空列表占位防止重复请求。
  final Map<String, List<PlayletComment>> _feedHotComments = {};

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

  /// 弹幕取数调度器（与播放页同款单飞 + seek 优先语义）。取数实现把
  /// seriesId 按 vid 回查，切剧的旧请求由调度器代际作废。
  late final DanmakuLoader _feedDanmakuLoader = DanmakuLoader(
    fetch: _fetchFeedDanmaku,
    onLoad: (page) {
      if (!mounted) return;
      final focus = _inline.position.value.inMilliseconds;
      setState(() {
        final retention = _feedDanmaku.load(page, focusMs: focus);
        if (retention.dropped) {
          _feedDanmakuLoader.noteRetainedRange(
            minOffsetMs: retention.minOffsetMs,
            maxOffsetMs: retention.maxOffsetMs,
            droppedBehind: retention.droppedBehind,
            droppedAhead: retention.droppedAhead,
            emptied: retention.emptied,
          );
        }
      });
    },
  );

  DramaChannel get _current => _channels[_channel];

  /// 冷启动回到上次看的频道（官方 SP `last_tab_type`）。类型不认识或该
  /// 频道已从服务端表里消失时留在「推荐」。
  int _restoredChannelIndex() {
    final type = DramaChannelPreferences.selectedType;
    if (type == null) return 0;
    final index = _channels.indexWhere((channel) => channel.serverType == type);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    // 频道必须在首帧前定下来：顶栏高亮、dock 肤色和首屏加载都读 `_current`。
    _channel = _restoredChannelIndex();
    // 重进页面时先把壳层的 dock 肤色对齐到当前频道（默认是推荐，黑）。
    // 放到帧后：initState 发生在壳层 build 期间，直接改 notifier 会触发
    // 壳层的 setState-in-build。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) dramaLightPageNotifier.value = !_current.playsInline;
    });
    if (isWindowsDesktop) {
      DesktopPlatform.fullscreen.addListener(_desktopFullscreenChanged);
    }
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
    // 弹幕开关/配置与字号档都是全局 SP（与播放页同键）：feed 与播放页
    // 互相跟随。字号档行尾文案读内存态，进页先加载一次。
    unawaited(_loadFeedDanmakuPreference());
    unawaited(_loadFeedDanmakuSettings());
    unawaited(ShortSeriesFontScale.load());
    _inline.activeVid.addListener(_onFeedVidChanged);
    _inline.seeked.addListener(_onFeedSeeked);
    // 进度心跳每秒喂一次调度器（与播放页一致：不逐帧，预取/补数都靠它）。
    _feedDanmakuTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_feedDanmakuEnabled || !_inline.playing.value) return;
      _feedDanmakuLoader.onProgress(_inline.position.value.inMilliseconds);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 首帧只加载**当前选中频道**的订阅流。provider 出厂停在
      // tabIndex=2（看剧＝tab_type 8），而默认频道是推荐（tabIndex=6＝
      // tab_type 16）：旧写法先 load tab=2，1~2s 后频道表回来再
      // selectTab(6) 整换可见列表——真机表现为先闪另一份快照的封面再
      // 起播（2026-09-28 DIAG 实锤：load tab=2 → 1.6s → load tab=6）。
      // 官方不变量：只挂载选中频道的流（SeriesMallFragment.Fh/Gh 只
      // attach selectIndex 那个 fragment，Xg 在响应前一直 loading），
      // 这里对齐为"只加载选中频道的流"。
      if (mounted) {
        final notifier = ref.read(dramaProvider.notifier);
        final tabIndex = ref.read(dramaProvider).tabIndex;
        final channel = _current;
        if (channel.isFeed) {
          if (tabIndex == channel.tabIndex) {
            // selectTab 对同下标是 no-op（重进页面时 provider 已停在本
            // 频道 tab）：直接补加载，保留旧的"重进即刷新"行为。
            unawaited(notifier.load());
          } else {
            // 目标 tab 尚未加载时 selectTab 内部会触发 load()。
            notifier.selectTab(channel.tabIndex);
          }
        }
      }
      if (mounted) unawaited(_loadChannels());
      if (mounted) _showGuide();
    });
  }

  @override
  void dispose() {
    if (isWindowsDesktop) {
      DesktopPlatform.fullscreen.removeListener(_desktopFullscreenChanged);
    }
    WidgetsBinding.instance.removeObserver(this);
    _inline.activeVid.removeListener(_onFeedVidChanged);
    _inline.seeked.removeListener(_onFeedSeeked);
    _feedDanmakuTimer?.cancel();
    _feedDanmakuFlight?.cancel();
    _feedDanmakuLoader.dispose();
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
                // 官方 SeriesMallVM：tabType 传当前频道、lastTabType 传上次
                // 选中的频道（SP last_tab_type，无值 -1），服务端据此算
                // tab_index。当前频道在 initState 已按 SP 恢复，两者不是一回事。
                tabType: current.serverType ?? kChannelVideoFeed,
                lastTabType: DramaChannelPreferences.lastType,
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
    dramaLightPageNotifier.value = !current.playsInline;
    if (current.isFeed) {
      ref.read(dramaProvider.notifier).selectTab(current.tabIndex);
    }
    if (!current.playsInline) {
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
    if (playbackAppIsActive(state)) {
      if (_tickerEnabled && !_modalOpen) {
        // Windows 上「切到别的窗口」只发 inactive，而 playbackAppIsActive
        // 在桌面端把 inactive 算作 active：无条件续播会把用户手动暂停的
        // 视频在焦点刚丢时就拉起来。Android 从后台回来同样会发 active，
        // 无条件续播也会推翻手动暂停。两端一致：只有可见性分支自己暂停过
        // 的那一次才许在这里恢复。
        if (!_inlineVisibilityPaused) return;
        _resumeInline();
        _scheduleInlineSync();
      }
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // 只在会话「打算播」时把这次暂停记到可见性头上：用户已经手动暂停
      // 的，回来时不许被当成可见性暂停恢复。判断有两种来源：激活还没走到
      // 起播那一步（播放器未建、或已建但尚未 play，此时 pause() 会把意图
      // 置假，不记账回前台就没人续播），以及播放器自身——桌面 chrome 是
      // 直接暂停播放器的，会话意图仍为真，只能读播放器状态分辨。
      final player = _inline.player;
      if (_inline.awaitingPlayback ||
          (player != null &&
              (player.playing ||
                  (player.playWhenReady && !player.completed)))) {
        _inlineVisibilityPaused = true;
      }
      // `inactive` 只是瞬态打断（下拉通知栏/控制中心）：feed 继续播；
      // 只有 hidden/paused/detached 才暂停（视频绝不能从后台出声）。
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
    if (!_current.playsInline) return null;
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
    final items = _visibleItems(ref.read(dramaProvider));
    if (widget.directoryLoader == null && _screenIndex + 1 < items.length) {
      unawaited(_inline.prefetchNextDrama(items[_screenIndex + 1]));
    }
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
    // 记住这次选择（官方把 `tab_type` 写回 SP）：下次冷启动直接落在这里。
    final type = channel.serverType;
    if (type != null) unawaited(DramaChannelPreferences.save(type));
    // 壳层的 dock / 系统导航栏跟着频道换肤（推荐＝深色，浅色页＝画布色）。
    dramaLightPageNotifier.value = !channel.playsInline;
    // Local channels read this device's own data; switching the provider would
    // silently load a feed nobody asked for.
    if (channel.isFeed) {
      ref.read(dramaProvider.notifier).selectTab(channel.tabIndex);
    }
    if (!channel.playsInline) {
      // Grids and local lists have no inline video: free any hidden decoder.
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

  Future<void> _refresh() =>
      ref.read(dramaProvider.notifier).load(manualRefresh: true);

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
    // 用户手动接管播放/暂停：可见性暂停的记账作废。
    _inlineVisibilityPaused = false;
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
    // 走到这里的续播都不是生命周期可见性恢复（滚动落定、路由返回、tab
    // 回到本页）：可见性记账就此作废，免得陈旧标记日后放行一次假恢复。
    _inlineVisibilityPaused = false;
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

  /// 长按中带打开的更多面板。官方链路：`jq3/x` 的 onLongPress 命中 K6 中带
  /// 且 `y7()` 成功 → `br3.y` 路由 → 与全页播放页同一个 `oi3/k` 面板构建器
  /// （from = `show_more_panel_from_long_click`），**行集也是同一份**。
  /// 样式跟随 `play_control_panel_style_v681`：浅色支（`#FAFAFA`、药丸、
  /// 无取消行）与深色 V2 同源；行随回调判空隐藏——清晰度要会话真有多档
  /// 流（官方 `oi3/k.P()` 门），听视频/离线缓存要集目录在场，清屏/弹幕/
  /// 字号是会话级状态。深色 V2 面板没有听视频/离线缓存/字号行（与全页
  /// 同支行集），所以那三行只在浅色支出现。
  ///
  /// 官方的面板是 dialog（`DialogType.MORE_PANEL`），不暂停播放器——视频在
  /// 面板后面继续播，这里同样只置 `_modalOpen` 挡手势，不走会销毁播放器的
  /// [_pushOverFeed]。
  Future<void> _showFeedMorePanel() async {
    // 全页播放器正在接管（_openPlayer 已销毁 inline 播放器）时不开面板。
    if (_feedPanelOpen || _openingId != null) return;
    _feedPanelOpen = true;
    final dark = PlayerStyleConfig.instance.morePanelDarkStyle;
    // 浅色支面板的内容会随夜间皮肤翻白（`PlayletMorePanelLight`），底色也
    // 得一起翻：否则深色主题下是 #FAFAFA 底配白字。
    final darkSheet = dark || Theme.of(context).brightness == Brightness.dark;
    // 倍速/清晰度入口行的行尾当前档（feed 卡片没有底栏显示它们）。
    final rateLabel = '${formatPlaybackRate(_inline.rate.value)}x';
    final qualityLabel = _inline.currentVariant?.name;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: darkSheet
            ? const Color(0xFF1C1C1C)
            : const Color(0xFFFAFAFA),
        barrierColor: Colors.transparent,
        sheetAnimationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 200),
          reverseDuration: Duration(milliseconds: 200),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(dark ? 12 : 16),
          ),
        ),
        builder: (context) {
          if (!dark) {
            return PlayletMorePanelLight(
              // 倍速/清晰度入口行：官方是面板内的药丸行，这里改成点开
              // 档位弹层（feed 卡片没有底栏当前档可点）。
              rateLabel: rateLabel,
              onOpenRate: () => _pendingFeedRate = true,
              qualityLabel: qualityLabel,
              onOpenQuality: _inline.variants.length > 1
                  ? () => _pendingFeedQuality = true
                  : null,
              clearScreen: _feedClearScreen,
              onToggleClearScreen: () =>
                  setState(() => _feedClearScreen = !_feedClearScreen),
              danmakuEnabled: _feedDanmakuEnabled,
              onToggleDanmaku: () => unawaited(_toggleFeedDanmaku()),
              // 官方 `jm3.e`：弹幕设置入口在弹幕开关之后（与全页同门）。
              onOpenDanmakuSettings: () => _pendingFeedDanmakuSettings = true,
              // 官方 `jm3.t0`：行尾当前档 + 点击级联打开字号弹层。
              fontScaleLabel: ShortSeriesFontScale.label,
              onOpenFontSettings: () => _pendingFeedFontScale = true,
              // 官方 `jm3.d0.y`/`jm3.u`：行点击随面板关闭直接打开听书页/
              // 选集下载弹窗（与全页 chrome 同款直推；集目录不在场——
              // 未起播/单集搜索回落——时整行不出现）。
              onOpenListenMode: _inline.episodes.isNotEmpty
                  ? () => unawaited(_openFeedListenMode())
                  : null,
              onOpenOfflineCache: _inline.episodes.isNotEmpty
                  ? () => unawaited(_openFeedDownloadSheet())
                  : null,
            );
          }
          return PlayletMorePanel(
            // 倍速/清晰度入口行（与浅色支同门，点开档位弹层）。
            rateLabel: rateLabel,
            onOpenRate: () => _pendingFeedRate = true,
            qualityLabel: qualityLabel,
            onOpenQuality: _inline.variants.length > 1
                ? () => _pendingFeedQuality = true
                : null,
            // feed 没有画面撑满，行随回调缺省隐藏。
            fillScreen: false,
            defaultMute: _inline.muted.value,
            onDefaultMuteChanged: (_) => unawaited(_inline.toggleMute()),
            danmakuEnabled: _feedDanmakuEnabled,
            onToggleDanmaku: () => unawaited(_toggleFeedDanmaku()),
            // 官方 `jm3.e`：弹幕设置入口在弹幕开关之后（与全页同门）。
            onOpenDanmakuSettings: () => _pendingFeedDanmakuSettings = true,
            clearScreen: _feedClearScreen,
            onToggleClearScreen: () =>
                setState(() => _feedClearScreen = !_feedClearScreen),
          );
        },
      );
    } finally {
      _feedPanelOpen = false;
      if (mounted) setState(() {});
    }
    // 「字体大小」「弹幕设置」行是级联行（官方 jm3.t0.m / jm3.e：面板收起
    // 后再开弹层，避免 _modalOpen 计账互相覆盖）；听视频/离线缓存行走
    // 面板行回调直推。
    if (!mounted) return;
    if (_pendingFeedFontScale) {
      _pendingFeedFontScale = false;
      unawaited(_showFeedFontScaleSheet());
    }
    // 「弹幕设置」行同款级联（官方 jm3.e）：面板收起后再开设置面板。
    if (_pendingFeedDanmakuSettings) {
      _pendingFeedDanmakuSettings = false;
      unawaited(_showFeedDanmakuSettings());
    }
    // 「倍速」「清晰度」入口行：面板收起后再开档位弹层，选中即落地。
    if (_pendingFeedRate) {
      _pendingFeedRate = false;
      unawaited(_showFeedRateSheet());
    }
    if (_pendingFeedQuality) {
      _pendingFeedQuality = false;
      unawaited(_showFeedQualitySheet());
    }
  }

  /// feed 的倍速档位弹层（与播放页底栏「倍速」共用 [showPlayletRateSheet]）。
  Future<void> _showFeedRateSheet() async {
    if (_modalOpen || _openingId != null) return;
    setState(() => _modalOpen = true);
    try {
      final picked = await showPlayletRateSheet(
        context,
        rate: _inline.rate.value,
        dark:
            PlayerStyleConfig.instance.morePanelDarkStyle ||
            Theme.of(context).brightness == Brightness.dark,
      );
      if (picked != null) await _inline.selectRate(picked);
    } finally {
      _modalOpen = false;
      if (mounted) setState(() {});
    }
  }

  /// feed 的清晰度档位弹层（与播放页底栏「清晰度」共用
  /// [showPlayletQualitySheet]）。
  Future<void> _showFeedQualitySheet() async {
    if (_modalOpen || _openingId != null) return;
    setState(() => _modalOpen = true);
    try {
      final picked = await showPlayletQualitySheet(
        context,
        variants: _inline.variants,
        currentUrl: _inline.currentVariant?.url,
        dark:
            PlayerStyleConfig.instance.morePanelDarkStyle ||
            Theme.of(context).brightness == Brightness.dark,
      );
      if (picked != null) _switchFeedQuality(picked);
    } finally {
      _modalOpen = false;
      if (mounted) setState(() {});
    }
  }

  /// 清晰度切换（官方 `bgw`）：Toast 立即出，不等换流完成。
  void _switchFeedQuality(EpisodeVariant variant) {
    if (!mounted) return;
    PlayerToast.show(context, '清晰度已成功切换至${variant.name}');
    unawaited(_inline.switchVariant(variant));
  }

  /// 字号弹层（官方 `nm3.e`，与播放页共用同一张 [showPlayletFontScaleSheet]）。
  Future<void> _showFeedFontScaleSheet() async {
    if (_modalOpen || _openingId != null) return;
    setState(() => _modalOpen = true);
    try {
      await showPlayletFontScaleSheet(context);
    } finally {
      _modalOpen = false;
      if (mounted) setState(() {});
    }
  }

  /// 弹幕设置面板（官方 `ay1/v.java`，与播放页共用同一张
  /// [PlayletDanmakuSettingsPanel]）：滑杆变化实时回调并落盘（官方
  /// UpdateDanmakuConfigEvent），feed 与播放页读同一份 `danmaku_config`。
  /// 横屏用 372dp 右对齐的面板形态（与播放页同款）。
  Future<void> _showFeedDanmakuSettings() async {
    if (_modalOpen || _openingId != null) return;
    setState(() => _modalOpen = true);
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        backgroundColor: landscape
            ? Colors.transparent
            : const Color(0xFF1C1C1C),
        shape: landscape
            ? null
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        builder: (sheetContext) {
          final panel = PlayletDanmakuSettingsPanel(
            settings: _feedDanmakuSettings,
            landscape: landscape,
            onChanged: (settings) {
              setState(() => _feedDanmakuSettings = settings);
              unawaited(DanmakuSettings.save(settings));
            },
            onReset: () => PlayerToast.show(context, '设置成功'),
          );
          if (!landscape) return panel;
          return Container(
            alignment: Alignment.bottomRight,
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: SizedBox(
              width: 372,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1C),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: panel,
              ),
            ),
          );
        },
      );
    } finally {
      _modalOpen = false;
      if (mounted) setState(() {});
    }
  }

  /// 离线缓存（官方 `jm3.u`）：面板行 → 选集下载弹窗，剧集目录直接用
  /// 会话已加载的这份（feed 激活时就拉过）。弹窗与面板同为 dialog 语义，
  /// 不销毁播放器。
  Future<void> _openFeedDownloadSheet() async {
    if (_modalOpen || _openingId != null) return;
    final item = _currentItem();
    if (item == null) return;
    final episodes = _inline.episodes;
    if (episodes.isEmpty) return;
    _modalOpen = true;
    try {
      await DramaDownloadSheet.show(
        context,
        seriesId: item.seriesId ?? item.id,
        title: item.title,
        cover: item.cover,
        episodes: episodes,
        // 与播放页同源：「往后N集」与默认分组从正在播的那集算，画质只列
        // 本集真实给到的档位。
        currentIndex: (_inline.activeEpisodeIndex ?? 0).clamp(
          0,
          episodes.length - 1,
        ),
        qualities: _inline.variants,
      );
    } finally {
      _modalOpen = false;
      if (mounted) setState(() {});
    }
  }

  /// 听视频（官方 `jm3.d0.y` 的听书模式页语义）：会话目标剧与当前集交给
  /// 听书页；关闭时把「听到哪一集 + 进度」写回，正在看的卡还在原剧就按
  /// 听到的位置续播，听期间划走了就只落历史。
  ///
  /// 听书页建自己的播放器，所以进页前与推全页播放器同一条纪律：销毁
  /// inline 播放器并清空池，不允许两个原生实例同时存活。`_modalOpen`
  /// 必须先于销毁置位——销毁清空 activeVid 会触发页面重建，先挡住
  /// [_syncInline] 才不会在销毁窗口里把刚拆掉的卡重新起播。
  Future<void> _openFeedListenMode() async {
    if (_modalOpen || _openingId != null) return;
    final item = _currentItem();
    final series = _inline.activeSeries;
    final episodes = List<Chapter>.of(_inline.episodes);
    final index = _inline.activeEpisodeIndex;
    if (item == null || series == null || episodes.isEmpty || index == null) {
      return;
    }
    _modalOpen = true;
    (int, Duration)? result;
    try {
      await _inline.disposePlayer();
      if (!mounted) return;
      result = await Navigator.of(context).push<(int, Duration)>(
        MaterialPageRoute<(int, Duration)>(
          builder: (_) => ListenModePage(
            seriesTitle: series.title,
            coverUrl: series.cover,
            episodes: episodes,
            initialIndex: index,
            resolveSource: _inline.resolveListenSource,
          ),
        ),
      );
    } finally {
      _modalOpen = false;
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    final (listenIndex, position) = result ?? (index, Duration.zero);
    final clampedIndex = listenIndex.clamp(0, episodes.length - 1);
    // 官方 sync_progress_strategy_listen_mode：先落历史再续播，中途被杀
    // 也不丢听书进度。
    await _inline.persistListenProgress(
      series,
      episodes,
      clampedIndex,
      position,
    );
    if (!mounted) return;
    if (_currentItem()?.id == item.id) {
      // 还在原卡：按听到的集与位置续播（激活路径消费显式起点）。
      await _inline.activate(
        item,
        startEpisodeIndex: clampedIndex,
        startPosition: position,
      );
    } else {
      // 听期间划到了别的卡：按常规路径激活在屏卡，听书进度已落历史。
      _syncInline();
    }
  }

  /// 官方开关切换（`i95/i.java:339-346`）：落盘 + Toast；重新打开时整池
  /// 重灌，按当前播放位置续取。
  Future<void> _toggleFeedDanmaku() async {
    final enabled = !_feedDanmakuEnabled;
    setState(() => _feedDanmakuEnabled = enabled);
    _feedDanmakuLoader.setEnabled(enabled);
    if (enabled) _restartFeedDanmaku();
    await DanmakuPreference.save(enabled);
    if (!mounted) return;
    PlayerToast.show(
      context,
      enabled ? danmakuEnabledToast : danmakuDisabledToast,
    );
  }

  /// 弹幕开关与配置都是全局 SP（官方 `video_danmaku_switch_sp` /
  /// `danmaku_config`），与播放页读同一份。
  Future<void> _loadFeedDanmakuPreference() async {
    final enabled = await DanmakuPreference.load();
    if (!mounted) return;
    setState(() => _feedDanmakuEnabled = enabled);
    _feedDanmakuLoader.setEnabled(enabled);
  }

  Future<void> _loadFeedDanmakuSettings() async {
    final settings = await DanmakuSettings.load();
    if (!mounted) return;
    setState(() => _feedDanmakuSettings = settings);
  }

  /// 切集/重开开关：时间轴整池重灌，调度器按当前播放位置发首批（官方
  /// ON_VIDEO_PLAY 语义；听书回传的显式起点在激活早期就挂上了 [InlineVideoPlayback.position]）。
  void _restartFeedDanmaku() {
    final vid = _inline.activeVid.value;
    _feedDanmaku.reset();
    _feedDanmakuFlight?.cancel();
    _feedDanmakuFlight = null;
    if (vid == null || vid.isEmpty) return;
    final series = _inline.activeSeries;
    if (series != null) {
      _feedDanmakuSeriesIds[vid] = series.seriesId ?? series.id;
      // 会话内看过的剧有限，但长会话也要封顶：保留最近 64 条映射。
      while (_feedDanmakuSeriesIds.length > 64) {
        _feedDanmakuSeriesIds.remove(_feedDanmakuSeriesIds.keys.first);
      }
    }
    final startMs = _inline.position.value.inMilliseconds;
    _feedDanmakuLoader.reset(vid: vid, startMs: startMs < 0 ? 0 : startMs);
    if (mounted) setState(() {});
  }

  void _onFeedVidChanged() {
    final vid = _inline.activeVid.value;
    if (vid == null || vid.isEmpty) {
      // 播放器销毁/入池：时间轴清空，调度器等下一个 vid。
      _feedDanmaku.reset();
      _feedDanmakuFlight?.cancel();
      _feedDanmakuFlight = null;
      if (mounted) setState(() {});
      return;
    }
    _restartFeedDanmaku();
  }

  /// 拖动进度条与换画质回跳的最终目标（官方 `ON_SEEK_FINISH`）。
  void _onFeedSeeked() {
    _feedDanmakuLoader.onSeek(_inline.seeked.value.inMilliseconds);
  }

  /// 弹幕取数：与播放页同一条接口（`:group_id` = vid，series 进
  /// `business_param.book_id`，时间毫秒）。seriesId 按 vid 回查：在飞的
  /// 旧请求在切剧后完成时也不会误挂新剧的 id。
  Future<PlayletCommentPage> _fetchFeedDanmaku(DanmakuFetchRequest request) {
    final flight = BackendRequest();
    _feedDanmakuFlight = flight;
    return ApiClient.instance.withCancellation(flight, () {
      return ApiClient.instance.playletDanmaku(
        request.vid,
        seriesId: _feedDanmakuSeriesIds[request.vid] ?? '',
        startOffsetMs: request.startOffsetMs,
        duration: _inline.duration.value,
        cursor: request.cursor,
      );
    });
  }

  /// 在屏卡的热评列表。官方在 holder 绑定时按剧请求（评论列表与计数
  /// 同源），这里只在剧首次上屏时请求一次，失败留空（行不显示）。
  Future<void> _loadFeedHotComments(MediaItem item) async {
    if (_feedHotComments.containsKey(item.id)) return;
    _feedHotComments[item.id] = const [];
    try {
      final loader = widget.hotCommentsLoader;
      final comments = loader != null
          ? await loader(item.id)
          : (await ApiClient.instance.playletHotComments(item.id)).hotComments;
      if (!mounted) return;
      setState(() => _feedHotComments[item.id] = comments);
    } catch (_) {
      // best-effort：官方拉不到热评同样整行不出现。
    }
  }

  /// 官方 feed 热评点击 → 评论面板（`SeriesHotCommentView.E`
  /// `:468-559` 按 dataType 组 Comment/Reply 定位参数）。面板是纯列表，
  /// 不建播放器，所以不走会销毁 inline 播放器的 [_pushOverFeed]，视频在
  /// 面板后面继续播（官方 dialog 语义）。
  Future<void> _openFeedComments(MediaItem item, PlayletComment comment) async {
    if (_modalOpen || _feedPanelOpen || _openingId != null) return;
    final isReply = comment.dataType == UgcRelativeType.reply;
    setState(() => _modalOpen = true);
    try {
      await PlayletCommentPanel.show(
        context,
        seriesId: item.id,
        focusCommentId: isReply ? comment.parentCommentId : comment.id,
        focusReplyId: isReply ? comment.id : '',
      );
    } finally {
      _modalOpen = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dramaProvider);
    final channel = _current;
    final items = _visibleItems(state);
    // 浅色页（看剧/漫剧/最近/收藏）跟随外观色板：深色 / OLED 下不能再用
    // 白底深字，否则整页和主题完全脱节。视频流仍固定黑底。
    final palette = HomePalette.of(context);
    _syncTickerMode();
    _scheduleInlineSync();
    // 官方看剧(8, CommonDoubleRow 两列)与漫剧(24, CommonThreeRow 三列)频道
    // 都是浅色海报瀑布格（StaggeredFeedTab）；最近/收藏列表也是浅色页；
    // 只有推荐(16)等视频流频道是黑底竖滑播放。状态栏图标亮度跟着页面走。
    final isVideoFlow = channel.playsInline;
    final lightPage = !isVideoFlow;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 深色外观下浅色页也是深色画布，状态栏图标要跟着换成浅色。
      value:
          (lightPage && !palette.dark
                  ? SystemUiOverlayStyle.dark
                  : SystemUiOverlayStyle.light)
              .copyWith(
                // 预设样式把导航栏写成纯黑：浅色页底部要跟画布同色，
                // 否则壳层 dock 换成浅色了，最底下还压着一条黑带。
                systemNavigationBarColor: lightPage
                    ? palette.canvas
                    : Colors.black,
                systemNavigationBarDividerColor: lightPage
                    ? palette.canvas
                    : Colors.black,
                systemNavigationBarIconBrightness: lightPage && !palette.dark
                    ? Brightness.dark
                    : Brightness.light,
              ),
      child: Scaffold(
        backgroundColor: lightPage ? palette.canvas : Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              // 最近 and 收藏 are lists in the official client too: the recent
              // list comes from the device's own history and the follow list
              // from the account, so neither is a video feed here either.
              // 看剧/漫剧是浅色海报瀑布格（官方 StaggeredFeedTab，
              // `client_template` 12/13），只有推荐走全屏竖滑播放流。
              child: TabSwipeArea(
                index: _channel,
                count: _channels.length,
                onSelect: _selectChannel,
                // 播放器打开、弹窗、最近频道编辑时都不该被横滑打断。
                enabled: !_modalOpen && _openingId == null && !_recentEditing,
                // 整片横滑都切频道，播放流也一样。唯一的例外是底部进度条：
                // 它自己带横向拖动、又比这里内层，所以只有那 24dp 归调进度，
                // 其余区域一律切频道（见 TabSwipeArea 的类文档）。
                // 只让内容跟手横移：频道条固定在顶部，切换后立刻显示新的
                // 选中项，不被动画拖着走。
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
            ),
            if (_pullDistance > 0)              Positioned(
                top: MediaQuery.paddingOf(context).top + _topChromeHeight + 8,
                left: 0,
                right: 0,
                child: _PullRefreshHint(
                  armed: _pullDistance >= _pullRefreshTrigger,
                  color: lightPage ? palette.ink : Colors.white,
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
                        _topChromeHeight +
                        56,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          // 浅色支沿用官方奶白渐变；深色 / OLED 取当前画布色
                          // 淡出，只负责把海报挡在顶栏后。
                          colors: [
                            palette.dark
                                ? palette.canvas
                                : const Color(0xFFFFF3E6),
                            palette.dark
                                ? palette.canvas
                                : const Color(0xFFFFFFFF),
                            palette.dark
                                ? palette.canvas.withValues(alpha: 0)
                                : const Color(0x00FFFFFF),
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (!_recentEditing &&
                !(isWindowsDesktop && DesktopPlatform.fullscreen.value))
              Positioned(
                // 推荐（视频流）与看剧/漫剧（浅色页）切换时，下面的浅色
                // 渐变背板会整体插入或移除，Stack 的子项下标随之错位。
                // 不挂 key 的话顶栏会被整棵重建，标签放大动画一帧就走完。
                key: const ValueKey('drama_top_bar'),
                top: 0,
                left: 0,
                right: 0,
                child: _TopBar(
                  channels: _channels,
                  selected: _channel,
                  onSelect: _selectChannel,
                  onSearch: _openSearch,
                  // 占位文案跟着频道语境走：漫剧频道搜漫剧，其余搜短剧。
                  hint: _current.kind == 'manju' ? '请输入漫剧名或主演名' : '请输入短剧名或主演名',
                  // 官方浅色页（看剧/漫剧）的顶栏换浅肤：深色字 + 浅灰搜索框。
                  light: lightPage,
                ),
              ),
            // 「上滑查看更多视频」：官方挂在全屏容器上、`gravity=bottom|center`
            // + bottomMargin 94dp（`pp3.f.n()`）。注意官方主界面（`d5.xml`）的
            // 底部 tab（50dp）是**悬浮压在 feed 上的**，所以 94dp 从 tab 底边算，
            // 提示悬在 tab 栏上方约 44dp。本页 feed 止步于 NavigationBar 顶边，
            // 同一视觉位置 = 94 - 官方 tab 高 50 = **44dp**。
            if (_guideMounted && !isWindowsDesktop)
              Positioned(
                left: 16,
                right: 16,
                bottom: _effectiveBottomInset(context) + 16,
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
    if (isWindowsDesktop) {
      columns = (MediaQuery.sizeOf(context).width / 190).floor().clamp(3, 9);
    }
    final bottomInset = _effectiveBottomInset(context);
    return NotificationListener<ScrollNotification>(
      onNotification: _onGridScroll,
      child: GridView.builder(
        key: Key(gridKey),
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.paddingOf(context).top + _topChromeHeight + 12,
          12,
          bottomInset + 20,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 8,
          mainAxisSpacing: 16,
          // 海报约 5:7 + 片名 + 「分类·集数」；两列格片名可占两行。
          childAspectRatio: isWindowsDesktop
              ? .58
              : columns == 2
              ? 0.56
              : 0.52,
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
    if (isWindowsDesktop && state.error == null && items.isNotEmpty) {
      return _desktopFeed(items);
    }
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

          // 记录停留卡片，快照保存时作为下次冷启动的续接点（官方落地缓存
          // `recordNextVideoData` 的等价物：单条视频 + 位置）。
          if (index < items.length) {
            ref.read(dramaProvider.notifier).noteCurrentVid(items[index].id);
          }

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
          // 官方在 holder 绑定时拉热评；这里只在剧首次上屏时请求一次。
          if (onScreen) unawaited(_loadFeedHotComments(item));
          return _DramaFeedCard(
            item: item,
            bottomInset: _effectiveBottomInset(context),
            opening: _openingId == item.id,
            playback: onScreen ? _inline : null,
            video: onScreen
                ? _InlineVideoLayer(item: item, playback: _inline)
                : null,
            // 弹幕与视频同裁剪（12dp 圆角内），清屏态整层不出现（与播放
            // 页 chrome 的 `!_clearScreen` 同门）。
            danmakuOverlay: onScreen
                ? _FeedDanmakuOverlay(
                    item: item,
                    playback: _inline,
                    entries: _feedDanmaku.entries,
                    enabled: _feedDanmakuEnabled,
                    clearScreen: _feedClearScreen,
                    settings: _feedDanmakuSettings,
                  )
                : null,
            errorOverlay: onScreen
                ? _InlineVideoError(
                    item: item,
                    playback: _inline,
                    onRetry: () => unawaited(_inline.activate(item)),
                  )
                : null,
            // 「观看全集·N集」药丸 = 进全页播放器（官方 `nk3.c.e` →
            // `zf3.c.s` goToSingleFeed）。
            onFullscreen: () => _openPlayer(item),
            // 右侧横屏钮是另一条路：官方 `nk3.c.g` → `zf3.c.w` →
            // `transformToLandActivity`，起独立横屏页。
            onLandscape: () => _openPlayer(item, openFullScreen: true),
            onQuickCatalog: () => _openQuickCatalog(item),
            // 标题行「剧名 >」= 官方进剧集详情页的入口（ql3/v0.a1）。
            onOpenSeriesDetail: () => _openSeriesDetail(item),
            onTogglePlay: _togglePlay,
            onOpenMorePanel: () => unawaited(_showFeedMorePanel()),
            clearScreen: onScreen && _feedClearScreen,
            hotComments: _feedHotComments[item.id] ?? const [],
            onHotCommentTap: (comment) =>
                unawaited(_openFeedComments(item, comment)),
            hotCommentActive:
                onScreen && !_modalOpen && !_feedPanelOpen && !_paging,
          );
        },
      ),
    );
  }

  void _desktopFullscreenChanged() {
    if (mounted) setState(() {});
  }

  void _desktopNextDrama(List<MediaItem> items, int delta) {
    final index = (_screenIndex + delta).clamp(0, items.length - 1);
    if (index == _screenIndex) return;
    setState(() => _screenIndex = index);
    ref.read(dramaProvider.notifier).noteCurrentVid(items[index].id);
    if (index >= items.length - 2) {
      unawaited(ref.read(dramaProvider.notifier).loadMore());
    }
    _syncInline();
  }

  /// 桌面滚轮切剧：600ms 冷却，一次滚动只切一条；推了路由（详情/播放页）
  /// 时不响应，滚轮留给上层页面。
  void _desktopWheelDrama(List<MediaItem> items, int delta) {
    if (_modalOpen) return;
    final now = DateTime.now();
    final last = _lastWheelSwitchAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 600)) {
      return;
    }
    _lastWheelSwitchAt = now;
    _desktopNextDrama(items, delta);
  }

  Widget _desktopFeed(List<MediaItem> items) {
    final item = items[_screenIndex.clamp(0, items.length - 1)];
    return ListenableBuilder(
      listenable: Listenable.merge([
        _inline.textureId,
        _inline.playing,
        _inline.duration,
        _inline.videoSize,
        _inline.firstFrame,
        _inline.error,
        _inline.activeVid,
      ]),
      builder: (context, _) => Focus(
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.pageDown) {
            _desktopNextDrama(items, 1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.pageUp) {
            _desktopNextDrama(items, -1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: EdgeInsets.only(
            top: DesktopPlatform.fullscreen.value ? 0 : _topChromeHeight,
          ),
          child: Column(
            children: [
              Expanded(
                child: VideoPlayerChrome(
                  key: const ValueKey('desktop-feed-player'),
                  player: _inline.player,
                  title: item.title,
                  seriesTitle: item.title,
                  synopsis: item.intro,
                  onWheelNavigate: (delta) => _desktopWheelDrama(items, delta),
                  episodes: _inline.episodes,
                  currentIndex: _inline.activeEpisodeIndex ?? 0,
                  duration: _inline.duration.value,
                  playing: _inline.playing.value,
                  enabled: _inline.player?.isCreated ?? false,
                  shortSeries: true,
                  onSelectEpisode: (index) =>
                      _inline.activate(item, startEpisodeIndex: index),
                  onError: (_) => _inline.error.value = '播放失败，请重试',
                  onOpenSeriesDetail: () => _openSeriesDetail(item),
                  onComments: () =>
                      PlayletCommentPanel.show(context, seriesId: item.id),
                  onOpenOfflineCache: _inline.episodes.isEmpty
                      ? null
                      : () => unawaited(_openFeedDownloadSheet()),
                  onOpenListenMode: _inline.episodes.isEmpty
                      ? null
                      : () => unawaited(_openFeedListenMode()),
                  onPlaybackRateChanged: _inline.selectRate,
                  onPlaybackVolumeChanged: _inline.setVolume,
                  defaultMute: _inline.muted.value,
                  qualityVariants: _inline.variants,
                  currentQualityUrl: _inline.currentVariant?.url,
                  onQualitySelected: (variant) =>
                      unawaited(_inline.switchVariant(variant)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _InlineVideoLayer(item: item, playback: _inline),
                      _FeedDanmakuOverlay(
                        item: item,
                        playback: _inline,
                        entries: _feedDanmaku.entries,
                        enabled: _feedDanmakuEnabled,
                        clearScreen: false,
                        settings: _feedDanmakuSettings,
                      ),
                      _InlineVideoError(
                        item: item,
                        playback: _inline,
                        onRetry: () => unawaited(_inline.activate(item)),
                      ),
                    ],
                  ),
                ),
              ),
              if (!DesktopPlatform.fullscreen.value)
                SizedBox(
                  height: 44,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _screenIndex > 0
                            ? () => _desktopNextDrama(items, -1)
                            : null,
                        icon: const Icon(Icons.keyboard_arrow_up),
                        label: const Text('上一条（Page Up）'),
                      ),
                      const SizedBox(width: 24),
                      Text(
                        '${_screenIndex + 1} / ${items.length}',
                        style: const TextStyle(color: Colors.white60),
                      ),
                      const SizedBox(width: 24),
                      TextButton.icon(
                        onPressed: _screenIndex + 1 < items.length
                            ? () => _desktopNextDrama(items, 1)
                            : null,
                        icon: const Icon(Icons.keyboard_arrow_down),
                        label: const Text('下一条（Page Down）'),
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

  /// The official card opens the play page directly
  /// (`VideoInfiniteHolderV3` → `ShortSeriesLaunchArgs`), so the directory is
  /// fetched here and the player is pushed with the resume episode selected.
  ///
  /// [startEpisodeIndex] 非空时跳过续播推断（详情页点选集进来指定目标集）。
  Future<void> _openPlayer(
    MediaItem item, {
    int? startEpisodeIndex,
    List<Chapter>? loadedEpisodes,
    SeriesDetail? initialDetail,

    /// 进页即横屏全屏（feed 卡片右侧的横屏钮）。官方那颗钮不是「观看全集」
    /// 的同一条路，它 `transformToLandActivity` 起独立
    /// `ShortSeriesLandActivity`（`jq3/x.java:4499-4538`）。
    bool openFullScreen = false,
  }) async {
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
      var volumes = loadedEpisodes != null
          ? [loadedEpisodes]
          : loader != null
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
      final index = (startEpisodeIndex ?? resumeEpisodeIndex(saved, eps) ?? 0)
          .clamp(0, eps.length - 1);
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
            initialSeriesDetail: initialDetail,
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
            openFullScreen: openFullScreen,
            aiGenerated: item.aiGenerated,
          ),
        ),
      );
    } catch (error) {
      if (mounted) PlayerToast.show(context, userFacingError(error));
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
    unawaited(_pushOverFeed(() => openBookDetail(context, item)));
  }

  /// feed 卡片标题行「剧名 >」→ 剧集详情页（官方 `ql3/v0.a1()` 默认分支，
  /// 埋点 `enter_from="title"`；feed 信息区与播放页信息区共用这个 Presenter）。
  ///
  /// 详情页点播放/选集时：先 pop 详情回到 feed，再走 `_openPlayer` 复用目录
  /// 推整页播放器（`_pushOverFeed` 已把 inline 播放器销毁，不会双实例）。
  void _openSeriesDetail(MediaItem item) {
    unawaited(
      _pushOverFeed(
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SeriesDetailPage(
              seriesId: item.seriesId ?? item.id,
              kind: item.kind,
              title: item.title,
              cover: item.cover,
              // feed 入口没带目录，详情页自拉；测试缝跟随 DramaPage 的
              // directoryLoader（按作品种类选择短剧或漫剧）。
              directoryLoader: widget.directoryLoader == null
                  ? null
                  : (sid) => widget.directoryLoader!(
                      sid,
                      item.kind == 'manju' ? '漫剧' : '短剧',
                    ),
              historyStore: widget.historyStore,
              seriesLoader: widget.seriesDetailLoader,
              commentLoader: widget.seriesCommentLoader,
              onPlaySelection: (index, episodes, detail) {
                Navigator.of(context).pop();
                unawaited(
                  _openPlayer(
                    item,
                    startEpisodeIndex: index,
                    loadedEpisodes: episodes,
                    initialDetail: detail,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _openQuickCatalog(MediaItem item) {
    if (_modalOpen || _openingId != null) return;
    PlayletQuickCatalogSheet.show(
      context,
      item: item,
      directoryLoader: widget.directoryLoader,
      historyStore: widget.historyStore,
      onEpisodeSelected: (index, episodes) {
        unawaited(
          _openPlayer(item, startEpisodeIndex: index, loadedEpisodes: episodes),
        );
      },
      onFullscreen: () => unawaited(_openPlayer(item)),
      seriesLoader: widget.seriesDetailLoader,
      onRelatedSeriesSelected: (entry) => _openSeriesDetail(
        MediaItem(
          id: entry.id,
          seriesId: entry.id,
          title: entry.title,
          cover: entry.cover,
          kind: entry.kind,
          author: '',
          badge: '',
          ep: entry.episodeCount > 0 ? '共 ${entry.episodeCount} 集' : '',
        ),
      ),
    );
  }

  void _openSearch() {
    // 官方短剧分区的搜索落在对应内容分类，而不是「综合」：漫剧频道搜
    // 漫剧，其余频道（推荐/看剧/最近/收藏）的内容只可能是短剧或漫剧，
    // 默认短剧（2026-10-25 用户要求把频道语境带进搜索）。
    final category = _current.kind == 'manju'
        ? SearchCategory.manju
        : SearchCategory.video;
    unawaited(
      _pushOverFeed(
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                widget.searchPageBuilder?.call(category) ??
                SearchPage(initialCategory: category),
          ),
        ),
      ),
    );
  }
}

/// The floating top bar: a 51dp search row over a 38dp channel strip, both on a
/// light scrim so the official black-on-white text stays readable over video.
class _TopBar extends StatefulWidget {
  final List<DramaChannel> channels;
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;

  /// 搜索框占位文案，跟着频道语境走：漫剧频道搜漫剧，其余频道搜短剧。
  final String hint;

  /// 官方浅色页（漫剧）的顶栏浅肤：深色字、浅灰搜索框。默认 false =
  /// 黑底视频流的浅色字顶栏（书城/短剧语境）。
  final bool light;

  const _TopBar({
    required this.channels,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
    required this.hint,
    this.light = false,
  });

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  /// 频道条自己的滚动控制器：选中项可能不在视口里（冷启动按 SP 恢复到
  /// 「收藏」、大字号下五个标签总宽超出屏幕）。
  final ScrollController _strip = ScrollController();

  /// 每个标签的定位锚点，「把选中项滚进视口」靠它取位置。
  List<GlobalKey> _tabKeys = const [];

  @override
  void initState() {
    super.initState();
    _syncTabKeys();
    // 首帧就要滚到位：SP 恢复的频道可能停在视口右端之外。
    _revealSelected(animate: false);
  }

  @override
  void didUpdateWidget(covariant _TopBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 服务端频道表替换本地表时条数会变，锚点跟着重建。
    if (oldWidget.channels.length != widget.channels.length) _syncTabKeys();
    if (oldWidget.selected != widget.selected) {
      _revealSelected(animate: !MediaQuery.disableAnimationsOf(context));
    }
  }

  @override
  void dispose() {
    _strip.dispose();
    super.dispose();
  }

  void _syncTabKeys() {
    _tabKeys = syncChannelTabKeys(_tabKeys, widget.channels.length);
  }

  /// 把选中标签居中滚进视口。
  ///
  /// `ensureVisible` 作用于最近的一层 Scrollable —— 频道条自己，不会带动
  /// 下面的 feed；减少动画（无障碍）时不动画，直接跳位。
  void _revealSelected({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = widget.selected;
      if (index < 0 || index >= _tabKeys.length) return;
      final target = _tabKeys[index].currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: animate ? const Duration(milliseconds: 220) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
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
          // 官方压缩态 `ap4.xml` 的搜索行是 38dp；这里按首页 `fua` 的
          // 51dp（上 6dp / 框体 36dp / 下 9dp）留白，频道标签不再贴着
          // 搜索框（2026-10-25 用户反馈）。
          // 桌面端不渲染这一行：分区搜索只留频道条右端的搜索图标一处
          // 入口（与 _DramaPageState._topChromeHeight 的桌面高度一致）。
          if (!isWindowsDesktop)
            SizedBox(
              height: _dramaSearchRowHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 9),
                child: _searchField(context, light: widget.light),
              ),
            ),

          SizedBox(
            height: _dramaStripHeightFor(context),
            child: Row(
              children: [
                Expanded(
                  // 只有五个标签，不用 ListView.builder：定位锚点必须随时
                  // 拿到 context，不能有还没建出来的标签。
                  child: SingleChildScrollView(
                    key: const Key('drama_channel_strip'),
                    controller: _strip,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (
                          var index = 0;
                          index < widget.channels.length;
                          index++
                        )
                          _ChannelTab(
                            key: _tabKeys[index],
                            label: widget.channels[index].label,
                            selected: index == widget.selected,
                            light: widget.light,
                            onTap: () => widget.onSelect(index),
                          ),
                      ],
                    ),
                  ),
                ),
                // 官方 `ap3.xml` 的 `@id/h4f` 是 20dp 搜索钮，但手机端顶部
                // 已有整条搜索框，两处入口重复（2026-10-25 用户要求移除）。
                // 桌面端不渲染搜索行，搜索只留这一处入口。
                if (isWindowsDesktop) ...[
                  IconButton(
                    key: const Key('drama_strip_search_button'),
                    tooltip: '搜索短剧',
                    onPressed: widget.onSearch,
                    iconSize: 20,
                    color: widget.light
                        ? (palette.dark
                              ? Colors.white
                              : const Color(0xFF1B1B1B))
                        : Colors.white,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 20,
                      height: 20,
                    ),
                    icon: const Icon(LucideIcons.search),
                  ),
                  const SizedBox(width: 16),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(BuildContext context, {required bool light}) {
    final palette = HomePalette.of(context);
    // 浅色页在外观为深色时，搜索框要改成白透底 + 浅字。
    final dark = light && palette.dark;
    final iconColor = light
        ? (dark ? const Color(0x99FFFFFF) : const Color(0x99000000))
        : const Color(0x99FFFFFF);
    return Semantics(
      button: true,
      label: '搜索短剧',
      child: GestureDetector(
        key: const Key('drama_search_button'),
        onTap: widget.onSearch,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: light
                ? (dark ? const Color(0x1AFFFFFF) : const Color(0x0F000000))
                : const Color(0x33000000),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: light
                  ? (dark ? const Color(0x1FFFFFFF) : const Color(0x14000000))
                  : const Color(0x2EFFFFFF),
              width: 0.5,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Icon(LucideIcons.search, size: 14, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: light && !dark
                        ? const Color(0x99000000)
                        : const Color(0x80FFFFFF),
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

/// One tab of the channel strip: an animated 16→24sp label over a 3dp
/// indicator.
///
/// 字号档位与切换动画移植自首页 tab 条（选中 24sp、未选中 16sp，
/// `AnimatedDefaultTextStyle` 180ms easeOutCubic），比官方短剧条的固定
/// 18sp 更有选中感（用户 2026-10-25 要求）。
///
/// The strip floats over the video feed (`ap4.xml` 根背景 @null)，文字用白色系：
/// 选中纯白加粗、未选中半透明白（官方 `app:aui/avn` 指向的
/// `skin_color_black_light` 是皮肤资源，截图里短剧 feed 上呈现为深色背景上
/// 的白字，与皮肤暗色变体一致）。
class _ChannelTab extends StatelessWidget {
  static const _selectedSize = 24.0;
  static const _unselectedSize = 16.0;

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 浅色页（漫剧）的深色文字变体，见 [_TopBar.light]。
  final bool light;

  const _ChannelTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.light = false,
  });

  @override
  Widget build(BuildContext context) {
    // 浅色页在深色外观下换成白字；视频流本来就压在黑底上，保持白色。
    final dark = light && HomePalette.of(context).dark;
    final selectedColor = light
        ? (dark ? Colors.white : const Color(0xFF1B1B1B))
        : Colors.white;
    final unselectedColor = light && !dark
        ? const Color(0x99000000)
        : const Color(0x99FFFFFF);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          // 点击水波也走圆角：方角高亮压在浅色页上像一块硬阴影。
          borderRadius: BorderRadius.circular(12),
          // 官方 `ap3.xml`：tab 内边距 `app:avb` = 16dp（TabCompress 开）／20dp（关），
          // 文字 18sp（`app:avq`/`app:av5`）。这里取压缩态 16dp；字号按
          // 用户要求换成首页的 24/16 两档。
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    fontSize: selected ? _selectedSize : _unselectedSize,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? selectedColor : unselectedColor,
                  ),
                  child: Text(label),
                ),
                // 官方指示条：高 `app:arw` = 3dp、宽 `app:auw` = 16dp（`ap3.xml`），
                // 在 `SlidingTabLayout.E()` 里按 tab 中心对齐。透明度跟着
                // 字号一起过渡，避免切换时只剩字在动。
                const SizedBox(height: 3),
                AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  width: 16,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? selectedColor : Colors.transparent,
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

  /// 弹幕层，与视频一起裁在 12dp 圆角内；清屏/未上屏时由宿主不传或整层
  /// 自隐藏。层自身 IgnorePointer，不抢手势。
  final Widget? danmakuOverlay;
  final Widget? errorOverlay;
  final InlineVideoPlayback? playback;
  final VoidCallback? onFullscreen;

  /// 右侧横屏钮（官方 `nk3.c.g` → `transformToLandActivity`），与
  /// [onFullscreen] 是两条路：那颗钮起独立的横屏页，不是「观看全集」。
  final VoidCallback? onLandscape;
  final VoidCallback? onQuickCatalog;
  final VoidCallback onTogglePlay;
  final VoidCallback onOpenMorePanel;
  final VoidCallback onOpenSeriesDetail;

  /// 清屏播放（官方面板行的会话态）：渐变遮罩、信息层、进度条与静音
  /// 药丸整批隐藏，出口只有面板的「退出清屏」行（与官方旧底栏分支同款
  /// 的无栏内出口形态）。
  final bool clearScreen;
  final List<PlayletComment> hotComments;
  final ValueChanged<PlayletComment> onHotCommentTap;
  final bool hotCommentActive;
  final double bottomInset;

  const _DramaFeedCard({
    required this.item,
    required this.opening,
    this.video,
    this.danmakuOverlay,
    this.errorOverlay,
    this.playback,
    this.onFullscreen,
    this.onLandscape,
    this.onQuickCatalog,
    required this.onTogglePlay,
    required this.onOpenMorePanel,
    required this.onOpenSeriesDetail,
    this.clearScreen = false,
    this.hotComments = const [],
    required this.onHotCommentTap,
    this.hotCommentActive = true,
    this.bottomInset = 0.0,
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
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              video ??
                  StoryCover(
                    item: item,
                    cacheWidth: (size.width * pixelRatio).ceil(),
                    alignment: Alignment.topCenter,
                  ),
              // 弹幕在视频上、其余遮罩之下（官方信息流弹幕不出画面区）。
              ?danmakuOverlay,
            ],
          ),
        ),
        // 官方 `cjk.xml`：底部渐变遮罩，`@drawable/yp` 是
        // `@color/oc`(#01000000) → `@color/ak`(#80000000)、angle 270。
        // 铺满整卡会把封面上半也压暗，所以只盖底部并根据 bottomInset 自适应抬高。
        if (!clearScreen)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 280 + bottomInset,
            child: const DecoratedBox(
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
          bottom: bottomInset + 160,
          child: _CardGestures(
            key: ValueKey('drama_card_${item.kind}_${item.id}'),
            enabled: _interactive,
            onTap: onTogglePlay,
            onPanelLongPress: onOpenMorePanel,
            onBoostLongPressStart: () => unawaited(playback?.startBoost()),
            onBoostLongPressEnd: () => unawaited(playback?.endBoost()),
          ),
        ),
        // Above the card's tap target, so the retry button wins its own taps.
        ?errorOverlay,
        // 居中播放/暂停微动效反馈
        if (playback != null)
          Positioned.fill(
            child: IgnorePointer(
              child: _PlayPauseFeedback(playback: playback!),
            ),
          ),
        // 官方进度条（`cjt.xml`）：整条高 16dp、轨道 1.0dip、滑块 1.5dip，
        // 已播 `@color/agn`=#1affffff、底槽 `@color/b8`=#4dffffff，左右 padding 16dp。
        // 自适应悬浮在底部导航栏之上，避免被底栏遮挡。
        if (playback != null && !clearScreen)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset,
            child: _SeekBar(playback: playback!),
          ),
        // 官方「取消静音」药丸（feed 变体 `mq3.c` + `bvf.xml`，108×36dp 展开），
        // 不是播放页的 `ck8.xml` 变体（12sp+16dp lottie、3s 定时）。官方出厂
        // 默认**有声**，药丸只在该会话静音时出现；形态细节见 _MuteHint 文档。
        if (playback != null && !clearScreen)
          Positioned(
            left: 12,
            bottom: bottomInset + 120,
            child: _MuteHint(playback: playback!),
          ),
        // 官方倍速提示（`cjx.xml`）：高 83dp、16sp bold 白字
        // `@string/ec6`=「2倍速快进中」，长按期间显示。
        if (playback != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 160,
            child: _RateHint(playback: playback!),
          ),
        // 官方底部信息层（`cj3.xml` 整体）：最上是居中的「观看全集」药丸行
        // （`nk3.c` inflate `ad9.xml`，在 RelativeLayout 里 CENTER_IN_PARENT），
        // 然后是标题行（`d6g.xml`）、分类 chip 行（`d6f.xml` 的 `hdm`）、
        // 集数简介行（`m6` ShortSeriesExtendTextView）。整块挂在信息槽 `H3` 上。
        if (!clearScreen)
          Positioned(
            left: 12,
            right: 12,
            bottom: bottomInset + 16,
            child: _InfoPanel(
              item: item,
              playback: playback,
              onOpenSeriesDetail: onOpenSeriesDetail,
              onFullscreen: onFullscreen,
              onLandscape: onLandscape,
              onQuickCatalog: onQuickCatalog,
              hotComments: hotComments,
              onHotCommentTap: onHotCommentTap,
              hotCommentActive: hotCommentActive,
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

/// feed 弹幕层：复用播放页的时间轴渲染组件，只在「本卡是会话目标、
/// 开关开启、非清屏」时出现。飞行/轨道/字号语义与播放页完全一致
/// （[PlayletDanmakuLayer] 自带帧时钟与暂停冻结）。
class _FeedDanmakuOverlay extends StatelessWidget {
  final MediaItem item;
  final InlineVideoPlayback playback;
  final List<PlayletComment> entries;
  final bool enabled;
  final bool clearScreen;
  final DanmakuSettings settings;

  const _FeedDanmakuOverlay({
    required this.item,
    required this.playback,
    required this.entries,
    required this.enabled,
    required this.clearScreen,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        playback.activeId,
        playback.playing,
        playback.rate,
      ]),
      builder: (context, _) {
        final active =
            enabled &&
            !clearScreen &&
            entries.isNotEmpty &&
            playback.activeId.value == item.id;
        if (!active) return const SizedBox.shrink();
        return Positioned.fill(
          child: IgnorePointer(
            child: PlayletDanmakuLayer(
              entries: entries,
              position: playback.position,
              rate: playback.rate.value,
              playing: playback.playing.value,
              landscape: false,
              settings: settings,
            ),
          ),
        );
      },
    );
  }
}

/// 居中播放/暂停瞬态微动效组件：当视频暂停时在画面中央呈现优雅的磨砂圆盘，播放时平滑淡出。
class _PlayPauseFeedback extends StatelessWidget {
  final InlineVideoPlayback playback;

  const _PlayPauseFeedback({required this.playback});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([playback.playing, playback.firstFrame]),
      builder: (context, _) {
        final isPaused = !playback.playing.value && playback.firstFrame.value;
        return Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            opacity: isPaused ? 1.0 : 0.0,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutBack,
              scale: isPaused ? 1.0 : 0.7,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0x59000000),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x33FFFFFF), width: 1),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Center(
                  child: Padding(
                    padding: EdgeInsets.only(left: 3),
                    child: Icon(
                      LucideIcons.play,
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The official card's tap / long-press plane.
///
/// 单击 = 播放/暂停。官方卡上**没有双击手势**：`jq3/x` 注册的监听器
/// （`fp3.f` 子类 `q`）继承了 `SimpleOnGestureListener.onDoubleTap` 的默认实现，
/// 而真正处理双击点赞的是另一条链路（`o.z7` → `lh3.a.onDoubleTap`），本仓库
/// 不实现点赞，所以这里也不注册双击。
///
/// Long-press is the official two-branch gesture (`jq3/x$q.onLongPress`
/// `:2228-2262`）：命中横向中带（`K6()` `:2690-2711`，竖屏 50% / 横屏 33% 宽、
/// 居中、Y 不限）且 `y7()` 处理成功 → 打开更多面板；带外才是速度层的 2×
/// 快进，按住期间生效（`@string/ec6`=「2倍速快进中」，`cjx.xml`）。
///
/// **这里不再挂横向拖动。** 官方那张卡上左右滑是整屏调进度（`o.java:K6`，
/// `bottomMargin=138dp`），但这条手势和「横滑切频道」是同一个操作的两套语义，
/// 落在不同区域会互相打架。调进度收窄到底部进度条（`_SeekTrack` 自己带
/// 横向拖动）：卡片其余区域一律归外层 [TabSwipeArea] 切频道，左边滑是
/// 上一个频道、右边滑是下一个，不再随按下点在「调进度 / 切频道」之间跳。
class _CardGestures extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onPanelLongPress;
  final VoidCallback onBoostLongPressStart;
  final VoidCallback onBoostLongPressEnd;

  const _CardGestures({
    super.key,
    required this.enabled,
    required this.onTap,
    required this.onPanelLongPress,
    required this.onBoostLongPressStart,
    required this.onBoostLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.expand();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 官方 `jq3/x.K6()`：中带宽 = 视图宽 ×（竖屏 0.5 / 横屏 0.33），
        // 居中放置，Y 不限。横竖屏分档来自官方 `J6()`。
        final bandFraction =
            MediaQuery.orientationOf(context) == Orientation.landscape
            ? 0.33
            : 0.5;
        bool inBand(double dx) {
          final width = constraints.maxWidth;
          if (width <= 0) return false;
          final half = width * bandFraction / 2;
          final center = width / 2;
          return dx >= center - half && dx <= center + half;
        }

        return GestureDetector(
          key: const Key('drama_card_gestures'),
          // opaque：整块手势区自己吃指针，上滑翻页仍归外层 PageView 的竖直
          // 拖动；横向则留给更外层的 TabSwipeArea（这里没有横向识别器，
          // 竞技场里只剩它一个）。
          behavior: HitTestBehavior.opaque,
          // 没有双击手势了，单击立即派发（不再等双击窗口）。
          onTap: onTap,
          onLongPressStart: (details) {
            if (inBand(details.localPosition.dx)) {
              onPanelLongPress();
            } else {
              HapticFeedback.lightImpact();
              onBoostLongPressStart();
            }
          },
          // 带外快进的收尾由 endBoost 的 _boosting 门挡住：中带开面板的
          // 那支从未 startBoost，松手不能动速率。
          onLongPressEnd: (_) => onBoostLongPressEnd(),
          onLongPressCancel: onBoostLongPressEnd,
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
              PlayerToast.show(context, '已开启声音');
            },
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _expanded ? 108 : 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0x66000000),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
              ),
              padding: EdgeInsets.only(left: _expanded ? 14 : 9),
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    LucideIcons.volume_x,
                    size: 16,
                    color: Colors.white,
                  ),
                  if (_expanded) const SizedBox(width: 6),
                  if (_expanded)
                    const Text(
                      '取消静音',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        height: 1.1,
                      ),
                    ),
                  if (_expanded) const SizedBox(width: 10),
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
/// 挂 `boosting` 而不是 `rate > 1`：更多面板也能选 2x，选档不是快进中，
/// 提示不能因此常驻。
class _RateHint extends StatelessWidget {
  final InlineVideoPlayback playback;

  const _RateHint({required this.playback});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback.boosting,
    builder: (context, _) {
      if (!playback.boosting.value) return const SizedBox.shrink();
      return Center(
        child: Container(
          key: const Key('drama_rate_hint'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xD9000000),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(LucideIcons.fast_forward, size: 18, color: Colors.white),
              SizedBox(width: 8),
              Text(
                '2倍速快进中',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 0.3,
                ),
              ),
            ],
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
          height: 24,
          child: _SeekTrack(
            progress: progress,
            currentPosition: playback.position.value,
            totalDuration: total,
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

class _SeekTrack extends StatefulWidget {
  final double progress;
  final Duration currentPosition;
  final Duration totalDuration;
  final ValueChanged<double> onSeek;

  const _SeekTrack({
    required this.progress,
    required this.currentPosition,
    required this.totalDuration,
    required this.onSeek,
  });

  @override
  State<_SeekTrack> createState() => _SeekTrackState();
}

class _SeekTrackState extends State<_SeekTrack> {
  bool _isDragging = false;
  double _dragProgress = 0.0;

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      void seekTo(double dx) {
        final fraction = width <= 0 ? 0.0 : (dx / width).clamp(0.0, 1.0);
        setState(() {
          _isDragging = true;
          _dragProgress = fraction;
        });
        widget.onSeek(fraction);
      }

      final effectiveProgress = _isDragging ? _dragProgress : widget.progress;
      final previewMillis =
          (widget.totalDuration.inMilliseconds * effectiveProgress).round();
      final previewDuration = Duration(milliseconds: previewMillis);

      return GestureDetector(
        key: const Key('drama_seek_bar'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (details) => seekTo(details.localPosition.dx),
        onHorizontalDragUpdate: (details) => seekTo(details.localPosition.dx),
        onHorizontalDragEnd: (_) {
          if (mounted) setState(() => _isDragging = false);
        },
        onHorizontalDragCancel: () {
          if (mounted) setState(() => _isDragging = false);
        },
        onTapDown: (details) => seekTo(details.localPosition.dx),
        child: SizedBox(
          height: 24,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              // 拖拽时浮现时间气泡提示
              if (_isDragging)
                Positioned(
                  bottom: 18,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE6000000),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24, width: 0.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        '${_formatDuration(previewDuration)} / ${_formatDuration(widget.totalDuration)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ),

              // 底部未播槽
              Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: _isDragging ? 4.5 : 2.0,
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // 已播段
              Center(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: effectiveProgress,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: _isDragging ? 4.5 : 2.0,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: _isDragging
                            ? const [
                                BoxShadow(
                                  color: Color(0x66FFFFFF),
                                  blurRadius: 4,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                ),
              ),

              // 滑块 Thumb
              Align(
                alignment: Alignment(effectiveProgress * 2 - 1, 0),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: _isDragging ? 12 : 3,
                  height: _isDragging ? 12 : 3,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: _isDragging
                        ? const [
                            BoxShadow(
                              color: Colors.black45,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ],
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
///   点击进剧集详情页（官方 `ql3/v0.a1()`，埋点 `enter_from="title"`；此前
///   误记为播放/暂停切换——卡片手势层才是 play/pause，标题行是详情入口）。
/// - **分类 chip 行**：`d6f.xml` 的 `hdm`（marginTop 4dp、marginBottom 12dp、
///   divider `@drawable/aai`），chip 由 `ql3.c0.V()` 运行时构造：12sp 白字、
///   背景 `@color/ags`=#33FFFFFF、圆角 2dp、padding 6/2/6/2。
/// - **简介行**：`m6` `ShortSeriesExtendTextView`：14sp、`@color/bb8`→
///   `@color/u`=#CCFFFFFF、最多 2 行（`app:amo=2`），截断时点「展开」。
///   文案按官方截图为「第1集丨简介」——feed 卡从第 1 集起播。
class _InfoPanel extends StatefulWidget {
  final MediaItem item;
  final InlineVideoPlayback? playback;
  final VoidCallback? onFullscreen;

  /// 右侧横屏钮（官方 `nk3.c.g`）。null 时该钮不渲染。
  final VoidCallback? onLandscape;
  final VoidCallback? onQuickCatalog;

  /// 标题行「剧名 >」点击 → 剧集详情页。
  final VoidCallback onOpenSeriesDetail;
  final List<PlayletComment> hotComments;
  final ValueChanged<PlayletComment> onHotCommentTap;
  final bool hotCommentActive;

  const _InfoPanel({
    required this.item,
    required this.playback,
    required this.onFullscreen,
    this.onLandscape,
    this.onQuickCatalog,
    required this.onOpenSeriesDetail,
    this.hotComments = const [],
    required this.onHotCommentTap,
    this.hotCommentActive = true,
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
                if (widget.onQuickCatalog != null) ...[
                  const SizedBox(width: 8),
                  _QuickCatalogButton(onTap: widget.onQuickCatalog!),
                ],
                if (widget.playback != null && widget.onLandscape != null) ...[
                  const SizedBox(width: 8),
                  _FullscreenRoundButton(
                    playback: widget.playback!,
                    onTap: widget.onLandscape!,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        // 标题行：官方 `d6g.xml`。点击进剧集详情页（ql3/v0 `a1()` 默认分支），
        // 与播放页标题行同一路跳转；播放/暂停由卡片手势层承担。
        GestureDetector(
          key: const Key('drama-series-title'),
          onTap: widget.onOpenSeriesDetail,
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
              const Icon(
                LucideIcons.chevron_right,
                size: 18,
                color: Colors.white70,
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
                    horizontal: 7,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: const Color(0x26FFFFFF),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    category,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        // 信息槽（官方 `cj3.xml`：`InfoPanelHotCommentView`(`drs`) 与
        // `ShortSeriesExtendTextView`(`m6`) 同一槽位约束——热评在场时
        // 整行替换简介行；否则回落到「第1集丨…」简介）。
        if (widget.hotComments.isNotEmpty)
          PlayletHotCommentBar(
            comments: widget.hotComments,
            onTap: widget.onHotCommentTap,
            active: widget.hotCommentActive,
          )
        else if (item.intro.isNotEmpty)
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
        // 作者声明行（`video_detail.ai_usage_type > 0`；播放页信息区同款，
        // 见 `video_player_chrome.dart` 的 `aiGenerated` 行）。
        if (item.aiGenerated) ...[
          const SizedBox(height: 8),
          Row(
            children: const [
              Icon(LucideIcons.info, size: 13, color: Color(0x99FFFFFF)),
              SizedBox(width: 4),
              Flexible(
                child: Text(
                  '作者声明：内容由AI生成',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Color(0x99FFFFFF)),
                ),
              ),
            ],
          ),
        ],
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
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0x2E000000),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0x38FFFFFF), width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.play, size: 12, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 快速选集入口按钮
class _QuickCatalogButton extends StatelessWidget {
  final VoidCallback onTap;

  const _QuickCatalogButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0x2E000000),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0x38FFFFFF), width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(LucideIcons.layout_grid, size: 12, color: Colors.white),
            SizedBox(width: 4),
            Text(
              '选集',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 官方 30×30dp 圆形全屏钮（`ad9.xml` 的 `@id/dgu`），进入横屏播放页。
///
/// 显隐照官方 `vk3.a.a(saasVideoData, false)`：判据是横版片源，而不是「解码
/// 尺寸此刻是否已知」。官方读的是数据层 `isVertical()`，换集立刻成立；本地
/// 源数据没有该字段，只能等解码器报尺寸，但结论一旦拿到就由
/// [InlineVideoPlayback.landscapeSource] 记住，不随 `videoSize` 换集重置而
/// 退回未知——那正是「上划一集后钮再也不出现」的成因。
class _FullscreenRoundButton extends StatelessWidget {
  final InlineVideoPlayback playback;
  final VoidCallback onTap;

  const _FullscreenRoundButton({required this.playback, required this.onTap});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool?>(
    valueListenable: playback.landscapeSource,
    builder: (context, landscape, _) {
      // `null`（还没解出尺寸）与竖版同样不渲染，避免闪出又消失。
      if (landscape != true) return const SizedBox.shrink();
      return GestureDetector(
        key: const Key('drama_fullscreen_button'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0x2E000000),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x38FFFFFF), width: 0.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            LucideIcons.maximize_2,
            size: 14,
            color: Colors.white,
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
        decoration: BoxDecoration(
          color: const Color(0xCC222222),
          // 与 feed 内的倍速提示同一套圆角，不再是一整块方角黑条。
          borderRadius: BorderRadius.circular(24),
        ),
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

/// Official `aq0.xml` pull-to-refresh strip: 16sp 「下拉刷新内容」.
class _PullRefreshHint extends StatelessWidget {
  final bool armed;

  /// 浅色页用墨色（白字在白底上看不见），视频流仍用白字。
  final Color color;

  const _PullRefreshHint({required this.armed, required this.color});

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
              style: TextStyle(fontSize: 16, color: color),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
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

  /// The cover laid over this card while nothing is playing (or before the
  /// first frame arrives).
  ///
  /// The poster is a 9:16 portrait image while this card gets a landscape
  /// window on desktop: `cover` fills by width and overflows several times,
  /// which reads as "only the top slice of the poster". Desktop switches to
  /// `contain` over a black backing — the same look as the video's
  /// `VideoFit.contain` right below. Phones keep a portrait card, so they
  /// keep filling.
  Widget _cover(int cacheWidth) => ColoredBox(
    color: Colors.black,
    child: StoryCover(
      key: ValueKey('drama_inline_cover_${item.kind}_${item.id}'),
      item: item,
      cacheWidth: cacheWidth,
      alignment: Alignment.topCenter,
      fit: isWindowsDesktop ? BoxFit.contain : BoxFit.cover,
    ),
  );

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
            final cover = _cover(cacheWidth);
            // A card the session is not playing (yet) shows its cover only.
            if (playback.activeId.value != item.id) return cover;
            final textureId = playback.textureId.value;
            final videoSize = playback.videoSize.value;
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
              fit: isWindowsDesktop ? VideoFit.contain : VideoFit.fillFrame,
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
                      child: isWindowsDesktop
                          ? DesktopPlatform.instance.videoSurface(
                              textureId,
                              key: ValueKey('drama_inline_${item.id}'),
                            )
                          : Texture(
                              key: ValueKey(
                                'drama_inline_texture_${item.kind}_${item.id}',
                              ),
                              textureId: textureId,
                            ),
                    ),
                  ),
                // A first-frame event may beat the size event. Never expose a
                // new texture through the 9:16 fallback (or stale geometry).
                if (textureId == null ||
                    !playback.firstFrame.value ||
                    videoSize.width <= 0 ||
                    videoSize.height <= 0)
                  cover,
              ],
            );
          },
        );
      },
    );
  }
}

/// The card keeps its cover and shows the session's curated error message.
/// The retry button re-activates this card's drama.
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
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.white),
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
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return ColoredBox(
      color: palette.canvas,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSpinner) ...[
                SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: palette.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    final palette = HomePalette.of(context);
    // 深色 / OLED 下卡片换浮层色，编辑态再错一档（原来编辑态是 #FAFAFA）。
    final cardColor = palette.dark
        ? (editing ? palette.soft : palette.surface)
        : (editing ? const Color(0xFFFAFAFA) : Colors.white);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
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
                    Center(
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                          color: Color(0x66000000),
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Padding(
                            padding: EdgeInsets.only(left: 2),
                            child: Icon(
                              LucideIcons.play,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
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
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        height: 1.25,
                        color: palette.ink,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            color: palette.muted,
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
    final palette = HomePalette.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0A000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
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
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: palette.dark
                              ? palette.line
                              : const Color(0x0F000000),
                          width: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            item.title,
            maxLines: titleMaxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: palette.ink,
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  color: palette.muted,
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
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: palette.dark ? palette.soft : const Color(0xFFFFF3E0),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.clapperboard,
              size: 38,
              color: Color(0xFFFA6725),
            ),
          ),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(fontSize: 14, color: palette.muted)),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 12,
                  ),
                  child: Text(
                    // 最近页 = `Fe()`（DynamicComic 开启时「找短剧」）；
                    // 收藏页官方硬编码「找视频」。
                    buttonLabel,
                    style: const TextStyle(
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
        style: TextStyle(fontSize: 12, color: HomePalette.of(context).muted),
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
                  padding: EdgeInsets.fromLTRB(
                    12,
                    8,
                    12,
                    MediaQuery.paddingOf(context).bottom + 72.0 + 20,
                  ),
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
                      tagText: item.kind == 'manju' && _filter != 'manju'
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
              else
                // 筛选行是常驻控件：切到没有记录的那一类（「其他视频」恒为空，
                // 短剧/漫剧也可能还没有）时它必须留着，否则用户回不到「全部」。
                _normalHeader(filtered),
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
  /// marginEnd 52dp 给它让位）。悬浮顶栏仍然压在页面上方，chips 行要整体
  /// 让到它下面。
  ///
  /// [filtered] 为空时（筛到没有记录的那一类）不给「编辑」：进编辑会把
  /// 悬浮顶栏藏掉，而编辑头只在有记录时出现，用户就没有「完成」可按了。
  Widget _normalHeader(List<MediaItem> filtered) {
    final top = MediaQuery.paddingOf(context).top;
    final palette = HomePalette.of(context);
    // 让位高度必须跟 [_TopBar] 同一套算法：搜索行 51 + 频道条 38（桌面端
    // 没有搜索行，也要少让一段）。这里曾经写死 84（＝旧 38+38+8），
    // 搜索行加高后 chips 会钻到频道条底下（2026-10-25）。
    final chrome = dramaTopChromeHeight(context);
    return Container(
      padding: EdgeInsets.fromLTRB(12, top + chrome + 8, 12, 8),
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
          if (filtered.isNotEmpty)
            GestureDetector(
              key: const Key('drama_recent_edit'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _setEditing(true),
              child: Text(
                '编辑',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
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
    final palette = HomePalette.of(context);
    return Container(
      key: const Key('drama_recent_edit_header'),
      color: palette.dark ? palette.canvas : Colors.white,
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
                    style: TextStyle(fontSize: 16, color: palette.ink),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setEditing(false),
                  child: Text(
                    '完成',
                    style: TextStyle(fontSize: 16, color: palette.ink),
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
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: palette.ink,
                    ),
                  ),
                  if (_selected.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '已选择 ${_selected.length} 个$_selectionSuffix',
                        style: TextStyle(fontSize: 12, color: palette.muted),
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
    final palette = HomePalette.of(context);
    return DecoratedBox(
      key: Key(
        fromShelfEdit ? 'drama_shelf_bottom_bar' : 'drama_recent_bottom_bar',
      ),
      decoration: BoxDecoration(
        color: palette.dark ? palette.canvas : Colors.white,
        border: Border(
          top: BorderSide(
            color: palette.dark
                ? palette.line
                : const Color(0xFF1B1B1B).withAlpha(15),
          ),
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
                  color: palette.ink,
                  enabled: enabled,
                  onTap: enabled
                      ? () => unawaited(_followSelected(filtered))
                      : null,
                ),
                const SizedBox(width: 40),
              ],
              _barAction(
                key: Key(
                  fromShelfEdit ? 'drama_shelf_delete' : 'drama_recent_delete',
                ),
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

  bool get fromShelfEdit => widget.channel.source == DramaChannelSource.shelf;

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
        content: Text(_filter == 'manju' ? '追漫后可在书架找到该漫剧' : '追剧后可在书架找到该短剧'),
      ),
    );
    Timer(const Duration(milliseconds: 300), () {
      if (mounted) _setEditing(false);
    });
  }

  /// 历史删除沿用官方确认（最近 `Te()`：标题「确定删除浏览历史吗？」、
  /// 确认/取消）。收藏删除官方同样先确认（`re()`→`hy2.d0`：标题
  /// 「确认删除吗？」、按钮文案「删除」），但取消追剧可逆（可重新
  /// 追剧、观看历史保留），按 issue #126 与书架页「可逆操作勿扰」的
  /// 同一决策直接执行、不弹确认框。成功 Toast「删除成功」/失败
  /// 「删除失败」，500ms 后退出编辑（`P2`/`pb` 的
  /// `postInForeground(500)`）。
  Future<void> _confirmDelete() async {
    final fromShelf = fromShelfEdit;
    if (!fromShelf) {
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
    }
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
    final palette = HomePalette.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _filter = kind),
      child: DecoratedBox(
        // 官方 `c4e.xml` + `f.s()`：选中浅橙底橙字加粗，未选中浅灰底深字。
        decoration: BoxDecoration(
          color: selected
              ? const Color(0x1AFA6725)
              : (palette.dark ? palette.soft : const Color(0x08000000)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? const Color(0xFFFA6725) : palette.ink,
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
