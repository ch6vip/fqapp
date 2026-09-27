import 'dart:async';

import 'package:flutter/material.dart';

import '../models/audio_extra.dart' show RelatedWork;
import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart';
import 'detail_page.dart' show DetailPage;
import '../services/api_client.dart';
import '../services/backend_transport.dart' show BackendRequest;
import '../services/player_panel_preferences.dart';
import '../services/watched_episodes.dart';
import '../services/episode_source_cache.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/playback_issue.dart';
import '../services/player_history.dart';
import '../services/player_load_diagnostics.dart';
import '../services/player_preferences.dart';
import '../services/player_style_config.dart';
import '../services/swipe_guide_store.dart';
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/playlet_danmaku_layer.dart';
import '../widgets/player/playlet_danmaku_loader.dart';
import '../widgets/player/playlet_danmaku_settings.dart';
import '../widgets/player/story_player_panel.dart';
import '../widgets/player/player_cover.dart';
import '../widgets/player/player_feedback.dart';
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
  final PlayerLoadDiagnostics? loadDiagnostics;

  /// 底部 band 装饰数据的可注入 loader（默认走 ApiClient，best-effort：
  /// 失败就缺省，不打扰播放）。测试注入用。
  final Future<SeriesDetail> Function(String bookId)? seriesLoader;

  /// 弹幕取数的可注入实现（默认走 ApiClient.playletDanmaku）。测试注入用，
  /// 与 [seriesLoader] 同一套缝。
  final Future<PlayletCommentPage> Function(DanmakuFetchRequest request)?
  danmakuFetcher;

  /// 官方短剧播放页形态（`apf.xml`）：竖屏无运输条、单击=播放/暂停。
  /// 详情页的电影/电视剧走通用形态（默认 false）。
  final bool shortSeries;

  /// 播放页信息层的 AI 声明行。
  final bool aiGenerated;

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
    this.danmakuFetcher,
    this.shortSeries = false,
    this.aiGenerated = false,
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
  bool _initVideo = false;
  bool _paging = false;
  Completer<void>? _pagingSettled;
  int? _pendingCompletion;
  NativePlayer? _pendingAutoplay;
  PlaybackIssue? _error;
  int _loadGeneration = 0;
  final Stopwatch _watchTime = Stopwatch();
  final List<StreamSubscription<dynamic>> _subs = [];
  Future<void> _releases = Future<void>.value();
  late final EpisodeSourceCache _sources;
  late final PlayerLoadDiagnostics _diagnostics;
  PlayerLoadTrace? _loadTrace;
  Timer? _prefetchTimer;
  int? _prefetchQueuedGeneration;
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
  String? _seriesStatus;
  RelatedWork? _originalBook;

  /// 官方入口计数（`SeriesCommentView` 读 `du4.a.e()` 并回写 videoData）；
  /// 0 表示「还没有人评论」，入口按官方文案显示「评论」。
  int _commentCount = 0;
  bool _externalPanelOpen = false;

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
    unawaited(NativePlayer.setKeepScreenOn(true).catchError((Object _) {}));
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
    final series =
        await (widget.seriesLoader?.call(widget.bookId) ??
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
    if (_externalPanelOpen || !mounted) return;
    setState(() => _externalPanelOpen = true);
    try {
      await open();
    } finally {
      if (mounted) setState(() => _externalPanelOpen = false);
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
  Future<void> _loadHotComments() async {
    if (!widget.shortSeries || widget.bookId.isEmpty) return;
    try {
      final page = await ApiClient.instance.playletHotComments(
        widget.bookId,
        vid: widget.eps.isEmpty ? '' : widget.eps.first.itemId,
      );
      if (!mounted) return;
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled ? danmakuEnabledToast : danmakuDisabledToast),
      ),
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
  void _openOriginalBook() {
    final book = _originalBook;
    if (book == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          item: MediaItem(
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
    unawaited(NativePlayer.setKeepScreenOn(false).catchError((Object _) {}));
    _progressTimer?.cancel();
    _prefetchTimer?.cancel();
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _loadTrace?.setAppActive(state == AppLifecycleState.resumed);
    _syncWatchClock();
    if (state == AppLifecycleState.resumed) {
      _resumePendingAutoplay();
    } else {
      unawaited(_persistProgress());
    }
    _updatePrefetch();
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
    return state == null || state == AppLifecycleState.resumed;
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
    if (player == null ||
        !_current(generation, player) ||
        !_appActive ||
        _paging) {
      return;
    }
    _pendingAutoplay = null;
    _loadTrace?.playRequested();
    await player.play();
    if (_current(generation, player) && !_appActive) {
      // The lifecycle can change while the platform acknowledges play.
      _pendingAutoplay = player;
      await player.pause();
    }
  }

  bool _canPrefetch(int generation, NativePlayer player) =>
      _current(generation, player) &&
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
  }

  Future<void> _teardownPlayer() {
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

  Future<void> _loadVideo({bool refresh = false}) async {
    if (widget.eps.isEmpty) return;
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
      final request = _sources.request(episode, refresh: refresh);
      trace.source = request.origin.name;
      final source = await request.future;
      if (!_current(generation)) return;
      final sourceUri = Uri.tryParse(source.url);
      if (sourceUri == null ||
          (sourceUri.scheme != 'http' && sourceUri.scheme != 'https') ||
          sourceUri.host.isEmpty) {
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
      final requestedMs = savedPosition * 1000;
      if (savedIndex == index &&
          requestedMs.isFinite &&
          requestedMs > 0 &&
          requestedMs < 0x7fffffffffffffff &&
          (durationSeconds <= 0 || savedPosition < durationSeconds)) {
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
      _pendingAutoplay = player;
      await _tryAutoplay(generation);
      if (!_current(generation, player)) return;
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
    _loadTrace?.finish('error');
    _sources.invalidate(widget.eps[_index].itemId);
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    ++_loadGeneration;
    _progressTimer?.cancel();
    _watchTime.stop();
    unawaited(_persistProgress());
    unawaited(_teardownPlayer());
    setState(() {
      _error = PlaybackIssue.fromError(error);
      _initVideo = false;
      _playing = false;
    });
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
    final active = state == null || state == AppLifecycleState.resumed;
    if (active &&
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
    });
    _loadDanmaku();
    // _loadVideo invalidates prior work synchronously; no network or history
    // operation may delay recording the user's newest target.
    return _loadVideo();
  }

  @override
  Widget build(BuildContext context) {
    // 官方播放页开关来自 config.json（`PlayerBottomStyleConfig` 等），
    // 每次 build 重读，配置变化无需重启页面。
    final style = PlayerStyleConfig.instance;
    return VideoPlayerChrome(
      player: _player,
      title: widget.title,
      episodes: widget.eps,
      currentIndex: _index,
      playingIndex: _activeIndex,
      duration: _duration,
      playing: _playing,
      shortSeries: widget.shortSeries,
      watchedEpisodes: watchedIndexes(_watchedIds, widget.eps),
      interactionBlocked: _externalPanelOpen,
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
      onSeeked: widget.shortSeries ? _onDanmakuSeek : null,
      newPlayerBottomStyle: style.useNewPlayerBottomStyle,
      hasBanner: style.hasBanner,
      padNewBottomStyle: style.padNewBottomStyle,
      reverseClearScreen: style.reverseClearScreen,
      landscapeLockEnabled: style.landscapeLockEnabled,
      child: _videoArea(),
    );
  }

  Widget _videoArea() {
    final generation = _loadGeneration;
    void retry() {
      if (_current(generation)) unawaited(_loadVideo(refresh: true));
    }

    final texture = _player?.textureId;
    final waiting =
        _initVideo || texture == null || !_player!.firstFrameRendered;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (texture != null)
          RotatedBox(
            quarterTurns: _player!.videoRotationCorrection ~/ 90,
            child: Texture(
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
