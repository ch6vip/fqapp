import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/media_description.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/player_history.dart';
import '../services/player_preferences.dart';
import '../widgets/video_player_chrome.dart';

class PlayerPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> eps;
  final int startIndex;
  final String? description;
  final Future<String> Function()? descriptionLoader;
  final Future<Map<String, dynamic>> Function(Chapter)? contentLoader;
  final NativePlayer Function()? playerFactory;
  final ReaderStore? historyStore;

  const PlayerPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.eps,
    required this.startIndex,
    this.description,
    this.descriptionLoader,
    this.contentLoader,
    this.playerFactory,
    this.historyStore,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late int _index;
  int? _activeIndex;
  NativePlayer? _player;
  Timer? _progressTimer;
  bool _initVideo = false;
  bool _paging = false;
  Completer<void>? _pagingSettled;
  int? _pendingCompletion;
  NativePlayer? _pendingAutoplay;
  String? _error;
  int _loadGeneration = 0;
  final Stopwatch _watchTime = Stopwatch();
  final List<StreamSubscription<dynamic>> _subs = [];
  Future<void> _releases = Future<void>.value();

  late String _description;
  late bool _descriptionLoaded;
  bool _descriptionLoading = false;
  String? _descriptionError;
  int _descriptionGeneration = 0;

  PlayerHistory get _history =>
      PlayerHistory(widget.historyStore ?? LibraryStore.instance);
  Duration _position = Duration.zero;
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
    _description = widget.description ?? '';
    _descriptionLoaded = widget.description != null;
    if (widget.eps.isEmpty) {
      _error = '暂无可播放剧集';
    } else {
      unawaited(_loadVideo());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(NativePlayer.setKeepScreenOn(false).catchError((Object _) {}));
    _progressTimer?.cancel();
    ++_loadGeneration;
    ++_descriptionGeneration;
    _pagingSettled?.complete();
    _pagingSettled = null;
    _watchTime.stop();
    unawaited(_persistProgress());
    unawaited(_teardownPlayer());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncWatchClock();
    if (state == AppLifecycleState.resumed) {
      _resumePendingAutoplay();
    } else {
      unawaited(_persistProgress());
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
    await player.play();
    if (_current(generation, player) && !_appActive) {
      // The lifecycle can change while the platform acknowledges play.
      _pendingAutoplay = player;
      await player.pause();
    }
  }

  Future<void> _teardownPlayer() {
    final old = _player;
    _player = null;
    _activeIndex = null;
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

  Future<void> _loadVideo() async {
    if (widget.eps.isEmpty) return;
    final generation = ++_loadGeneration;
    final index = _index;
    final episode = widget.eps[index];
    _progressTimer?.cancel();
    _watchTime.stop();
    unawaited(_persistProgress());
    final release = _teardownPlayer();
    _watchTime.reset();
    setState(() {
      _initVideo = true;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _playing = false;
    });

    NativePlayer? candidate;
    try {
      final response =
          await (widget.contentLoader?.call(episode) ??
              ApiClient.instance.content(
                episode.itemId,
                tab: '短剧',
                mode: 'stream',
              ));
      if (!_current(generation)) return;
      final data = response['data'] is Map
          ? Map<String, dynamic>.from(response['data'] as Map)
          : response;
      var rawUrl = (data['video_url'] ?? data['main_url'] ?? '')
          .toString()
          .trim();
      final keyHex = (data['key_hex'] ?? '').toString().trim();
      if (rawUrl.isEmpty) rawUrl = _extractVideoUrl(response);
      final url = rawUrl.isEmpty ? '' : ApiClient.instance.absoluteUrl(rawUrl);
      if (url.isEmpty) throw ApiException('获取播放地址失败');

      await release;
      if (!_current(generation)) return;
      Map<String, dynamic>? saved;
      try {
        saved = await _history.load(widget.bookId);
      } catch (_) {
        // Local storage is optional for starting a video.
      }
      if (!await _waitForPaging(generation)) return;
      final player = candidate = widget.playerFactory?.call() ?? NativePlayer();
      _player = player;
      await player.create(url, keyHex);
      if (!_current(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      _subscribe(player, generation);
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

      if (!await _waitForPaging(generation, player)) return;
      setState(() {
        _activeIndex = index;
        _position = player.position;
        _duration = player.duration;
        _playing = player.playing;
        _initVideo = false;
      });
      final history = _historyEntry(index, player);
      unawaited(_history.save(history));
      _pendingAutoplay = player;
      await _tryAutoplay(generation);
      if (!_current(generation, player)) return;
      _syncWatchClock();
      _progressTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_persistProgress()),
      );
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
    ++_loadGeneration;
    _progressTimer?.cancel();
    _watchTime.stop();
    unawaited(_persistProgress());
    unawaited(_teardownPlayer());
    setState(() {
      _error = '$error';
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
      }),
      player.videoSizeStream.listen((_) {
        if (_current(generation, player)) setState(() {});
      }),
      player.firstFrameStream.listen((_) {
        if (_current(generation, player)) setState(() {});
      }),
      player.positionStream.listen((position) {
        if (_current(generation, player)) setState(() => _position = position);
      }),
      player.durationStream.listen((duration) {
        if (_current(generation, player)) setState(() => _duration = duration);
      }),
      player.playingStream.listen((playing) {
        if (!_current(generation, player)) return;
        setState(() => _playing = playing);
        _syncWatchClock();
      }),
      player.completedStream.listen((completed) {
        if (!_current(generation, player) || _activeIndex != _index) {
          return;
        }
        if (!completed) {
          _pendingCompletion = null;
          return;
        }
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
    if (active && _playing && !(_player?.buffering ?? true) && _error == null) {
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
      'kind': 'video',
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
    if (player == null || index == null) return Future<void>.value();
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
    setState(() => _index = index);
    // _loadVideo invalidates prior work synchronously; no network or history
    // operation may delay recording the user's newest target.
    return _loadVideo();
  }

  Future<void> _loadDescription({bool retry = false}) async {
    if (_descriptionLoading || (_descriptionLoaded && !retry)) return;
    final generation = ++_descriptionGeneration;
    setState(() {
      _descriptionLoading = true;
      _descriptionError = null;
    });
    try {
      final description =
          await (widget.descriptionLoader?.call() ??
              ApiClient.instance
                  .detail(widget.bookId, tab: '短剧')
                  .then(extractMediaDescription));
      if (!mounted || generation != _descriptionGeneration) return;
      setState(() {
        _description = description;
        _descriptionLoaded = true;
      });
    } catch (error) {
      if (!mounted || generation != _descriptionGeneration) return;
      setState(() {
        _descriptionError = '$error';
        _descriptionLoaded = true;
      });
    } finally {
      if (mounted && generation == _descriptionGeneration) {
        setState(() => _descriptionLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => VideoPlayerChrome(
    player: _player,
    title: widget.title,
    episodes: widget.eps,
    currentIndex: _index,
    playingIndex: _activeIndex,
    position: _position,
    duration: _duration,
    playing: _playing,
    enabled:
        _player != null &&
        _activeIndex != null &&
        !_initVideo &&
        _error == null,
    description: _description,
    descriptionLoading: _descriptionLoading,
    descriptionError: _descriptionError,
    onRequestDescription: () => unawaited(_loadDescription()),
    onRetryDescription: () => unawaited(_loadDescription(retry: true)),
    onPagingChanged: _onPagingChanged,
    onSelectEpisode: _selectEpisode,
    onError: (error) => _fail(error, _loadGeneration),
    child: _videoArea(),
  );

  Widget _videoArea() {
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 32),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              if (widget.eps.isNotEmpty) ...[
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _loadVideo, child: const Text('重试')),
              ],
            ],
          ),
        ),
      );
    }
    final texture = _player?.textureId;
    if (_initVideo || texture == null) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                '正在加载第 ${_index + 1} 集',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Texture(textureId: texture),
        if (_player!.buffering)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      ],
    );
  }
}

/// Returns only a normal playback-position delta. Restore/seek/app-resume
/// jumps are deliberately rejected so historical progress is never counted
/// as newly watched time.
double countablePlaybackDelta({
  required bool playing,
  required double previousSeconds,
  required double currentSeconds,
}) {
  if (!playing) return 0;
  final delta = currentSeconds - previousSeconds;
  return delta > 0.5 && delta <= 10 ? delta : 0;
}

// Deep video URL extraction fallback for old backends that do not expose
// the stream route (key_hex empty → plain playback).
String _extractVideoUrl(Map<String, dynamic> payload) {
  String visit(dynamic value, [int depth = 0]) {
    if (depth > 7 || value == null) return '';
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.startsWith('http://') ||
          trimmed.startsWith('https://') ||
          trimmed.startsWith('/src/')) {
        return trimmed;
      }
      if (trimmed.startsWith('{')) {
        try {
          return visit(jsonDecode(trimmed), depth + 1);
        } catch (_) {
          return '';
        }
      }
      return '';
    }
    if (value is List) {
      for (final item in value.reversed) {
        final found = visit(item, depth + 1);
        if (found.isNotEmpty) return found;
      }
      return '';
    }
    if (value is Map) {
      for (final key in ['video_url', 'play_url', 'main_url', 'url']) {
        final found = visit(value[key], depth + 1);
        if (found.isNotEmpty) return found;
      }
      for (final key in [
        'data',
        'video_info',
        'video_list',
        'play_info_list',
        'video_model',
      ]) {
        final found = visit(value[key], depth + 1);
        if (found.isNotEmpty) return found;
      }
      for (final nested in value.values) {
        final found = visit(nested, depth + 1);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  return visit(payload);
}
