import 'dart:async';

import 'package:flutter/material.dart';

import '../models/audio_extra.dart' show RelatedWork;
import '../models/media_item.dart';
import 'detail_page.dart' show DetailPage;
import '../services/api_client.dart';
import '../services/episode_source_cache.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/playback_issue.dart';
import '../services/player_history.dart';
import '../services/player_load_diagnostics.dart';
import '../services/player_preferences.dart';
import '../services/swipe_guide_store.dart';
import '../models/book_detail.dart' show BookDetail, formatCounter;
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

  /// 底部 band 装饰数据的可注入 loader（默认走 ApiClient，均为
  /// best-effort：失败就缺省，不打扰播放）。测试注入用。
  final Future<BookDetail> Function(String bookId)? detailLoader;
  final Future<List<RelatedWork>> Function(String bookId)? relatedLoader;

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
    this.detailLoader,
    this.relatedLoader,
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
  }

  /// 完结状态（`book_detail.creation_status`：0=已完结、1=连载中）与原著
  /// 书卡（`/related` 里 kind=book 的关联）。两请求都自吞异常——band 是
  /// 装饰，接口再差也不能影响播放。
  Future<void> _loadBandExtras() async {
    final detail = await (widget.detailLoader?.call(widget.bookId) ??
            ApiClient.instance.bookDetail(widget.bookId))
        .catchError((Object _) => const BookDetail());
    if (mounted) {
      setState(() {
        _seriesStatus = switch (detail.creationStatus) {
          0 => '已完结',
          1 => '连载中',
          _ => null,
        };
      });
    }
    final related = await (widget.relatedLoader?.call(widget.bookId) ??
            ApiClient.instance.relatedWorks(widget.bookId))
        .catchError((Object _) => const <RelatedWork>[]);
    for (final work in related) {
      if (work.kind == 'book' && work.title.isNotEmpty) {
        if (mounted) setState(() => _originalBook = work);
        return;
      }
    }
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
    });
    // _loadVideo invalidates prior work synchronously; no network or history
    // operation may delay recording the user's newest target.
    return _loadVideo();
  }

  @override
  Widget build(BuildContext context) => VideoPlayerChrome(
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
    child: _videoArea(),
  );

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
