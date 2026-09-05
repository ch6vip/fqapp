import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';
import '../widgets/video_player_chrome.dart';

class PlayerPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> eps;
  final int startIndex;
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
    this.contentLoader,
    this.playerFactory,
    this.historyStore,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late int _index;
  NativePlayer? _player;
  NativePlayer? _displayPlayer;
  Timer? _progressTimer;
  bool _initVideo = false;
  bool _advancing = false;
  String? _error;
  int _loadGeneration = 0;
  final Stopwatch _watchTime = Stopwatch();
  bool _changingEpisode = false;
  ReaderStore get _historyStore => widget.historyStore ?? LibraryStore.instance;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    unawaited(NativePlayer.setKeepScreenOn(true).catchError((_) {}));
    _index = widget.eps.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.eps.length - 1);
    if (widget.eps.isEmpty) {
      _error = '暂无可播放剧集';
    } else {
      _loadVideo();
    }
  }

  @override
  void dispose() {
    unawaited(NativePlayer.setKeepScreenOn(false).catchError((_) {}));
    _progressTimer?.cancel();
    ++_loadGeneration;
    _watchTime.stop();
    unawaited(_persistProgress());
    unawaited(_teardownPlayer());
    super.dispose();
  }

  Future<void> _teardownPlayer() async {
    final cancellations = <Future<void>>[];
    for (final s in _subs) {
      cancellations.add(s.cancel());
    }
    _subs.clear();
    final old = _player;
    _player = null;
    await Future.wait(cancellations);
    await old?.dispose();
  }

  Future<void> _loadVideo() async {
    if (widget.eps.isEmpty) return;
    final generation = ++_loadGeneration;
    final episode = widget.eps[_index];
    if (mounted) {
      setState(() {
        _initVideo = true;
        _error = null;
      });
    }

    _progressTimer?.cancel();
    _watchTime
      ..stop()
      ..reset();
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    await _teardownPlayer();
    if (!mounted || generation != _loadGeneration) return;

    try {
      final response =
          await (widget.contentLoader?.call(episode) ??
              ApiClient.instance.content(
                episode.itemId,
                tab: '短剧',
                mode: 'stream',
              ));
      if (!mounted || generation != _loadGeneration) return;
      final data = response['data'] is Map
          ? Map<String, dynamic>.from(response['data'] as Map)
          : response;
      var rawUrl = (data['video_url'] ?? data['main_url'] ?? '')
          .toString()
          .trim();
      final keyHex = (data['key_hex'] ?? '').toString().trim();
      if (rawUrl.isEmpty) {
        // Old backends may not expose the stream route; fall back to the
        // deep video URL extraction used previously.
        rawUrl = _extractVideoUrl(response);
      }
      final url = rawUrl.isEmpty ? '' : ApiClient.instance.absoluteUrl(rawUrl);
      if (url.isEmpty) throw ApiException('获取播放地址失败');
      await _startWith(url, keyHex, generation, episode);
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$e';
        _initVideo = false;
      });
    }
  }

  Future<void> _startWith(
    String url,
    String keyHex,
    int generation,
    Chapter episode,
  ) async {
    final player = widget.playerFactory?.call() ?? NativePlayer();
    try {
      await player.create(url, keyHex);
      if (player.lastError case final Object error) throw error;
      if (!mounted || generation != _loadGeneration) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _displayPlayer = player;
        _position = player.position;
        _duration = player.duration;
        _playing = player.playing;
        _initVideo = false;
      });
      _subscribe(player, generation);
    } catch (e) {
      await player.dispose();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$e';
        _initVideo = false;
      });
      return;
    }

    // Restore saved progress for the same episode.
    final saved = await _historyStore.historyEntry(widget.bookId);
    if (!mounted || generation != _loadGeneration) {
      await player.dispose();
      return;
    }
    final savedEpisode = saved?['episode'] is num
        ? (saved!['episode'] as num).toInt()
        : -1;
    if (savedEpisode == _index && saved?['position'] is num) {
      final savedSeconds = (saved!['position'] as num).toDouble();
      if (savedSeconds > 0) {
        await player.seek(
          Duration(milliseconds: (savedSeconds * 1000).round()),
        );
        if (!mounted || generation != _loadGeneration) return;
        setState(
          () =>
              _position = Duration(milliseconds: (savedSeconds * 1000).round()),
        );
      }
    }
    if (!mounted || generation != _loadGeneration) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      await player.play();
    }
    if (!mounted || generation != _loadGeneration) return;
    _syncWatchClock();
    _progressTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_persistProgress()),
    );
    await _historyStore.addHistory({
      'id': widget.bookId,
      'kind': 'video',
      'title': widget.title,
      'bookId': widget.bookId,
      'seriesId': widget.bookId,
      'episodeId': episode.itemId,
      'episode': _index,
      'progress': savedEpisode == _index && saved?['progress'] is num
          ? (saved!['progress'] as num).toDouble()
          : 0.0,
      'position': savedEpisode == _index && saved?['position'] is num
          ? (saved!['position'] as num).toDouble()
          : 0.0,
      'duration': _duration.inMilliseconds / 1000,
      'cover': widget.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _subscribe(NativePlayer player, int generation) {
    _subs.add(
      player.bufferingStream.listen((_) {
        if (mounted && generation == _loadGeneration) _syncWatchClock();
      }),
    );
    _subs.add(
      player.positionStream.listen((pos) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() => _position = pos);
      }),
    );
    _subs.add(
      player.durationStream.listen((dur) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() => _duration = dur);
      }),
    );
    _subs.add(
      player.playingStream.listen((playing) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() => _playing = playing);
        _syncWatchClock();
      }),
    );
    _subs.add(
      player.completedStream.listen((completed) {
        if (!mounted ||
            generation != _loadGeneration ||
            !completed ||
            _advancing) {
          return;
        }
        _advancing = true;
        unawaited(_next(auto: true).whenComplete(() => _advancing = false));
      }),
    );
    _subs.add(
      player.errorStream.listen((error) {
        if (!mounted || generation != _loadGeneration) return;
        _progressTimer?.cancel();
        _watchTime.stop();
        setState(() {
          _error = '$error';
          _initVideo = false;
          _playing = false;
        });
      }),
    );
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

  Future<void> _persistProgress() async {
    final player = _player;
    if (player == null || widget.eps.isEmpty) return;
    final index = _index;
    final episodeId = widget.eps[index].itemId;
    final durationMs = player.duration.inMilliseconds;
    final positionMs = player.position.inMilliseconds.clamp(0, durationMs);
    final progress = durationMs > 0 ? positionMs / durationMs : 0.0;
    // Actual active time is independent of seeking and playback speed.
    final seconds =
        _watchTime.elapsedMicroseconds / Duration.microsecondsPerSecond;
    _watchTime.reset();
    try {
      if (seconds > 0) {
        await _historyStore.accumulateReadTime(widget.bookId, 'video', seconds);
      }
      await _historyStore.updateProgress(
        widget.bookId,
        index,
        progress.clamp(0.0, 1.0),
        chapterId: episodeId,
        position: positionMs / 1000,
        maxScroll: durationMs / 1000,
      );
    } catch (_) {
      // Playback continues if history storage is temporarily unavailable.
    }
  }

  Future<void> _selectEpisode(int index) async {
    if (_changingEpisode ||
        index < 0 ||
        index >= widget.eps.length ||
        index == _index) {
      return;
    }
    _changingEpisode = true;
    try {
      await _persistProgress();
      if (!mounted) return;
      setState(() => _index = index);
      await _loadVideo();
    } finally {
      _changingEpisode = false;
    }
  }

  Future<void> _next({bool auto = false}) async {
    if (_index >= widget.eps.length - 1) return;
    await _selectEpisode(_index + 1);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.eps.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(widget.title),
        ),
        body: Center(
          child: Text(
            _error ?? '暂无剧集',
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    final episode = widget.eps[_index];
    final player = _displayPlayer;
    if (player != null && _error == null) {
      return VideoPlayerChrome(
        player: player,
        episodes: widget.eps,
        currentIndex: _index,
        position: _position,
        duration: _duration,
        playing: _playing,
        enabled: identical(player, _player) && player.isCreated && !_initVideo,
        onSelectEpisode: _selectEpisode,
        onError: (error) {
          _watchTime.stop();
          _progressTimer?.cancel();
          setState(() => _error = '$error');
          unawaited(_teardownPlayer());
        },
        child: _videoArea(),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          episode.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Center(
            child: Text(
              '${_index + 1}/${widget.eps.length}',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [Expanded(child: Center(child: _videoArea()))],
        ),
      ),
    );
  }

  Widget _videoArea() {
    if (_initVideo) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _loadVideo, child: const Text('重试')),
        ],
      );
    }
    final player = _player;
    final textureId = player?.textureId;
    if (player == null || textureId == null) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    final vw = player.videoWidth > 0 ? player.videoWidth.toDouble() : 9.0;
    final vh = player.videoHeight > 0 ? player.videoHeight.toDouble() : 16.0;
    final aspectRatio = vw / vh;
    final video = Texture(textureId: textureId);

    Widget display;
    if (aspectRatio > 1.0) {
      display = Center(
        child: AspectRatio(aspectRatio: aspectRatio, child: video),
      );
    } else {
      // Vertical short-drama: fill the screen, crop top/bottom edges.
      display = FittedBox(
        fit: BoxFit.cover,
        alignment: const Alignment(0, 0.45),
        child: SizedBox(width: vw, height: vh, child: video),
      );
    }

    return display;
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
