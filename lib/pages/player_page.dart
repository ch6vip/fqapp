import 'dart:async';

import 'package:flutter/material.dart';

import '../models/audio_extra.dart' show RelatedWork;
import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart';
import 'detail_page.dart' show DetailPage;
import '../services/api_client.dart';
import '../services/episode_source_cache.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/playback_issue.dart';
import '../services/player_history.dart';
import '../services/player_load_diagnostics.dart';
import '../services/player_preferences.dart';
import '../services/player_style_config.dart';
import '../services/swipe_guide_store.dart';
import '../models/book_detail.dart' show formatCounter;
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/playlet_danmaku_layer.dart';
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

  /// 官方短剧播放页形态（`apf.xml`）：竖屏无运输条、单击=播放/暂停。
  /// 详情页的电影/电视剧走通用形态（默认 false）。
  final bool shortSeries;

  /// 播放页沉浸式信息层（官方截图形态）：右栏追剧计数（`followed_cnt`，
  /// 0 = 显示「追剧」）、AI 声明行、右栏/追剧的本地回调。
  final int followerCount;
  final bool aiGenerated;
  final VoidCallback? onFollow;
  final VoidCallback? onLike;

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
    this.shortSeries = false,
    this.followerCount = 0,
    this.aiGenerated = false,
    this.onFollow,
    this.onLike,
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

  /// 已看集（选集面板灰字）：续播点之前的集（本地历史的等价推断）+
  /// 本次会话播过的集（切集时把离开的集记为已看）。
  final Set<int> _watched = {};

  /// 底部 band 装饰（官方截图第二十二轮）：完结状态与原著书卡，
  /// best-effort 拉取，失败保持缺省。
  String? _seriesStatus;
  RelatedWork? _originalBook;

  /// 官方入口计数（`SeriesCommentView` 读 `du4.a.e()` 并回写 videoData）；
  /// 0 表示「还没有人评论」，入口按官方文案显示「评论」。
  int _commentCount = 0;
  int _danmakuGeneration = 0;

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
    _watched.addAll([for (var i = 0; i < _index; i++) i]);
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
    unawaited(_loadDanmaku());
  }

  /// 热评（官方 `SeriesHotCommentView`）：与评论计数同源，来自
  /// `comment/list` 的 `comment_source=4/count=20` 那次请求，
  /// 由 [hotOf] 在本地筛出（**不是接口字段**）。
  List<PlayletComment> _hotComments = const [];

  /// 弹幕（官方 `DanmakuRequestHelper`）：按 vid 取数，时间单位毫秒。
  /// 时间轴对象负责切集清空与去重（官方 container/l.java 的规则）。
  final DanmakuTimeline _danmaku = DanmakuTimeline();
  bool _danmakuEnabled = DanmakuPreference.defaultEnabled;

  /// 底部 band 装饰，一个 `seriesDetail` 请求全出：完结状态
  /// （`series_status`：官方 `SeriesStatus` 1=已完结/0=更新中/3=今日更新/
  /// 4=断更）、原著书卡（`video_relate_book`）与评论计数
  /// （`comment_cnt`，官方入口「评论/抢首评」的判据）。
  /// 自吞异常——band 是装饰，接口再差也不能影响播放。
  Future<void> _loadBandExtras() async {
    final series = await (widget.seriesLoader?.call(widget.bookId) ??
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
    setState(() {
      _seriesStatus = status;
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
  void _openComments() {
    if (!widget.shortSeries) return;
    PlayletCommentPanel.show(
      context,
      seriesId: widget.bookId,
      total: _commentCount,
      submitComment: _submitComment,
      diggComment: _diggComment,
      replyComment: _replyComment,
    );
  }

  /// 发表剧评（官方 `comment/add`）。数据走真实接口，成功后由面板重拉。
  Future<void> _submitComment(String text) =>
      ApiClient.instance.addPlayletComment(widget.bookId, text);

  /// 回复剧评（官方 `reply/add`）。
  Future<void> _replyComment(PlayletComment comment, String text) =>
      ApiClient.instance.replyPlayletComment(
        comment.id,
        seriesId: widget.bookId,
        text: text,
      );

  /// 点赞/取消点赞（官方独立 digg 接口）。
  Future<void> _diggComment(PlayletComment comment, bool liked) =>
      ApiClient.instance.diggPlayletComment(
        comment.id,
        liked: liked,
        bookId: widget.bookId,
      );


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
  /// `hot_comment_id`）。本地等价是打开评论面板并滚到该条。
  void _openHotComment(PlayletComment comment) {
    final target = comment.dataType == UgcRelativeType.reply
        ? comment.parentCommentId
        : comment.id;
    PlayletCommentPanel.show(
      context,
      seriesId: widget.bookId,
      total: _commentCount,
      focusCommentId: target,
      submitComment: _submitComment,
      diggComment: _diggComment,
      replyComment: _replyComment,
    );
  }

  /// 官方开关落盘（`video_danmaku_switch_sp`）。
  Future<void> _loadDanmakuPreference() async {
    final enabled = await DanmakuPreference.load();
    if (!mounted) return;
    setState(() => _danmakuEnabled = enabled);
  }

  /// 官方取数（`DanmakuRequestHelper.java:314-329`）：`:group_id` 是当前
  /// vid，剧集 id 进 `business_param.book_id`，时间毫秒。best-effort：
  /// 失败不显示弹幕，不影响播放。
  Future<void> _loadDanmaku() async {
    if (!widget.shortSeries || widget.eps.isEmpty) return;
    final vid = widget.eps[_index].itemId;
    if (vid.isEmpty) return;
    final request = ++_danmakuGeneration;
    try {
      final page = await ApiClient.instance.playletDanmaku(
        vid,
        seriesId: widget.bookId,
        startOffsetMs: _player?.position.inMilliseconds ?? 0,
        duration: _duration,
      );
      if (!mounted || request != _danmakuGeneration) return;
      setState(() => _danmaku.load(danmakuFromPage(page), replace: true));
    } catch (_) {
      // 弹幕是装饰层，取数失败只是不显示。
    }
  }

  /// 官方开关切换：落盘 + Toast 文案（`i95/i.java:339-346`）。
  Future<void> _toggleDanmaku() async {
    final enabled = !_danmakuEnabled;
    setState(() => _danmakuEnabled = enabled);
    await DanmakuPreference.save(enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled ? danmakuEnabledToast : danmakuDisabledToast),
      ),
    );
  }

  /// 发弹幕（官方 `comment/add`，`commit_source=1500`）：成功后按当前进度
  /// 就地插入，等价于官方的整池重灌。
  Future<void> _sendDanmaku(String text) async {
    if (widget.eps.isEmpty) return;
    final vid = widget.eps[_index].itemId;
    if (vid.isEmpty) return;
    final offset = _player?.position.inMilliseconds ?? 0;
    await ApiClient.instance.addPlayletDanmaku(
      vid,
      seriesId: widget.bookId,
      text: text,
      offsetMs: offset,
    );
    if (!mounted) return;
    setState(() {
      _danmaku.entries.add(
        PlayletComment(
          id: 'local-${DateTime.now().microsecondsSinceEpoch}',
          text: text,
          dataType: UgcRelativeType.seriesVideo,
          offsetMs: offset,
        ),
      );
    });
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
        unawaited(_persistProgress());
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
        await player.seek(Duration(milliseconds: requestedMs.round()));
        if (!_current(generation, player)) return;
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

  Future<void> _persistProgress() {
    final player = _player;
    final index = _activeIndex;
    if (player == null || index == null || !_hasDisplayed) {
      return Future<void>.value();
    }
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
      _watched.add(_index);
      _index = index;
      // 切集：官方清时间线整池重灌（container/l.java:1496-1528）。
      _danmaku.reset();
    });
    unawaited(_loadDanmaku());
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
    watchedEpisodes: _watched,
    followerLabel: widget.followerCount > 0
        ? formatCounter('${widget.followerCount}')
        : null,
    onFollow: widget.onFollow,
    onLike: widget.onLike,
    // 官方竖屏双击点赞（`jq3/x.q.onDoubleTap` → `holder.z7`）：动画由播放器
    // 自己播，点赞动作走与右栏「点赞」同一条宿主回调，不另开一条链路。
    onLikeTap: widget.onLike,
    aiGenerated: widget.aiGenerated,
    showSeekHint: _seekHintVisible,
    onSeekHintConsumed: _consumeSeekHint,
    seriesStatus: _seriesStatus,
    originalBook: _originalBook,
    onOpenOriginalBook: _openOriginalBook,
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
    danmaku: _danmaku.entries,
    danmakuEnabled: _danmakuEnabled,
    onToggleDanmaku: widget.shortSeries ? _toggleDanmaku : null,
    onSendDanmaku: widget.shortSeries ? _sendDanmaku : null,
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
