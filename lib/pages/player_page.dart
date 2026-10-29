import '../services/desktop_platform.dart';
import '../services/app_log.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/audio_extra.dart' show RelatedWork;
import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart';
import '../models/related_series.dart';
import '../widgets/player/related_series_sheet.dart';
import 'detail_page.dart' show openBookDetail;
import 'series_detail_page.dart' show SeriesDetailPage;
import '../services/api_client.dart';
import '../services/backend_transport.dart' show BackendRequest;
import '../services/player_panel_preferences.dart';
import '../services/watched_episodes.dart';
import 'listen_mode_page.dart';
import '../services/episode_source_cache.dart';
import '../services/fair_memory.dart';
import '../services/drama_cache_preferences.dart';
import '../services/drama_download_store.dart';
import '../services/drama_downloader.dart';
import '../services/connectivity_status.dart';
import 'drama_download_sheet.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/playback_issue.dart';
import '../services/player_history.dart';
import '../services/player_layout_preferences.dart';
import '../services/player_load_diagnostics.dart';
import '../services/player_preferences.dart';
import '../services/player_style_config.dart';
import '../services/quality_memory.dart';
import '../services/swipe_guide_store.dart';
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/playlet_danmaku_layer.dart';
import '../widgets/player/playlet_danmaku_loader.dart';
import '../widgets/player/playlet_danmaku_settings.dart';
import '../widgets/player/story_player_panel.dart';
import '../widgets/player/player_cover.dart';
import '../widgets/player/player_feedback.dart';
import '../widgets/player/player_split_panel.dart';
import '../widgets/player/player_toast.dart';
import '../widgets/video_player_chrome.dart';

class PlayerPage extends StatefulWidget {
  final String bookId;
  final String kind;
  final String title;
  final String cover;
  final List<Chapter> eps;
  final int startIndex;
  final Future<Map<String, dynamic>> Function(Chapter)? contentLoader;
  final NativePlayer Function()? playerFactory;
  final ReaderStore? historyStore;
  final SeriesDetail? initialSeriesDetail;
  final PlayerLoadDiagnostics? loadDiagnostics;

  /// 底部 band 装饰数据的可注入 loader（默认走 ApiClient，best-effort：
  /// 失败就缺省，不打扰播放）。测试注入用。
  final Future<SeriesDetail> Function(String bookId)? seriesLoader;

  /// 弹幕取数的可注入实现（默认走 ApiClient.playletDanmaku）。测试注入用，
  /// 与 [seriesLoader] 同一套缝。
  final Future<PlayletCommentPage> Function(DanmakuFetchRequest request)?
  danmakuFetcher;

  /// 热评取数的可注入实现（默认走 ApiClient.playletHotComments），参数是
  /// 剧集 id 与当前集 vid。测试注入用，与 [danmakuFetcher] 同一套缝。
  final Future<PlayletCommentPage> Function(String seriesId, String vid)?
  hotCommentsLoader;

  /// 官方短剧播放页形态（`apf.xml`）：竖屏无运输条、单击=播放/暂停。
  /// 详情页的电影/电视剧走通用形态（默认 false）。
  final bool shortSeries;

  /// 播放页信息层的 AI 声明行。
  final bool aiGenerated;

  /// 进页即全屏（并请求横屏）。官方 feed 卡片右侧的横屏钮不是「观看全集」
  /// 的同一条路：它 `transformToLandActivity` → 起独立
  /// `ShortSeriesLandActivity`（`jq3/x.java:4499-4538`，manifest 锁
  /// `userLandscape`），页面一起来就是横屏全屏。本地用同一个播放页承载，
  /// 靠这个参数在进页时置全屏态。
  final bool openFullScreen;

  /// 离线下载引擎与缓存的注入缝（测试用）。缺省用全局单例 —— 生产环境
  /// 下载队列就是进程级的一个，测试里换成假实现才不碰 Hive 与真网。
  final DramaDownloader? downloader;
  final DramaDownloadStore? store;

  const PlayerPage({
    super.key,
    required this.bookId,
    this.kind = 'video',
    required this.title,
    this.cover = '',
    required this.eps,
    required this.startIndex,
    this.contentLoader,
    this.playerFactory,
    this.historyStore,
    this.loadDiagnostics,
    this.seriesLoader,
    this.initialSeriesDetail,
    this.danmakuFetcher,
    this.hotCommentsLoader,
    this.shortSeries = false,
    this.aiGenerated = false,
    this.openFullScreen = false,
    this.downloader,
    this.store,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late int _index;
  late String _historyKind = widget.kind;
  int? _activeIndex;
  bool _hasDisplayed = false;
  NativePlayer? _player;
  Timer? _progressTimer;
  // 小米公平运行内存 KILL 广播的刷盘注销函数，见 reader_page.dart。
  VoidCallback? _unregisterFairMemoryFlush;
  bool _initVideo = false;
  bool _paging = false;

  /// 悬浮窗播放中（#24）：应用切后台后画面搬进系统悬浮窗继续播。
  /// 服务在 inactive（仍属前台过渡态）时启动，hidden 确认切后台后显示；
  /// 回前台 / 页面销毁 / 打开听视频时停掉并恢复 Flutter 纹理。
  bool _floating = false;

  /// 最近一次生命周期状态：悬浮窗启动是异步的，启动完成时要按当前
  /// 状态收尾（已回前台就立刻停，已切后台就立即显示）。
  AppLifecycleState _lastLifecycleState = AppLifecycleState.resumed;
  Completer<void>? _pagingSettled;
  int? _pendingCompletion;
  NativePlayer? _pendingAutoplay;
  PlaybackIssue? _error;
  int _loadGeneration = 0;
  final Stopwatch _watchTime = Stopwatch();
  final List<StreamSubscription<dynamic>> _subs = [];
  Future<void> _releases = Future<void>.value();
  late final EpisodeSourceCache _sources;

  DramaDownloadStore get _downloadStore =>
      widget.store ?? HiveDramaDownloadStore.instance;

  DramaDownloader get _downloader =>
      widget.downloader ?? DramaDownloader.instance;
  late final PlayerLoadDiagnostics _diagnostics;
  PlayerLoadTrace? _loadTrace;
  Timer? _prefetchTimer;
  int? _prefetchQueuedGeneration;

  /// 边看边往后缓存（见 [_scheduleAutoCache]）。
  Timer? _autoCacheTimer;

  /// 已经为哪一集排过自动缓存，避免同一集反复入队。
  int? _autoCacheFor;

  /// 待触发的调度是为哪一集排的（同一集反复出首帧不推迟截止时间）。
  int? _autoCacheTimerIndex;

  /// 播放器最近一次**实际选中**的档位高度（按 [QualityMemory] 的名字套用，
  /// 或用户在画质菜单里换档）。null = 没选过档，播的是上游默认流。
  int? _renditionHeight;
  int? _prefetchAttemptedGeneration;

  /// 「左右滑动可调整进度」首次引导（每台设备一次，`of3/a`）。
  bool _seekHintVisible = false;
  Timer? _seekHintTimer;

  /// 已看集（选集面板灰字）。
  ///
  /// 官方按 **vid 逐集**记录（`hj3/r0.java:445` 的 `bf3.b.b.q(seriesId, vid)`），
  /// 本地同样以**剧集 id** 为准：`_watchedIds` 是持久化的稳定集合，
  /// 渲染时再映射成下标（`watchedIndexes`）。
  /// 曾经这里用「续播点之前的集都算已看」推断，跳集时会标错，已废弃。
  Set<String> _watchedIds = <String>{};
  WatchedEpisodes get _watched =>
      WatchedEpisodes(widget.historyStore ?? LibraryStore.instance);

  /// 底部 band 装饰（官方截图第二十二轮）：完结状态与原著书卡，
  /// best-effort 拉取，失败保持缺省。
  SeriesDetail? _seriesDetail;
  String? _seriesStatus;
  RelatedWork? _originalBook;

  /// 官方入口计数（`SeriesCommentView` 读 `du4.a.e()` 并回写 videoData）；
  /// 0 表示「还没有人评论」，入口按官方文案显示「评论」。
  int _commentCount = 0;
  bool _externalPanelOpen = false;
  bool _switchingSeries = false;

  /// 选集面板头部用的剧信息（官方 `aa8.xml:7-15`）。
  String _seriesTitle = '';
  String _seriesCover = '';
  String _episodeLabel = '';

  /// 官方「画面撑满」（SP `is_fill_screen`）。
  bool _fillScreen = false;

  /// 官方「默认静音」：**不落盘**，只在进程内（`tm3/b.java:17-20`）。
  bool _defaultMute = PlayerPanelPreferences.defaultMute;

  PlayerHistory get _history =>
      PlayerHistory(widget.historyStore ?? LibraryStore.instance);
  Duration _duration = Duration.zero;
  bool _playing = false;

  bool _current(int generation, [NativePlayer? player]) =>
      mounted &&
      generation == _loadGeneration &&
      (player == null || identical(player, _player));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 小米公平运行内存：KILL 广播到达时刷一次播放进度，避免被杀丢进度。
    _unregisterFairMemoryFlush = FairMemoryService.instance
        .registerFlushHandler(_persistProgress);
    unawaited(NativePlayer.setKeepScreenOn(true).catchError((Object _) {}));
    unawaited(PlayerPreferences.loadFloatingWindow());
    _index = widget.eps.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.eps.length - 1);
    // 已看集来自持久化记录，**不**从续播下标推断（F07 的核心修正）。
    unawaited(_loadWatched());
    // 「左右滑动可调整进度」每台设备一次（`of3/a`）。只在 store 已初始化时
    // 判定，测试里未打开的 box 不显示；横滑或超时后写回并隐藏。
    if (SwipeGuideStore.instance.ready &&
        !SwipeGuideStore.instance.seekHintShown) {
      _seekHintVisible = true;
      _seekHintTimer = Timer(const Duration(seconds: 5), _consumeSeekHint);
    }
    _diagnostics = widget.loadDiagnostics ?? PlayerLoadDiagnostics();
    _sources = EpisodeSourceCache(
      loader: (episode) async => EpisodeSource.fromResponse(
        await (widget.contentLoader?.call(episode) ??
            ApiClient.instance.content(
              episode.itemId,
              tab: '短剧',
              mode: 'stream',
            )),
      ),
    );
    if (widget.eps.isEmpty) {
      _error = PlaybackIssue.empty;
    } else {
      unawaited(_loadVideo());
    }
    unawaited(_loadBandExtras());
    unawaited(_loadHotComments());
    unawaited(_loadDanmakuPreference());
    unawaited(_loadDanmakuSettings());
    // 进度心跳每秒喂一次调度器：进预取区间补拉下一批、落未覆盖处补数。
    // 不挂在 200ms 进度流上，也不逐帧（上批逐帧滚动只属于渲染层）。
    _danmakuProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_danmakuEnabled || !_playing || !_appActive) return;
      final player = _player;
      if (player == null || player.buffering || _paging || _error != null) {
        return;
      }
      _danmakuLoader.onProgress(player.position.inMilliseconds);
    });
  }

  /// 热评（官方 `SeriesHotCommentView`）：与评论计数同源，来自
  /// `comment/list` 的 `comment_source=4/count=20` 那次请求，
  /// 由 [hotOf] 在本地筛出（**不是接口字段**）。
  List<PlayletComment> _hotComments = const [];

  /// 弹幕（官方 `DanmakuRequestHelper`）：按 vid 取数，时间单位毫秒。
  /// 时间轴对象负责切集清空与去重（官方 container/l.java 的规则）。
  final DanmakuTimeline _danmaku = DanmakuTimeline();
  bool _danmakuEnabled = DanmakuPreference.defaultEnabled;

  /// 弹幕设置（官方 `danmaku_config` 五项，默认值同官方）。
  DanmakuSettings _danmakuSettings = const DanmakuSettings();

  /// 分段预加载 + seek 补数的调度器；一次只飞一个请求，旧响应按
  /// 代际作废。取数实现可注入（[PlayerPage.danmakuFetcher]）。
  late final DanmakuLoader _danmakuLoader = DanmakuLoader(
    fetch: widget.danmakuFetcher ?? _fetchDanmaku,
    onLoad: (page) {
      if (!mounted) return;
      final focus = _player?.position.inMilliseconds ?? 0;
      setState(() {
        final retention = _danmaku.load(page, focusMs: focus);
        if (retention.dropped) {
          _danmakuLoader.noteRetainedRange(
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

  /// 历史进度的 seek 发生在调度器 reset 之前时，先记在这里。
  /// 只对这一集有效，切走就丢。
  int? _danmakuResumeIndex;
  int? _danmakuResumeMs;

  /// 在飞的弹幕请求取消柄：切集与销毁时作废（官方 `w()` dispose 的等价）。
  BackendRequest? _danmakuFlight;

  /// 进度心跳（1 秒节流）。
  Timer? _danmakuProgressTimer;

  /// 底部 band 装饰，一个 `seriesDetail` 请求全出：完结状态
  /// （`series_status`：官方 `SeriesStatus` 1=已完结/0=更新中/3=今日更新/
  /// 4=断更）、原著书卡（`video_relate_book`）与评论计数
  /// （`comment_cnt`，官方入口「评论/抢首评」的判据）。
  /// 自吞异常——band 是装饰，接口再差也不能影响播放。
  Future<void> _loadBandExtras() async {
    final initial = widget.initialSeriesDetail;
    final series = initial != null && !initial.isEmpty
        ? initial
        : await (widget.seriesLoader?.call(widget.bookId) ??
                  ApiClient.instance.seriesDetail(widget.bookId))
              .catchError((Object _) => SeriesDetail.empty);
    if (!mounted) return;
    // 评论计数与评论入口同源：有计数才显示入口（官方该项默认 gone，
    // 由数据驱动显隐，见 res/layout/cjs.xml:11 与 SeriesCommentView.java:479-491）。
    if (series.commentCount > 0) _commentCount = series.commentCount;
    final status = switch (series.status) {
      1 => '已完结',
      0 => '连载中',
      3 => '今日更新',
      4 => '断更',
      _ => null,
    };
    final book = series.originalBook;
    final episodes = series.episodeCount > 0
        ? series.episodeCount
        : widget.eps.length;
    setState(() {
      _seriesDetail = series;
      _seriesStatus = status;
      _seriesTitle = series.title;
      _seriesCover = series.cover;
      _episodeLabel = seriesEpisodeLabel(
        status: series.status,
        count: episodes,
        currentIndex: _index,
      );
      _commentCount = series.commentCount;
      _originalBook = book == null
          ? null
          : RelatedWork(
              kind: 'book',
              id: book.id,
              title: book.title,
              cover: book.cover,
              label: '原著小说',
            );
    });
  }

  /// 官方右栏评论入口：竖屏走底部评论面板（`CommentDialogHelper`）。
  /// 面板数据走短剧剧评链路（`gx1/m.java:168-181`），与播放页共用剧集 id。
  Future<void> _withPlayerOverlay(Future<void> Function() open) async {
    if (_externalPanelOpen || _switchingSeries || !mounted) return;
    setState(() => _externalPanelOpen = true);
    try {
      await open();
    } finally {
      if (mounted) setState(() => _externalPanelOpen = false);
    }
  }

  /// Pause the player while a route pushed from this page is on top, and
  /// resume on return if the page still shows the same episode with the
  /// same player.
  ///
  /// In-app pushes do not change AppLifecycleState, so without this the
  /// video keeps playing behind DetailPage / ReaderPage / AudioPage
  /// (#39). Callers that drive their own load from the pushed route
  /// (detail's onPlayEpisode / onOpenRelatedSeries) update [_index] /
  /// [_switchingSeries] / [_player] synchronously on pop, so the guards
  /// below see their effect before resuming and the resume never fights
  /// their load. A pause failure must not block the navigation.
  Future<void> _pauseWhileRouteOnTop(Future<void> Function() push) async {
    final player = _player;
    final wasPlaying = _playing;
    final indexBefore = _index;
    if (player != null && wasPlaying) {
      try {
        await player.pause();
      } catch (_) {
        // Best-effort: the route still opens; a failed pause only means
        // the video may keep playing behind it.
      }
    }
    if (!mounted) return;
    await push();
    if (!mounted || !wasPlaying) return;
    if (!identical(_player, player)) return;
    if (_index != indexBefore || _switchingSeries) return;
    await player?.play();
  }

  /// 标题行「剧名 >」→ 剧集详情页（官方 `ql3/v0.a1()` 默认分支：
  /// `openShortSeriesDetailActivity`，页面名 `series_detail`）。
  ///
  /// 详情页在上时暂停播放，返回后按原状态续看；从详情再往深走（关联
  /// 原著 → 阅读/听书）时视频也不会在下面一直播（#39）。
  /// 详情页点「继续播放/选集」只是关掉详情并切集，不叠第二个播放器。
  void _openSeriesDetail() {
    if (!widget.shortSeries || widget.bookId.isEmpty) return;
    unawaited(
      _withPlayerOverlay(
        () => _pauseWhileRouteOnTop(
          () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => SeriesDetailPage(
                seriesId: widget.bookId,
                kind: widget.kind,
                title: _seriesTitle,
                cover: _seriesCover,
                episodes: widget.eps,
                startIndex: _index,
                watchedIds: _watchedIds,
                initialDetail: _seriesDetail,
                historyStore: widget.historyStore,
                hasPlaybackProgress:
                    (_player?.position.inMilliseconds ?? 0) > 0,
                seriesLoader: widget.seriesLoader,
                onOpenRelatedSeries: (entry) {
                  Navigator.of(context).pop();
                  unawaited(_switchRelatedSeries(entry));
                },
                onPlayEpisode: (index) {
                  // 详情页就在本播放器之上，pop 一次即回到播放页。
                  Navigator.of(context).pop();
                  if (index != _index) _selectEpisode(index);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openRelatedSeries() => _withPlayerOverlay(() async {
    // 横屏与选集抽屉/视频设置同一形态：右侧面板（宽屏上的底部弹层会被拉
    // 成一条通栏）。竖屏仍是官方底部 sheet。
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height;
    final entry = landscape
        ? await RelatedSeriesSheet.showSidePanel(context, widget.bookId)
        : await RelatedSeriesSheet.show(context, widget.bookId);
    if (entry != null && mounted) await _switchRelatedSeries(entry);
  });

  Future<void> _switchRelatedSeries(RelatedSeries entry) async {
    if (!mounted ||
        _switchingSeries ||
        entry.unavailable ||
        entry.id == widget.bookId) {
      return;
    }
    setState(() => _switchingSeries = true);
    final wasPlaying = _playing || _initVideo;
    // Persist before detaching; no old decoder or late autoplay may survive
    // into the next series. Keep the route alive: replacing it would complete
    // the feed's awaited push early and restart its inline player underneath.
    ++_loadGeneration;
    _pendingAutoplay = null;
    _prefetchTimer?.cancel();
    _progressTimer?.cancel();
    _watchTime.stop();
    _loadTrace?.finish('relatedSeries');
    try {
      // Capture progress synchronously, then release even if storage is slow.
      final saved = _persistProgress();
      await _teardownPlayer();
      await saved;
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SeriesDetailPage(
            seriesId: entry.id,
            kind: entry.kind,
            title: entry.title,
            cover: entry.cover,
            historyStore: widget.historyStore,
            seriesLoader: widget.seriesLoader,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _switchingSeries = false);
        await _loadVideo(autoplay: wasPlaying);
      }
    }
  }

  void _openComments() {
    if (!widget.shortSeries) return;
    unawaited(
      _withPlayerOverlay(
        () => PlayletCommentPanel.show(
          context,
          seriesId: widget.bookId,
          total: _commentCount,
        ),
      ),
    );
  }

  /// 热评数据：官方与评论计数同源（`comment/list` 的
  /// `comment_source=4/count=20` 那次请求，`a13/w.java:563-599`），
  /// 本地筛出 `dataType in {4,9}` 的条目。best-effort：失败就不显示胶囊。
  ///
  /// 请求按**当前集**的 vid 取（官方 `groupID = jVar.y()` 是单集 vid），
  /// 切集重拉；晚到的旧集响应按 vid 丢弃。
  Future<void> _loadHotComments() async {
    if (!widget.shortSeries || widget.bookId.isEmpty) return;
    final vid = widget.eps.isEmpty ? '' : widget.eps[_index].itemId;
    try {
      final loader = widget.hotCommentsLoader;
      final page = loader != null
          ? await loader(widget.bookId, vid)
          : await ApiClient.instance.playletHotComments(
              widget.bookId,
              vid: vid,
            );
      final current = widget.eps.isEmpty ? '' : widget.eps[_index].itemId;
      if (!mounted || current != vid) return;
      setState(() {
        if (page.totalCount > 0) _commentCount = page.totalCount;
        _hotComments = page.hotComments;
      });
    } catch (_) {
      // 热评是装饰，接口失败不能影响播放。
    }
  }

  /// 热评点击：官方的联动是发 `show_hot_comment_dialog` 并带
  /// `hot_comment_id`/`hot_reply_id`（Reply 型用父评论 id 当
  /// `hot_comment_id`）。本地等价是打开评论面板并滚到该条；
  /// Reply 型再带回复 id，面板自动进楼并用 source=1002 定位楼层。
  void _openHotComment(PlayletComment comment) {
    final isReply = comment.dataType == UgcRelativeType.reply;
    final target = isReply ? comment.parentCommentId : comment.id;
    unawaited(
      _withPlayerOverlay(
        () => PlayletCommentPanel.show(
          context,
          seriesId: widget.bookId,
          total: _commentCount,
          focusCommentId: target,
          focusReplyId: isReply ? comment.id : '',
        ),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 画面撑满的缺省值取决于竖/横屏（`FillScreenDataManager.a()` 的
    // `e.q()` 分支），因此要等 MediaQuery 可用之后才能读。
    unawaited(_loadPanelPreferences());
  }

  /// 读取持久化的已看集，并把旧历史记录迁移一次。
  ///
  /// 迁移只标记**旧记录里那一集**，绝不补造中间的集（工单 F07 的硬要求）。
  Future<void> _loadWatched() async {
    if (!widget.shortSeries || widget.bookId.isEmpty) return;
    try {
      final saved = await _history.load(widget.bookId);
      final migrated = await _watched.migrateFromHistory(
        seriesId: widget.bookId,
        saved: saved,
        episodes: widget.eps,
      );
      final ids = await _watched.ids(widget.bookId);
      if (!mounted) return;
      setState(
        () => _watchedIds = migrated.isEmpty ? ids : {...ids, ...migrated},
      );
    } catch (_) {
      // 已看标记是装饰，读不到就当没有。
    }
  }

  /// 标记一集已看（按剧集 id）。同一集只写一次存储：进度保存点里
  /// 含 2 秒定时器，不去重会反复落盘。
  Future<void> _markWatched(int index) async {
    if (!widget.shortSeries ||
        widget.bookId.isEmpty ||
        index < 0 ||
        index >= widget.eps.length) {
      return;
    }
    final id = widget.eps[index].itemId;
    if (id.isEmpty || _watchedIds.contains(id)) return;
    // 进度保存点会在页面销毁（dispose）时触发，元素已 defunct，
    // 不能 setState；直接改字段，可见态由下一次既有 rebuild 带出。
    _watchedIds = {..._watchedIds, id};
    await _watched.mark(widget.bookId, [id]);
  }

  /// 更多面板的两个开关：画面撑满读 SP，默认静音取进程内静态值。
  ///
  /// 两者都只改播放器的表现，不动进度：官方切换后不 pause 也不 seek
  /// （画面撑满 `FillScreenDataManager`；默认静音 `tm3/b`）。
  Future<void> _loadPanelPreferences() async {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final fillScreen = await PlayerPanelPreferences.loadFillScreen(
      portrait: portrait,
    );
    if (!mounted) return;
    setState(() {
      _fillScreen = fillScreen;
      _defaultMute = PlayerPanelPreferences.defaultMute;
    });
  }

  void _setFillScreen(bool enabled) {
    setState(() => _fillScreen = enabled);
    unawaited(PlayerPanelPreferences.saveFillScreen(enabled));
  }

  void _setDefaultMute(bool enabled) {
    setState(() => _defaultMute = enabled);
    PlayerPanelPreferences.setDefaultMute(enabled);
    // 官方默认静音是「起播时的音量」，切换时立刻作用到当前播放器，
    // 与官方「开启时默认静音/关闭默认静音」的即时反馈一致。
    final player = _player;
    if (player != null) {
      unawaited(
        player.setVolume(enabled ? 0 : 1).catchError((Object _) {
          // 音量设置失败不影响播放，也不该冒泡到 onError。
        }),
      );
    }
  }

  /// 官方开关落盘（`video_danmaku_switch_sp`）。开关状态就绪后才允许
  /// 发首批请求：关闭弹幕的用户一条请求都不该有（官方禁用时根本不建
  /// 弹幕视图）。
  Future<void> _loadDanmakuPreference() async {
    final enabled = await DanmakuPreference.load();
    if (!mounted) return;
    setState(() => _danmakuEnabled = enabled);
    _danmakuLoader.setEnabled(enabled);
    if (enabled) _loadDanmaku();
  }

  /// 弹幕设置（官方 `danmaku_config`）：字号/透明度/速度/行数横竖屏密度。
  Future<void> _loadDanmakuSettings() async {
    final settings = await DanmakuSettings.load();
    if (!mounted) return;
    setState(() => _danmakuSettings = settings);
  }

  /// 弹幕取数的默认实现：每次请求挂一个取消柄，切集/销毁时作废在飞
  /// 请求（`ApiClient.withCancellation` 的既有机制，不另建链路）。
  Future<PlayletCommentPage> _fetchDanmaku(DanmakuFetchRequest request) {
    final flight = BackendRequest();
    _danmakuFlight = flight;
    return ApiClient.instance.withCancellation(flight, () {
      return ApiClient.instance.playletDanmaku(
        request.vid,
        seriesId: widget.bookId,
        startOffsetMs: request.startOffsetMs,
        duration: _duration,
        cursor: request.cursor,
      );
    });
  }

  /// 官方取数（`DanmakuRequestHelper.java:314-329`）：`:group_id` 是当前
  /// vid，剧集 id 进 `business_param.book_id`，时间毫秒。best-effort：
  /// 失败不显示弹幕，不影响播放。调度（预取/补数/竞态）都在
  /// [DanmakuLoader] 里。
  void _loadDanmaku() {
    if (!widget.shortSeries || widget.eps.isEmpty) return;
    final vid = widget.eps[_index].itemId;
    if (vid.isEmpty) return;
    _danmakuFlight?.cancel();
    _danmakuFlight = null;
    // 首批按官方 ON_VIDEO_PLAY 在起始位置取数：初始与切集都是 0，
    // 开关重新打开时按当前集的播放位置续取。历史进度如果已经知道、
    // 但播放器还没把这一集标成活跃，用记下的恢复位置，避免先向 0ms
    // 要一页然后被 hasMore=false 卡住。
    final resumed = _activeIndex == _index;
    final resumeMs = _danmakuResumeIndex == _index ? _danmakuResumeMs : null;
    _danmakuResumeIndex = null;
    _danmakuResumeMs = null;
    final startMs = resumed
        ? (_player?.position.inMilliseconds ?? 0)
        : (resumeMs ?? 0);
    _danmakuLoader.reset(vid: vid, startMs: startMs < 0 ? 0 : startMs);
  }

  void _rememberDanmakuResume(int index, int positionMs) {
    if (!widget.shortSeries || positionMs <= 0) return;
    if (index < 0 || index >= widget.eps.length) return;
    if (_danmakuLoader.videoId == widget.eps[index].itemId) return;
    _danmakuResumeIndex = index;
    _danmakuResumeMs = positionMs;
  }

  /// chrome 上报的最终 seek 目标（官方 `ON_SEEK_FINISH`）：调度器自行
  /// 判断目标是否已被覆盖、是否需要清游标重拉。
  void _onDanmakuSeek(Duration target) {
    if (!widget.shortSeries) return;
    _danmakuLoader.onSeek(target.inMilliseconds);
  }

  /// 官方开关切换：落盘 + Toast 文案（`i95/i.java:339-346`）。重新打开时
  /// 调度器整池重灌，按当前播放位置续取（官方重新 start 的语义）。
  Future<void> _toggleDanmaku() async {
    final enabled = !_danmakuEnabled;
    setState(() => _danmakuEnabled = enabled);
    _danmakuLoader.setEnabled(enabled);
    if (enabled) _loadDanmaku();
    await DanmakuPreference.save(enabled);
    if (!mounted) return;
    PlayerToast.show(
      context,
      enabled ? danmakuEnabledToast : danmakuDisabledToast,
    );
  }

  /// 选集面板头部下方的关联原著（官方 `a1.java:1819-1828`）。
  ///
  /// 官方三个条件都要满足：配置 `relate_book_in_episodes_dialog`（默认关）、
  /// `videoRelateBook.bookInfo` 非空、且不在 `SeriesDeliverUserRelateBookRevert`
  /// 的回滚实验里。本地只有前两条可判，第三条的开关未接入。
  EpisodeRelateBook? get _episodeRelateBook {
    if (!PlayerStyleConfig.instance.relateBookInEpisodesDialog) return null;
    final book = _originalBook;
    if (book == null) return null;
    return EpisodeRelateBook(id: book.id, title: book.title, cover: book.cover);
  }

  /// 原著书卡点击 → 原著详情页（audio 页同一条 MediaItem 跳转链路）。
  ///
  /// 进详情前暂停，返回后按原状态续看；否则视频会在书详情乃至从详情
  /// 再进的阅读/听书下面一直播（#39）。
  void _openOriginalBook() {
    final book = _originalBook;
    if (book == null) return;
    unawaited(
      _pauseWhileRouteOnTop(
        () => openBookDetail(
          context,
          MediaItem(
            id: book.id,
            title: book.title,
            cover: book.cover,
            author: '',
            badge: book.label,
            ep: '',
            kind: 'book',
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unregisterFairMemoryFlush?.call();
    _unregisterFairMemoryFlush = null;
    unawaited(NativePlayer.setKeepScreenOn(false).catchError((Object _) {}));
    if (_floating) unawaited(_stopFloating());
    NativePlayer.clearRemoteCommandHandler();
    _progressTimer?.cancel();
    _prefetchTimer?.cancel();
    _autoCacheTimer?.cancel();
    _danmakuProgressTimer?.cancel();
    _danmakuFlight?.cancel();
    _danmakuLoader.dispose();
    _seekHintTimer?.cancel();
    _sources.dispose();
    _loadTrace?.finish('disposed');
    ++_loadGeneration;
    _pagingSettled?.complete();
    _pagingSettled = null;
    _watchTime.stop();
    unawaited(_persistProgress());
    unawaited(_teardownPlayer());
    // 提示挂在根 Overlay 上，页面退出必须摘掉，否则会飘到下一页上。
    PlayerToast.hide();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lastLifecycleState = state;
    _loadTrace?.setAppActive(playbackAppIsActive(state));
    _syncWatchClock();
    if (playbackAppIsActive(state)) {
      _resumePendingAutoplay();
      if (_floating) unawaited(_stopFloating());
    } else {
      unawaited(_persistProgress());
      if (state == AppLifecycleState.inactive) {
        // 悬浮窗在仍属前台的过渡态启动服务（后台启动前台服务会被系统拒绝），
        // 等 hidden 确认切后台后再显示悬浮窗；只是下拉通知栏时 resumed 会
        // 跟着来，服务随即停掉，悬浮窗全程不出现。
        if (_canFloat()) unawaited(_startFloating());
      } else if (state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused) {
        if (_floating) unawaited(NativePlayer.showFloating());
      }
    }
    _updatePrefetch();
  }

  /// 是否满足进悬浮窗的条件：开关开 + 正在播 + 播放器就绪。
  bool _canFloat() =>
      !isWindowsDesktop &&
      !_floating &&
      PlayerPreferences.floatingWindow.value &&
      _player != null &&
      _playing &&
      _error == null;

  String _episodeTitle() => widget.eps.isEmpty ? '' : widget.eps[_index].title;

  /// 启动悬浮窗：原生侧起服务并在 surface 就绪后把画面换到悬浮窗。
  /// 只有原生侧成功返回才置 `_floating`：焦点被占 / 服务启动失败时
  /// 不进悬浮，交给 chrome 的切后台暂停。
  Future<void> _startFloating() async {
    final player = _player;
    final playerId = player?.playerId;
    if (player == null || playerId == null || _floating) return;
    // 权限可能在设置里开启后又被系统收回，这里再查一次。
    if (!await NativePlayer.canDrawOverlays()) return;
    try {
      await NativePlayer.startFloating(
        playerId: playerId,
        title: _seriesTitle.isNotEmpty ? _seriesTitle : widget.title,
        episode: _episodeTitle(),
        playing: _playing,
        hasPrev: _index > 0,
        hasNext: _index + 1 < widget.eps.length,
        positionMs: player.position.inMilliseconds,
        durationMs: player.duration.inMilliseconds,
        videoWidth: player.videoWidth,
        videoHeight: player.videoHeight,
      );
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (_lastLifecycleState == AppLifecycleState.resumed) {
      // 启动过程中已回前台（只是下拉通知栏）：不进悬浮，立刻停服务。
      await NativePlayer.stopFloating();
      return;
    }
    _floating = true;
    NativePlayer.setRemoteCommandHandler(onAction: _handleFloatingRemoteAction);
    if (_lastLifecycleState == AppLifecycleState.hidden ||
        _lastLifecycleState == AppLifecycleState.paused) {
      // 启动过程中已切后台：hidden 分支已跑过（那时 _floating 还是 false），
      // 这里补一次显示。
      await NativePlayer.showFloating();
    }
  }

  /// 停悬浮窗：画面回 Flutter 纹理，停服务，清远程控制。
  Future<void> _stopFloating() async {
    if (!_floating) return;
    _floating = false;
    NativePlayer.clearRemoteCommandHandler();
    await NativePlayer.stopFloating();
  }

  /// 后台自动切集：新播放器接手悬浮窗（服务不重启，避免后台启动限制）。
  /// 接手失败悬浮窗黑屏，无法恢复，只能等用户关闭 / 回前台。
  Future<void> _swapFloatingPlayer(NativePlayer player) async {
    final playerId = player.playerId;
    if (!_floating || playerId == null) return;
    try {
      await NativePlayer.swapFloatingPlayer(playerId: playerId);
    } catch (_) {
      return;
    }
    await NativePlayer.updateFloating(
      episode: _episodeTitle(),
      playing: _playing,
      hasPrev: _index > 0,
      hasNext: _index + 1 < widget.eps.length,
      positionMs: player.position.inMilliseconds,
      durationMs: player.duration.inMilliseconds,
    );
  }

  /// 悬浮窗 / 通知的远程控制：播放暂停、上下集、关闭、回应用。
  void _handleFloatingRemoteAction(String action) {
    if (!mounted) return;
    final player = _player;
    switch (action) {
      case 'playPause':
        if (player == null) return;
        if (_playing) {
          unawaited(player.pause());
        } else {
          unawaited(player.play());
        }
      case 'prev':
        if (_index > 0) unawaited(_selectEpisode(_index - 1));
      case 'next':
        if (_index + 1 < widget.eps.length) {
          unawaited(_selectEpisode(_index + 1));
        }
      case 'stop':
        // 悬浮窗关闭：暂停并收起悬浮窗。
        if (player != null) unawaited(player.pause());
        unawaited(_stopFloating());
      case 'fullscreen':
        // 服务已拉起应用并藏起悬浮窗；这里收起服务并恢复纹理。
        unawaited(_stopFloating());
    }
  }

  void _onPagingChanged(bool paging) {
    if (_paging == paging) return;
    _paging = paging;
    if (paging) {
      _pagingSettled = Completer<void>();
    } else {
      _pagingSettled?.complete();
      _pagingSettled = null;
      final completedGeneration = _pendingCompletion;
      _pendingCompletion = null;
      if (completedGeneration != null &&
          _current(completedGeneration) &&
          _activeIndex == _index) {
        unawaited(
          _selectEpisode(_index + 1, expectedGeneration: completedGeneration),
        );
      } else {
        _resumePendingAutoplay();
      }
    }
    _updatePrefetch();
  }

  /// 首次横滑或超时后收起引导并写回「已显示」（chrome 在
  /// `_startDragSeek`/`_endDragSeek` 里回调）。
  void _consumeSeekHint() {
    _seekHintTimer?.cancel();
    _seekHintTimer = null;
    if (!_seekHintVisible) return;
    setState(() => _seekHintVisible = false);
    unawaited(SwipeGuideStore.instance.markSeekHintShown());
  }

  Future<bool> _waitForPaging(int generation, [NativePlayer? player]) async {
    while (_current(generation, player) && _paging) {
      await _pagingSettled!.future;
    }
    return _current(generation, player);
  }

  bool get _appActive {
    final state = WidgetsBinding.instance.lifecycleState;
    return playbackAppIsActive(state);
  }

  void _resumePendingAutoplay() {
    final generation = _loadGeneration;
    unawaited(
      _tryAutoplay(generation).catchError((Object error) {
        _fail(error, generation);
      }),
    );
  }

  Future<void> _tryAutoplay(int generation) async {
    final player = _pendingAutoplay;
    if (isWindowsDesktop && player != null) {
      AppLog.d(
        'desktop-autoplay',
        'active=$_appActive lifecycle=${WidgetsBinding.instance.lifecycleState} paging=$_paging current=${_current(generation, player)}',
      );
    }
    if (player == null ||
        !_current(generation, player) ||
        (!_appActive && !_floating) ||
        _paging) {
      return;
    }
    _pendingAutoplay = null;
    _loadTrace?.playRequested();
    await player.play();
    if (_current(generation, player) && !_appActive && !_floating) {
      // The lifecycle can change while the platform acknowledges play.
      _pendingAutoplay = player;
      await player.pause();
    }
  }

  bool _canPrefetch(int generation, NativePlayer player) =>
      _current(generation, player) &&
      !_switchingSeries &&
      _appActive &&
      !_paging &&
      !_initVideo &&
      _error == null &&
      _activeIndex == _index &&
      player.firstFrameRendered &&
      player.playing &&
      !player.buffering &&
      _index + 1 < widget.eps.length;

  void _updatePrefetch() {
    final generation = _loadGeneration;
    final player = _player;
    if (player == null || !_canPrefetch(generation, player)) {
      _prefetchTimer?.cancel();
      _prefetchTimer = null;
      return;
    }
    if (_prefetchTimer != null ||
        _prefetchQueuedGeneration == generation ||
        _prefetchAttemptedGeneration == generation) {
      return;
    }
    final next = widget.eps[_index + 1];
    _prefetchTimer = Timer(const Duration(milliseconds: 750), () {
      _prefetchTimer = null;
      if (!_canPrefetch(generation, player)) return;
      _prefetchQueuedGeneration = generation;
      unawaited(
        _sources
            .prefetch(
              next,
              stillWanted: () {
                if (!_canPrefetch(generation, player)) return false;
                _prefetchAttemptedGeneration = generation;
                return true;
              },
            )
            .whenComplete(() {
              if (_prefetchQueuedGeneration == generation) {
                _prefetchQueuedGeneration = null;
              }
              if (_current(generation, player)) _updatePrefetch();
            }),
      );
    });
  }

  /// 边看边往后缓存：这一集出画面后，把后面几集排进离线下载队列，
  /// 断网 / 信号差的时候也能接着看。
  ///
  /// 与小说阅读时预取前后各一章同构，区别是短剧一集几十 MB，所以默认
  /// 限 Wi-Fi、限 5 集，并且只保留最近的一段（见 [_trimAutoCache]）。
  /// 用户手动下载的一律不碰：那批记录的 `auto` 是 false。
  void _scheduleAutoCache(NativePlayer player) {
    if (!widget.shortSeries || widget.bookId.isEmpty) return;
    if (_autoCacheFor == _index) return;
    // 同一集的首帧会来好几次（起播、换流、重试），别每次都把 2 秒推后。
    if (_autoCacheTimer != null && _autoCacheTimerIndex == _index) return;
    _autoCacheTimer?.cancel();
    _autoCacheTimerIndex = _index;
    _autoCacheTimer = Timer(const Duration(seconds: 2), () {
      _autoCacheTimer = null;
      _autoCacheTimerIndex = null;
      // 判活用播放器实例而不是 generation：换流重试会让 generation 递增，
      // 拿旧的 generation 判会把这一集的预缓存白白放弃掉。
      if (!mounted || !identical(player, _player)) return;
      if (_autoCacheFor == _index) return;
      unawaited(_autoCacheNext());
    });
  }

  /// 当前实际在播的清晰度（像素高度），取不到返回 null。
  ///
  /// 优先用选档时记下的高度：`variants` 里可能有两条 url 相同、高度不同的
  /// 别名流，按 url 反查只会拿到第一条，不一定是正在播的那条。没选过档时看
  /// 播放器解码出来的高度——播的是上游默认流时，它到底绑到哪一档客户端并不
  /// 知道，但解码后就有答案了。两者都取不到才退回按 url 认领。
  int? _playingHeight() {
    final selected = _renditionHeight;
    if (selected != null) return selected;
    final decoded = _player?.videoHeight ?? 0;
    if (decoded > 0) return decoded;
    final source = _currentSource;
    if (source == null) return null;
    for (final variant in source.variants) {
      if (variant.url != source.url) continue;
      return variant.height > 0 ? variant.height : null;
    }
    return null;
  }

  Future<void> _autoCacheNext() async {
    final index = _index;
    final prefs = DramaCachePreferences.instance;
    final ahead = prefs.ahead.value;
    if (ahead <= 0) return;
    final upcoming = autoCacheEpisodes(
      episodes: widget.eps,
      currentIndex: index,
      ahead: ahead,
    );
    if (upcoming.isEmpty) return;
    // store 未就绪（Hive 未初始化的测试环境）直接跳过，别碰 openBox。
    if (!_downloadStore.isReady) return;
    if (prefs.wifiOnly.value) {
      // 测不出网络形态时按「不是 Wi-Fi」处理：自动缓存没有流量确认兜底。
      final view = await probeConnectivity();
      if (view == null || !view.online || view.metered) return;
    }
    if (!mounted) return;
    try {
      await _downloader.enqueue(
        drama: CachedDrama(
          id: widget.bookId,
          title: _seriesTitle,
          cover: widget.cover,
          episodes: widget.eps,
        ),
        episodes: upcoming,
        auto: true,
        // 用户在面板里挑过画质就守那个上限；没挑过就跟**当前正在播的这一档**
        // 保持一致 —— 播放器已经按网速/清晰度选过一次了，自动缓存再自作
        // 主张挑最高档，只会让流量和空间白涨。
        maxHeight: prefs.downloadHeight.value != 0
            ? prefs.downloadHeight.value
            : _playingHeight(),
      );
      // 排上了才算这一集处理过：上面每条早退都不算，否则那一集永远没
      // 机会再自动缓存（冷启动 store 未就绪、或在移动网络下起播都会）。
      _autoCacheFor = index;
      await _trimAutoCache(ahead);
    } catch (_) {
      // 预缓存是机会性的：失败（权限、空间、解析不到地址）不能影响播放，
      // 也不打扰用户 —— 用户手动缓存时才会看到具体错误。
    }
  }

  /// 跟着播放进度丢掉自动缓存的旧集，只留「当前集之前 2×ahead」以后的。
  ///
  /// 只删 `auto == true` 的记录 —— 用户在缓存面板里手动下的集永远不动。
  Future<void> _trimAutoCache(int ahead) async {
    final cutoff = _index - ahead * 2;
    if (cutoff <= 0) return;
    final store = _downloadStore;
    try {
      final summaries = await store.dramas();
      for (final summary in summaries) {
        if (summary.drama.id != widget.bookId) continue;
        // 集记录里的 index 是「入队时的相对序号」，不能当全集位置用；
        // 目录 `drama.episodes` 的顺序才是权威的。
        final order = {
          for (final (position, episode) in summary.drama.episodes.indexed)
            episode.itemId: position,
        };
        for (final episode in summary.episodes) {
          if (!episode.auto) continue;
          final position = order[episode.itemId];
          if (position == null || position >= cutoff) continue;
          await store.removeEpisode(episode.itemId);
        }
      }
    } catch (_) {
      // 清理失败只影响磁盘占用，不影响播放与已缓存内容的可用性。
    }
  }

  void _onFirstFrame(NativePlayer player, int generation) {
    if (!_current(generation, player) || !player.firstFrameRendered) return;
    _loadTrace?.firstFrame();
    if (!_initVideo && _activeIndex == _index) {
      _loadTrace?.finish('firstFrame');
      if (!_hasDisplayed) {
        // Native create acknowledges preparation, not a usable CDN/decoder.
        // Keep the previous resume record until this episode is visible.
        // Note: .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md
        _hasDisplayed = true;
        // 首帧只更新续播记录。官方「已看」= `video_progress` SP 有该 vid 的
        // 条目（`com/dragon/read/video/d.java:56-58`），而 SP 只在**暂停/
        // 切集/保存进度**时写入（`video/d.java:122-126` 的调用点）——
        // 播放开始不写。因此已看标记挂在 _persistProgress 的保存点上，
        // 不在首帧（工单 F07「未出首帧/看完即走」用例）。
        unawaited(_persistProgress(markWatched: false));
        _syncWatchClock();
      }
    }
    _updatePrefetch();
    _scheduleAutoCache(player);
  }

  Future<void> _teardownPlayer() {
    // 这一集的调度还没到点就作废：换集/换流后的 2 秒不该再去排它。
    _autoCacheTimer?.cancel();
    _autoCacheTimer = null;
    _autoCacheTimerIndex = null;
    final old = _player;
    _player = null;
    _activeIndex = null;
    _hasDisplayed = false;
    _pendingAutoplay = null;
    _pendingCompletion = null;
    final cancellations = [
      for (final subscription in _subs) subscription.cancel(),
    ];
    _subs.clear();
    final release = () async {
      await Future.wait(cancellations);
      if (old != null) {
        try {
          if (old.isCreated) await old.pause();
        } finally {
          await old.dispose();
        }
      }
    }();
    // Every new session waits for all previously detached players, even if a
    // later request supersedes the request which initiated their teardown.
    _releases = Future.wait([
      _releases,
      release,
    ]).then<void>((_) {}).catchError((Object _) {});
    return _releases;
  }

  Future<void> _loadVideo({bool refresh = false, bool autoplay = true}) async {
    if (!mounted || _switchingSeries || widget.eps.isEmpty) return;
    _loadTrace?.finish('superseded');
    final generation = ++_loadGeneration;
    final index = _index;
    final episode = widget.eps[index];
    final trace = _loadTrace = _diagnostics.begin(
      attempt: generation,
      episode: index + 1,
      trigger: refresh
          ? 'retry'
          : generation == 1
          ? 'initial'
          : 'switch',
      appActive: _appActive,
    );
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    _sources.retainOnly({
      episode.itemId,
      if (index + 1 < widget.eps.length) widget.eps[index + 1].itemId,
    });
    _progressTimer?.cancel();
    _watchTime.stop();
    unawaited(_persistProgress());
    final release = _teardownPlayer();
    _watchTime.reset();
    setState(() {
      _initVideo = true;
      _error = null;
      _duration = Duration.zero;
      _playing = false;
    });

    NativePlayer? candidate;
    try {
      // 离线优先（官方 isOfflineVideo 语义）：已缓存的集直接读本地加密
      // 文件，不请求取流接口；文件被用户清掉时静默回退在线链路。
      final offline = await _offlineSource(episode);
      final EpisodeSource source;
      int? renditionHeight;
      if (offline != null) {
        trace.source = 'offline';
        source = offline;
      } else {
        final request = _sources.request(episode, refresh: refresh);
        trace.source = request.origin.name;
        var online = await request.future;
        // 会话内记住的画质选择（官方=引擎当前档）：按画质名在本集自己
        // 的 variants 里找，找到就用，找不到回默认（#60：换下一集不
        // 应变回默认画质）。记忆由 [QualityMemory] 在 Feed 与播放页
        // 之间共享；只记名、不搬 variant 对象——variant 的 URL 属于
        // 它自己的集，搬过来会播错集的流。
        final chosenName = QualityMemory.nameFor(widget.bookId);
        if (chosenName != null) {
          for (final variant in online.variants) {
            if (variant.name == chosenName) {
              online = online.withVariant(variant);
              renditionHeight = variant.height > 0 ? variant.height : null;
              break;
            }
          }
        }
        source = online;
      }
      if (!_current(generation)) return;
      _currentSource = source;
      // 每次装载都重新认领：换集后没选过档就是 null，不留上一集的高度。
      _renditionHeight = renditionHeight;
      final sourceUri = Uri.tryParse(source.url);
      final isRemote =
          sourceUri != null &&
          (sourceUri.scheme == 'http' || sourceUri.scheme == 'https') &&
          sourceUri.host.isNotEmpty;
      if (!isRemote && sourceUri?.scheme != 'file') {
        throw const ApiException('获取播放地址失败');
      }
      trace.stage('releaseWait');
      await release;
      if (!_current(generation)) return;
      trace.stage('history');
      Map<String, dynamic>? saved;
      try {
        saved = await _history.load(widget.bookId);
      } catch (_) {
        // Local storage is optional for starting a video.
      }
      trace.stage('pagingBeforeCreate');
      if (!await _waitForPaging(generation)) return;
      if (saved?['kind'] == 'manju') _historyKind = 'manju';
      trace.stage('create');
      final player = candidate = widget.playerFactory?.call() ?? NativePlayer();
      _player = player;
      await player.create(source.url, source.keyHex);
      if (!_current(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      trace.stage('initialize');
      _subscribe(player, generation);
      _onFirstFrame(player, generation);
      // Keep the texture mounted beneath the cover while rate/seek initialize.
      setState(() {});
      var rate = 1.0;
      try {
        rate = await PlayerPreferences.loadPlaybackRate();
      } catch (_) {}
      if (!_current(generation, player)) return;
      await player.setRate(rate);
      if (!_current(generation, player)) return;
      // 官方「默认静音」是**起播音量**（`tm3/b.java:17-20` 的静态标志），
      // 每次新建播放器都要重新套一遍。音量失败不能拖垮播放：
      // 官方音量只是表现层，起播照旧。
      try {
        await player.setVolume(_defaultMute ? 0 : 1);
      } catch (_) {
        // 忽略：默认音量不成立时保持播放器的默认音量。
      }
      if (!_current(generation, player)) return;

      final savedIndex = resumeEpisodeIndex(saved, widget.eps);
      final rawPosition = saved?['position'];
      final savedPosition = rawPosition is num ? rawPosition.toDouble() : 0.0;
      final rawDuration = saved?['duration'];
      final savedDuration = rawDuration is num && rawDuration.isFinite
          ? rawDuration.toDouble()
          : 0.0;
      final durationSeconds = player.duration > Duration.zero
          ? player.duration.inMilliseconds / 1000
          : savedDuration;
      // 听书回传的锚点优先于历史存档（更「新」）；只消费一次，非本集
      // （load 被抢先换到别的集）则丢弃。
      final pendingResume = _listenResume;
      _listenResume = null;
      final listenResumeMs = pendingResume != null && pendingResume.$1 == index
          ? pendingResume.$2.inMilliseconds.toDouble()
          : -1.0;
      final requestedMs = listenResumeMs >= 0
          ? listenResumeMs
          : savedPosition * 1000;
      final resumeSeconds = requestedMs / 1000;
      if ((listenResumeMs >= 0 || savedIndex == index) &&
          requestedMs.isFinite &&
          requestedMs > 0 &&
          requestedMs < 0x7fffffffffffffff &&
          (durationSeconds <= 0 || resumeSeconds < durationSeconds)) {
        // Completed/out-of-range entries restart instead of immediately
        // reaching the end again. Unknown duration must not erase a valid seek.
        final targetMs = requestedMs.round();
        // chrome 的 onSeeked 只覆盖手势。恢复进度是直接 seek，不通知的话
        // 调度器仍停在 0ms，首批 hasMore=false 后目标位置补不到。
        _rememberDanmakuResume(index, targetMs);
        await player.seek(Duration(milliseconds: targetMs));
        if (!_current(generation, player)) return;
        if (widget.shortSeries &&
            _danmakuLoader.videoId == widget.eps[index].itemId) {
          _danmakuResumeIndex = null;
          _danmakuResumeMs = null;
          _onDanmakuSeek(Duration(milliseconds: targetMs));
        }
      }

      trace.stage('pagingBeforePlay');
      if (!await _waitForPaging(generation, player)) return;
      setState(() {
        _activeIndex = index;
        _duration = player.duration;
        _playing = player.playing;
        _initVideo = false;
      });
      trace.stage('autoplayWait');
      _onFirstFrame(player, generation);
      _pendingAutoplay = autoplay ? player : null;
      await _tryAutoplay(generation);
      if (!_current(generation, player)) return;
      // 后台自动切集：新播放器接手悬浮窗，旧的已在 _teardownPlayer 里销毁。
      if (_floating) await _swapFloatingPlayer(player);
      _onFirstFrame(player, generation);
      _updatePrefetch();
      _syncWatchClock();
      _progressTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        // A paused episode must not keep re-stamping its history record.
        if (_playing) unawaited(_persistProgress());
      });
    } catch (error) {
      if (_current(generation)) {
        _fail(error, generation);
      } else {
        await candidate?.dispose();
      }
    }
  }

  void _fail(Object error, int generation) {
    if (!_current(generation)) return;
    final errorCode = error is NativePlaybackException ? error.errorCode : null;
    final httpStatusCode = switch (error) {
      NativePlaybackException() => error.httpStatusCode,
      ApiException() => error.statusCode,
      _ => null,
    };
    _loadTrace?.fail(errorCode: errorCode, httpStatusCode: httpStatusCode);
    _sources.invalidate(widget.eps[_index].itemId);
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    ++_loadGeneration;
    _progressTimer?.cancel();
    _watchTime.stop();
    unawaited(_persistProgress());
    unawaited(_teardownPlayer());
    // 悬浮窗里播失败：通知状态改成暂停，用户可用悬浮窗 / 通知的关闭收起。
    if (_floating) {
      unawaited(NativePlayer.updateFloating(playing: false));
    }
    setState(() {
      _error = PlaybackIssue.fromError(error);
      _initVideo = false;
      _playing = false;
    });
  }

  /// The source the current player was created from (includes the rendition
  /// list). The session-level quality choice lives in [QualityMemory],
  /// shared with the feed: the official client keeps the resolution on the
  /// engine for the session only; no cross-launch preference exists there,
  /// so none is stored here either.
  EpisodeSource? _currentSource;

  /// 听书页回传的续看锚点 (集号, 进度)：[_openListenMode] 在自动连播跨集
  /// 时设置，只对匹配集的下一次 [_loadVideo] 生效一次——此时本地历史
  /// 存档还停在原集，听书进度比它新。
  (int, Duration)? _listenResume;

  /// Switches the playing episode to [variant]: reopen the crypto stream on
  /// the new rendition, keep the playback position and rate, and report the
  /// seek to the danmaku scheduler. The official client switches resolutions
  /// inside one engine session; here every rendition is its own encrypted
  /// URL, so an equivalent switch reopens the stream on the same episode.
  Future<void> _switchVariant(EpisodeVariant variant) async {
    final source = _currentSource;
    final player = _player;
    if (source == null || player == null || _initVideo) return;
    if (source.variants.every((v) => v.url != variant.url)) return;
    if (variant.url == source.url) return;
    final generation = ++_loadGeneration;
    final resume = player.position;
    final resumeMs = resume.inMilliseconds;
    final wasPlaying = _playing;
    final episode = widget.eps[_index];
    QualityMemory.remember(widget.bookId, variant.name);
    _currentSource = source.withVariant(variant);
    _renditionHeight = variant.height > 0 ? variant.height : null;
    final release = _teardownPlayer();
    NativePlayer? candidate;
    try {
      await release;
      if (!_current(generation)) return;
      final fresh = candidate = widget.playerFactory?.call() ?? NativePlayer();
      _player = fresh;
      // `_teardownPlayer` 把 `_activeIndex` 一并清空了，换档换的是同一集的
      // 另一路流，所以必须补回来：它为 null 时 `enabled`（下传给 chrome）
      // 恒假，chrome 的 `_ready` 随之恒假，于是①单击画面不再切播放/暂停
      // （`_togglePlayback` 的 `!_ready` 早退）②`fitVideo` 落到 viewport
      // 而不是按源尺寸算出的 `layout.video`，画面被拉满整屏——换档后画面
      // 拉伸与点击失效是同一个真因，直到换集才会恢复。
      // Note: 换档清空 `_activeIndex` 引发的四个后果与本位置的取值依据 —
      // 见 .agents/notes/implemented/bug-fix/2026-10-14-quality-switch-clears-active-index.md
      _activeIndex = _index;
      await fresh.create(variant.url, variant.keyHex);
      if (!_current(generation, fresh)) {
        await fresh.dispose();
        return;
      }
      if (fresh.lastError case final Object error) throw error;
      _subscribe(fresh, generation);
      _onFirstFrame(fresh, generation);
      setState(() {});
      var rate = 1.0;
      try {
        rate = await PlayerPreferences.loadPlaybackRate();
      } catch (_) {}
      if (!_current(generation, fresh)) return;
      await fresh.setRate(rate);
      if (!_current(generation, fresh)) return;
      try {
        await fresh.setVolume(_defaultMute ? 0 : 1);
      } catch (_) {}
      if (!_current(generation, fresh)) return;
      if (resumeMs > 0) {
        _rememberDanmakuResume(_index, resumeMs);
        await fresh.seek(resume);
        if (!_current(generation, fresh)) return;
        if (widget.shortSeries && _danmakuLoader.videoId == episode.itemId) {
          _danmakuResumeIndex = null;
          _danmakuResumeMs = null;
          _onDanmakuSeek(resume);
        }
      }
      if (wasPlaying) {
        await fresh.play();
        if (!_current(generation, fresh)) return;
      }
      setState(() => _playing = wasPlaying);
    } catch (error) {
      if (_current(generation)) {
        _fail(error, generation);
      } else {
        await candidate?.dispose();
      }
    }
  }

  void _subscribe(NativePlayer player, int generation) {
    _subs.addAll([
      player.bufferingStream.listen((_) {
        if (!_current(generation, player)) return;
        setState(() {});
        _syncWatchClock();
        _updatePrefetch();
      }),
      player.videoSizeStream.listen((_) {
        if (_current(generation, player)) setState(() {});
      }),
      player.textureIdStream.listen((_) {
        if (_current(generation, player)) setState(() {});
      }),
      player.firstFrameStream.listen((_) {
        if (!_current(generation, player)) return;
        _onFirstFrame(player, generation);
        setState(() {});
      }),
      player.durationStream.listen((duration) {
        if (_current(generation, player) && _duration != duration) {
          setState(() => _duration = duration);
        }
      }),
      player.playingStream.listen((playing) {
        if (!_current(generation, player)) return;
        if (_playing != playing) setState(() => _playing = playing);
        _syncWatchClock();
        _updatePrefetch();
        // 悬浮窗通知里的播放状态跟着变（系统按最后同步的位置 + 倍速外推）。
        if (_floating) {
          unawaited(
            NativePlayer.updateFloating(
              playing: playing,
              positionMs: player.position.inMilliseconds,
              durationMs: player.duration.inMilliseconds,
            ),
          );
        }
      }),
      player.completedStream.listen((completed) {
        if (!_current(generation, player) || _activeIndex != _index) {
          return;
        }
        if (!completed) {
          _pendingCompletion = null;
          return;
        }
        // Completion must persist even when there is no next episode or a
        // paging gesture delays it. Each snapshot settles only new watch time.
        // Note: .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md
        unawaited(_persistProgress());
        if (_paging) {
          _pendingCompletion = generation;
          return;
        }
        unawaited(_selectEpisode(_index + 1, expectedGeneration: generation));
      }),
      player.errorStream.listen((error) => _fail(error, generation)),
    ]);
  }

  void _syncWatchClock() {
    final state = WidgetsBinding.instance.lifecycleState;
    final active = playbackAppIsActive(state);
    if (active &&
        !_switchingSeries &&
        _hasDisplayed &&
        _playing &&
        !(_player?.buffering ?? true) &&
        _error == null) {
      _watchTime.start();
    } else {
      _watchTime.stop();
    }
  }

  Map<String, dynamic> _historyEntry(int index, NativePlayer player) {
    final durationMs = player.duration > Duration.zero
        ? player.duration.inMilliseconds
        : 0;
    final rawPositionMs = player.position.inMilliseconds;
    final positionMs = durationMs > 0
        ? rawPositionMs.clamp(0, durationMs)
        : rawPositionMs < 0
        ? 0
        : rawPositionMs;
    return {
      'id': widget.bookId,
      'kind': _historyKind,
      'title': widget.title,
      'bookId': widget.bookId,
      'seriesId': widget.bookId,
      'episodeId': widget.eps[index].itemId,
      'chapterId': widget.eps[index].itemId,
      'episode': index,
      'progress': durationMs > 0 ? positionMs / durationMs : 0.0,
      'position': positionMs / 1000,
      'duration': durationMs / 1000,
      'maxScroll': durationMs / 1000,
      'cover': widget.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 保存当前集的续播进度；除首帧外的所有调用点都对应官方
  /// `video_progress` 的写入时机（暂停/切集/完成/退出），同时把该集
  /// 记为已看——官方「已看」判据就是这条进度记录存在
  /// （`br3/p0.java:47` -> `video/d.java:56-58`）。
  // Note: 已看标记曾挂首帧，2026-09-27 对齐官方保存点 —
  // 见 .agents/notes/implemented/bug-fix/2026-09-27-playlet-evidence-flips.md
  Future<void> _persistProgress({bool markWatched = true}) {
    final player = _player;
    final index = _activeIndex;
    if (player == null || index == null || !_hasDisplayed) {
      return Future<void>.value();
    }
    if (markWatched) unawaited(_markWatched(index));
    // Capture identity and progress before any await. All writes (including a
    // new episode's history entry) share this queue to preserve their order.
    final history = _historyEntry(index, player);
    final seconds =
        _watchTime.elapsedMicroseconds / Duration.microsecondsPerSecond;
    _watchTime.reset();
    return _history.save(history, watchedSeconds: seconds);
  }

  Future<void> _selectEpisode(int index, {int? expectedGeneration}) {
    if (!mounted ||
        _switchingSeries ||
        index < 0 ||
        index >= widget.eps.length ||
        index == _index ||
        (expectedGeneration != null && !_current(expectedGeneration))) {
      return Future<void>.value();
    }
    setState(() {
      _index = index;
      // 切集：官方清时间线整池重灌（container/l.java:1496-1528）。
      _danmaku.reset();
      // 热评按集取：先撤掉上一集的，免得新集画面上挂着旧热评。
      _hotComments = const [];
    });
    _loadDanmaku();
    unawaited(_loadHotComments());
    // _loadVideo invalidates prior work synchronously; no network or history
    // operation may delay recording the user's newest target.
    return _loadVideo();
  }

  @override
  Widget build(BuildContext context) {
    // 设置页切「播放页布局」后要立刻换形态：偏好走全局 notifier，回到播放页
    // 时 chrome 与分屏面板一起重建，不依赖路由回弹时的偶然 build。
    return ValueListenableBuilder<PlayerLayoutMode>(
      valueListenable: PlayerLayoutPreferences.mode,
      builder: (context, layoutMode, _) => _chrome(layoutMode),
    );
  }

  Widget _chrome(PlayerLayoutMode layoutMode) {
    // 官方播放页开关来自 config.json（`PlayerBottomStyleConfig` 等），
    // 每次 build 重读，配置变化无需重启页面。
    final style = PlayerStyleConfig.instance;
    return VideoPlayerChrome(
      layoutMode: layoutMode,
      splitPanel: _buildSplitPanel(),
      player: _player,
      title: widget.title,
      episodes: widget.eps,
      currentIndex: _index,
      playingIndex: _activeIndex,
      duration: _duration,
      playing: _playing,
      shortSeries: widget.shortSeries,
      openFullScreen: widget.openFullScreen,
      watchedEpisodes: watchedIndexes(_watchedIds, widget.eps),
      interactionBlocked: _externalPanelOpen || _switchingSeries,
      aiGenerated: widget.aiGenerated,
      showSeekHint: _seekHintVisible,
      onSeekHintConsumed: _consumeSeekHint,
      seriesStatus: _seriesStatus,
      originalBook: _originalBook,
      onOpenOriginalBook: _openOriginalBook,
      // 选集面板的关联原著条：官方由
      // `series_relate_book_config_v659.relate_book_in_episodes_dialog`
      // 控制且**默认 false**，本地照官方默认（配置里可打开）。
      relateBook: _episodeRelateBook,
      onOpenRelateBook: _episodeRelateBook == null ? null : _openOriginalBook,
      coverUrl: ApiClient.instance.absoluteUrl(widget.cover),
      enabled:
          _player != null &&
          _activeIndex != null &&
          !_initVideo &&
          _error == null,
      onPagingChanged: _onPagingChanged,
      onSelectEpisode: _selectEpisode,
      onError: (error) => _fail(error, _loadGeneration),
      commentCount: _commentCount,
      onComments: widget.shortSeries ? _openComments : null,
      hotComments: _hotComments,
      onHotCommentTap: widget.shortSeries ? _openHotComment : null,
      seriesTitle: _seriesTitle,
      synopsis: _seriesDetail?.intro ?? '',
      // 官方播放页标题行「剧名 >」（ql3/v0 `a1()`）与选集面板头部箭头
      // 都进剧集详情页（`series_detail`）。
      onOpenSeriesDetail: widget.shortSeries ? _openSeriesDetail : null,
      onOpenRelatedSeries:
          widget.shortSeries && (_seriesDetail?.hasRelatedSeries ?? false)
          ? () => unawaited(_openRelatedSeries())
          : null,
      seriesCover: _seriesCover,
      episodeLabel: _episodeLabel,
      fillScreen: _fillScreen,
      onFillScreenChanged: widget.shortSeries ? _setFillScreen : null,
      defaultMute: _defaultMute,
      onDefaultMuteChanged: widget.shortSeries ? _setDefaultMute : null,
      danmaku: _danmaku.entries,
      danmakuEnabled: _danmakuEnabled,
      onToggleDanmaku: widget.shortSeries ? _toggleDanmaku : null,
      danmakuSettings: _danmakuSettings,
      onDanmakuSettingsChanged: widget.shortSeries
          ? (settings) => setState(() => _danmakuSettings = settings)
          : null,
      // 听视频（官方 `jm3.d0.y()`）：暂停视频页播放，打开听书页；关闭时
      // 回传进度写回视频页续看。
      onOpenListenMode: widget.shortSeries && widget.eps.isNotEmpty
          ? () => unawaited(_openListenMode())
          : null,
      // 离线缓存（官方 `jm3.u`）：面板行 → 选集下载弹窗（弹窗头部可进
      // 管理页）。feed 面板未接（保持占位）。
      onOpenOfflineCache: widget.shortSeries && widget.eps.isNotEmpty
          ? () => unawaited(_openDownloadSheet())
          : null,
      // 官方 `oi3/k.P()` 门：上游只有单流时不显示清晰度行。
      qualityVariants: _currentSource?.variants ?? const [],
      currentQualityUrl: _currentSource?.url,
      onQualitySelected: widget.shortSeries
          ? (variant) {
              // 官方 `bgw`：切换的 Toast 立即出，不等换流完成。
              PlayerToast.show(context, '清晰度已成功切换至${variant.name}');
              unawaited(_switchVariant(variant));
            }
          : null,
      onSeeked: widget.shortSeries ? _onDanmakuSeek : null,
      newPlayerBottomStyle: style.useNewPlayerBottomStyle,
      hasBanner: style.hasBanner,
      padNewBottomStyle: style.padNewBottomStyle,
      reverseClearScreen: style.reverseClearScreen,
      landscapeLockEnabled: style.landscapeLockEnabled,
      child: _videoArea(),
    );
  }

  /// 分屏下半区（竖屏）/ 右侧栏（横屏）。非短剧返回 null，chrome 自动
  /// 退回沉浸式整屏；桌面走 [DesktopVideoChrome]，不会走到这里。
  Widget? _buildSplitPanel() {
    if (!widget.shortSeries) return null;
    final relatedSeries = (_seriesDetail?.hasRelatedSeries ?? false)
        ? () => unawaited(_openRelatedSeries())
        : null;
    final hasEpisodes = widget.eps.isNotEmpty;
    return PlayerSplitPanel(
      seriesId: widget.bookId,
      title: _seriesTitle.isNotEmpty ? _seriesTitle : widget.title,
      cover: ApiClient.instance.absoluteUrl(_seriesCover),
      episodeLabel: _episodeLabel,
      status: _seriesStatus,
      synopsis: _seriesDetail?.intro ?? '',
      episodes: widget.eps,
      currentIndex: _index,
      playingIndex: _activeIndex,
      playing: _playing,
      watched: watchedIndexes(_watchedIds, widget.eps),
      commentCount: _commentCount,
      onSelectEpisode: (index) => unawaited(_selectEpisode(index)),
      onOpenSeriesDetail: widget.bookId.isEmpty ? null : _openSeriesDetail,
      onOpenRelatedSeries: relatedSeries,
      relateBook: _episodeRelateBook,
      onOpenRelateBook: _episodeRelateBook == null ? null : _openOriginalBook,
      onOpenListenMode: hasEpisodes ? () => unawaited(_openListenMode()) : null,
      onOpenDownload: hasEpisodes
          ? () => unawaited(_openDownloadSheet())
          : null,
      // 分屏里发评论/加载分页后，页面的评论入口计数（整屏右栏与热评弹窗）
      // 也要跟上，不能只更新下半区 Tab。
      onCommentTotalChanged: (total) {
        if (!mounted || total <= 0 || total == _commentCount) return;
        setState(() => _commentCount = total);
      },
    );
  }

  /// 选集下载弹窗（官方 `jm3.u` 的面板行语义）：先把剧集目录交给下载
  /// 引擎，弹窗内选集并入队；管理页从弹窗头部进入。
  Future<void> _openDownloadSheet() async {
    await DramaDownloadSheet.show(
      context,
      seriesId: widget.bookId,
      title: _seriesTitle,
      cover: widget.cover,
      episodes: widget.eps,
      currentIndex: _index,
      // 画质只列这部剧真实给到的档位，避免"选了 720 实际只有 360"。
      qualities: _currentSource?.variants ?? const [],
    );
  }

  /// 已缓存的集 → 本地取流结果（`file://` + keyHex，回放时原生层从磁盘
  /// 读加密字节解密）；记录在但文件被清掉则返回 null 回退在线。
  ///
  /// store 未就绪（Hive 未初始化的测试环境）直接跳过，不触碰 openBox。
  Future<EpisodeSource?> _offlineSource(Chapter episode) async {
    final store = _downloadStore;
    if (!store.isReady) return null;
    try {
      final cached = await store.episode(episode.itemId);
      if (cached == null) return null;
      if (!File(cached.filePath).existsSync()) return null;
      return cached.toSource();
    } catch (_) {
      return null;
    }
  }

  /// 听书页与播放页共用的取流入口：离线优先，在线走取流缓存。
  Future<EpisodeSource?> _resolveSource(Chapter episode) async {
    final offline = await _offlineSource(episode);
    if (offline != null) return offline;
    return _sources.request(episode).future;
  }

  /// 听视频（官方 `jm3.d0.y()` 的听书模式页语义）：视频页暂停，推入独立
  /// 听书页；关闭时把「听到哪一集 + 进度」写回视频页续看（官方的
  /// `sync_progress_strategy_listen_mode` 进度同步的本地等价）。
  Future<void> _openListenMode() async {
    final player = _player;
    final wasPlaying = _playing;
    if (player != null) await player.pause();
    // 听视频接手播放：先收起悬浮窗，避免两个播放面同时占着播放器。
    if (_floating) await _stopFloating();
    if (!mounted) return;
    final result = await Navigator.of(context).push<(int, Duration)>(
      MaterialPageRoute<(int, Duration)>(
        builder: (_) => ListenModePage(
          seriesTitle: _seriesTitle,
          coverUrl: widget.cover,
          episodes: widget.eps,
          initialIndex: _index,
          resolveSource: _resolveSource,
        ),
      ),
    );
    if (!mounted || player == null) return;
    final (listenIndex, position) = result ?? (_index, Duration.zero);
    final targetIndex = listenIndex >= 0 && listenIndex < widget.eps.length
        ? listenIndex
        : _index;
    if (targetIndex != _index) {
      // 听书页自动连播跨了集：切到那一集，进度由 _loadVideo 消费
      // [_listenResume] 恢复；起播交给切集链路自己的自动播放。
      if (position > Duration.zero) _listenResume = (targetIndex, position);
      await _selectEpisode(targetIndex);
      return;
    }
    if (position > Duration.zero) {
      await player.seek(position);
    }
    if (wasPlaying) await player.play();
  }

  Widget _videoArea() {
    final generation = _loadGeneration;
    void retry() {
      if (_current(generation)) unawaited(_loadVideo(refresh: true));
    }

    final player = _player;
    final texture = player?.textureId;
    final waiting =
        _initVideo ||
        texture == null ||
        player == null ||
        !player.firstFrameRendered ||
        player.videoWidth <= 0 ||
        player.videoHeight <= 0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (texture != null)
          RotatedBox(
            quarterTurns: _player!.videoRotationCorrection ~/ 90,
            child: isWindowsDesktop
                ? DesktopPlatform.instance.videoSurface(
                    texture,
                    key: const ValueKey('player-texture'),
                  )
                : Texture(
                    key: const ValueKey('player-texture'),
                    textureId: texture,
                  ),
          ),
        if (waiting || _error != null)
          PlayerCover(
            key: const ValueKey('player-cover'),
            url: ApiClient.instance.absoluteUrl(widget.cover),
          ),
        if (_error != null)
          PlayerErrorFeedback(
            key: const ValueKey('player-error'),
            issue: _error!,
            onRetry: widget.eps.isEmpty ? null : retry,
          ),
        if (_error == null && (waiting || _player!.buffering))
          PlayerLoadingFeedback(
            key: ValueKey('player-loading-$generation'),
            label: waiting ? '正在加载第 ${_index + 1} 集' : null,
            onRetry: retry,
          ),
      ],
    );
  }
}
