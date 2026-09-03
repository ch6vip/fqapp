import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';

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
  VideoPlayerController? _ctrl;
  Timer? _progressTimer;
  bool _initVideo = false;
  bool _advancing = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
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
    _progressTimer?.cancel();
    _persistProgress();
    _ctrl?.dispose();
    super.dispose();
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
    final old = _ctrl;
    _ctrl = null;
    await old?.dispose();

    try {
      final response = await ApiClient.instance.content(
        episode.itemId,
        tab: '短剧',
      );
      final rawUrl = _extractVideoUrl(response);
      if (rawUrl.isEmpty) throw ApiException('获取播放地址失败');
      final url = ApiClient.instance.absoluteUrl(rawUrl);

      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted || generation != _loadGeneration) {
        await controller.dispose();
        return;
      }
      controller
        ..setLooping(false)
        ..addListener(_onVideoChanged);
      setState(() {
        _ctrl = controller;
        _initVideo = false;
      });
      final saved = await LibraryStore.instance.historyEntry(widget.bookId);
      if (!mounted || generation != _loadGeneration) {
        await controller.dispose();
        return;
      }
      final savedEpisode = saved?['episode'] is num
          ? (saved!['episode'] as num).toInt()
          : -1;
      if (savedEpisode == _index && saved?['position'] is num) {
        final savedSeconds = (saved!['position'] as num).toDouble();
        if (savedSeconds > 0) {
          await controller.seekTo(
            Duration(milliseconds: (savedSeconds * 1000).round()),
          );
        }
      }
      await controller.play();
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
        'duration': controller.value.duration.inMilliseconds / 1000,
        'cover': widget.cover,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$e';
        _initVideo = false;
      });
    }
  }

  void _onVideoChanged() {
    final controller = _ctrl;
    if (!mounted || controller == null) return;
    if (controller.value.isCompleted && !_advancing) {
      _advancing = true;
      unawaited(_next(auto: true).whenComplete(() => _advancing = false));
    }
    // Refresh the play/pause overlay and timestamps without rebuilding while
    // the video is merely advancing frames.
    if (controller.value.isPlaying != _lastPlaying) {
      _lastPlaying = controller.value.isPlaying;
      setState(() {});
    }
  }

  bool _lastPlaying = false;

  Future<void> _persistProgress() async {
    final controller = _ctrl;
    if (controller == null ||
        !controller.value.isInitialized ||
        widget.eps.isEmpty) {
      return;
    }
    final index = _index;
    final episodeId = widget.eps[index].itemId;
    final durationMs = controller.value.duration.inMilliseconds;
    final positionMs = controller.value.position.inMilliseconds.clamp(
      0,
      durationMs,
    );
    final progress = durationMs > 0 ? positionMs / durationMs : 0.0;
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
            if (_ctrl != null && _ctrl!.value.isInitialized) _controls(),
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
    final controller = _ctrl;
    if (controller == null || !controller.value.isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: GestureDetector(
        onTap: () {
          controller.value.isPlaying ? controller.pause() : controller.play();
        },
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            if (!controller.value.isPlaying)
              const Center(
                child: Icon(
                  Icons.play_circle_outline,
                  size: 72,
                  color: Colors.white70,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    final controller = _ctrl!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        children: [
          VideoProgressIndicator(
            controller,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: Color(0xFFE8532D),
              bufferedColor: Colors.white38,
              backgroundColor: Colors.white12,
            ),
          ),
          const SizedBox(height: 8),
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
                  controller.value.isPlaying
                      ? Icons.pause_circle
                      : Icons.play_circle,
                  color: Colors.white,
                  size: 48,
                ),
                onPressed: () {
                  controller.value.isPlaying
                      ? controller.pause()
                      : controller.play();
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
