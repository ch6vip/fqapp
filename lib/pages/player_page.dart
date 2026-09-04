import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';

class PlayerPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> eps;
  final int startIndex;

  const PlayerPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.eps,
    required this.startIndex,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late int _index;
  NativePlayer? _player;
  Timer? _progressTimer;
  bool _initVideo = false;
  bool _advancing = false;
  String? _error;
  int _loadGeneration = 0;
  // Playback position (seconds) of the previous tick; used to accumulate
  // watched time from position deltas (seek-backs are ignored).
  double _lastPos = 0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    NativePlayer.setKeepScreenOn(true);
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
    NativePlayer.setKeepScreenOn(false);
    _progressTimer?.cancel();
    _persistProgress();
    _teardownPlayer();
    super.dispose();
  }

  void _teardownPlayer() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final old = _player;
    _player = null;
    old?.dispose();
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
    _lastPos = 0;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _teardownPlayer();

    try {
      final response = await ApiClient.instance.content(
        episode.itemId,
        tab: '短剧',
        mode: 'stream',
      );
      final data = response['data'] is Map
          ? Map<String, dynamic>.from(response['data'] as Map)
          : response;
      var rawUrl =
          (data['video_url'] ?? data['main_url'] ?? '').toString().trim();
      final keyHex = (data['key_hex'] ?? '').toString().trim();
      if (rawUrl.isEmpty) {
        // Old backends may not expose the stream route; fall back to the
        // deep video URL extraction used previously.
        rawUrl = _extractVideoUrl(response);
      }
      final url = rawUrl.isEmpty
          ? ''
          : ApiClient.instance.absoluteUrl(rawUrl);
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
    final player = NativePlayer();
    try {
      await player.create(url, keyHex);
      if (!mounted || generation != _loadGeneration) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
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
    final saved = await LibraryStore.instance.historyEntry(widget.bookId);
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
        await player.seek(Duration(milliseconds: (savedSeconds * 1000).round()));
      }
    }
    await player.play();
    _progressTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _persistProgress(),
    );
    await LibraryStore.instance.addHistory({
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
    _subs.add(player.positionStream.listen((pos) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _position = pos);
    }));
    _subs.add(player.durationStream.listen((dur) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _duration = dur);
    }));
    _subs.add(player.playingStream.listen((playing) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _playing = playing);
    }));
    _subs.add(player.completedStream.listen((completed) {
      if (!mounted ||
          generation != _loadGeneration ||
          !completed ||
          _advancing) {
        return;
      }
      _advancing = true;
      unawaited(_next(auto: true).whenComplete(() => _advancing = false));
    }));
  }

  Future<void> _persistProgress() async {
    final player = _player;
    if (player == null || widget.eps.isEmpty) return;
    final index = _index;
    final episodeId = widget.eps[index].itemId;
    final durationMs = player.duration.inMilliseconds;
    final positionMs = player.position.inMilliseconds.clamp(0, durationMs);
    final progress = durationMs > 0 ? positionMs / durationMs : 0.0;
    // Accumulate watched time from position deltas. A seek-back adds
    // nothing, so scrubbing cannot double-count.
    final posSeconds = positionMs / 1000;
    if (player.playing && posSeconds > _lastPos + 0.5) {
      final delta = posSeconds - _lastPos;
      await LibraryStore.instance.accumulateReadTime(
        widget.bookId,
        'video',
        delta,
      );
    }
    _lastPos = posSeconds;
    await LibraryStore.instance.updateProgress(
      widget.bookId,
      index,
      progress.clamp(0.0, 1.0),
      chapterId: episodeId,
      position: positionMs / 1000,
      maxScroll: durationMs / 1000,
    );
  }

  Future<void> _prev() async {
    if (_index <= 0) return;
    await _persistProgress();
    if (!mounted) return;
    setState(() => _index--);
    await _loadVideo();
  }

  Future<void> _next({bool auto = false}) async {
    if (_index >= widget.eps.length - 1) {
      if (!auto && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已是最后一集')));
      }
      return;
    }
    await _persistProgress();
    if (!mounted) return;
    setState(() => _index++);
    await _loadVideo();
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
          children: [
            Expanded(child: Center(child: _videoArea())),
            if (_player != null && _player!.isCreated) _controls(),
          ],
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

    return GestureDetector(
      onTap: () {
        if (_playing) {
          player.pause();
        } else {
          player.play();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          display,
          if (!_playing)
            const Center(
              child: Icon(
                Icons.play_circle_outline,
                size: 72,
                color: Colors.white70,
              ),
            ),
        ],
      ),
    );
  }

  Widget _controls() {
    final player = _player!;
    final durationMs = _duration.inMilliseconds;
    final positionMs = _position.inMilliseconds.clamp(0, durationMs);
    final value = durationMs > 0 ? positionMs / durationMs : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFFE8532D),
              inactiveTrackColor: Colors.white24,
              thumbColor: const Color(0xFFE8532D),
              overlayColor: const Color(0xFFE8532D).withValues(alpha: 0.2),
              trackHeight: 3,
            ),
            child: Slider(
              value: value.clamp(0.0, 1.0),
              onChangeStart: (_) => player.pause(),
              onChanged: (v) {
                setState(() {
                  _position = Duration(milliseconds: (durationMs * v).round());
                });
              },
              onChangeEnd: (v) {
                player.seek(Duration(milliseconds: (durationMs * v).round()));
                player.play();
              },
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(
                  Icons.skip_previous,
                  color: Colors.white,
                  size: 36,
                ),
                onPressed: _index > 0 ? _prev : null,
              ),
              const SizedBox(width: 22),
              IconButton(
                icon: Icon(
                  _playing ? Icons.pause_circle : Icons.play_circle,
                  color: Colors.white,
                  size: 48,
                ),
                onPressed: () {
                  if (_playing) {
                    player.pause();
                  } else {
                    player.play();
                  }
                },
              ),
              const SizedBox(width: 22),
              IconButton(
                icon: const Icon(
                  Icons.skip_next,
                  color: Colors.white,
                  size: 36,
                ),
                onPressed: _index < widget.eps.length - 1 ? _next : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
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
