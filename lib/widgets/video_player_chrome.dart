import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/native_player.dart';
import '../services/player_preferences.dart';

class VideoPlayerChrome extends StatefulWidget {
  final NativePlayer player;
  final List<Chapter> episodes;
  final int currentIndex;
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool enabled;
  final Widget child;
  final Future<void> Function(int) onSelectEpisode;
  final void Function(Object) onError;

  const VideoPlayerChrome({
    super.key,
    required this.player,
    required this.episodes,
    required this.currentIndex,
    required this.position,
    required this.duration,
    required this.playing,
    this.enabled = true,
    required this.child,
    required this.onSelectEpisode,
    required this.onError,
  });

  @override
  State<VideoPlayerChrome> createState() => _VideoPlayerChromeState();
}

class _VideoPlayerChromeState extends State<VideoPlayerChrome>
    with WidgetsBindingObserver {
  Timer? _hideTimer;
  bool _visible = true;
  bool _seeking = false;
  bool _resumeAfterSeek = false;
  bool _sheetOpen = false;
  bool _fullScreen = false;
  bool _boosting = false;
  bool _appActive = true;
  bool _resumeOnForeground = false;
  double _rate = 1;
  int _rateGeneration = 0;
  Future<void> _systemUiUpdates = Future<void>.value();
  bool _systemUiTouched = false;
  double? _seekValue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _loadRate();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(VideoPlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _seeking = false;
      _seekValue = null;
      _boosting = false;
      _visible = true;
      _control(widget.player.setRate(_rate));
    }
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.playing != widget.playing ||
        oldWidget.player != widget.player) {
      if ((!widget.playing && !_seeking) || !widget.enabled) _visible = true;
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    if (_systemUiTouched) {
      unawaited(_systemUiUpdates.then((_) => _restoreSystemUi()));
    }
    super.dispose();
  }

  Future<void> _loadRate() async {
    final generation = _rateGeneration;
    try {
      final rate = await PlayerPreferences.loadPlaybackRate();
      if (!mounted || generation != _rateGeneration) return;
      setState(() => _rate = rate);
      await _control(widget.player.setRate(_boosting ? 2 : rate));
    } catch (_) {
      // Keep normal playback available if preferences cannot be read.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (!active && _appActive) {
      _appActive = false;
      _resumeOnForeground = widget.playing && !_seeking;
      _endBoost();
      _hideTimer?.cancel();
      _control(widget.player.pause());
    } else if (active && !_appActive) {
      _appActive = true;
      if (_resumeOnForeground) _control(widget.player.play());
      _resumeOnForeground = false;
      _scheduleHide();
    }
  }

  Future<void> _control(Future<void> operation) async {
    final player = widget.player;
    try {
      await operation;
    } catch (error) {
      if (mounted && widget.player == player) widget.onError(error);
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.enabled ||
        !_appActive ||
        !widget.playing ||
        _seeking ||
        _sheetOpen ||
        _boosting) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _toggleControls() {
    setState(() => _visible = !_visible);
    if (_visible) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _togglePlayback() {
    if (!widget.enabled) return;
    _endBoost();
    _control(widget.playing ? widget.player.pause() : widget.player.play());
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _startSeek(double value) {
    _hideTimer?.cancel();
    _resumeAfterSeek = widget.playing;
    setState(() {
      _seeking = true;
      _seekValue = value;
    });
    _control(widget.player.pause());
  }

  Future<void> _finishSeek(double value) async {
    final player = widget.player;
    final target = Duration(
      milliseconds: (widget.duration.inMilliseconds * value).round(),
    );
    try {
      await player.seek(target);
      if (!mounted || widget.player != player) return;
      if (_resumeAfterSeek && _appActive) await player.play();
    } catch (error) {
      if (mounted && widget.player == player) widget.onError(error);
    } finally {
      if (mounted && widget.player == player) {
        setState(() {
          _seeking = false;
          _seekValue = null;
        });
        _scheduleHide();
      }
    }
  }

  void _seekBy(int seconds) {
    final milliseconds = (widget.position.inMilliseconds + seconds * 1000)
        .clamp(0, widget.duration.inMilliseconds);
    _control(widget.player.seek(Duration(milliseconds: milliseconds)));
    _scheduleHide();
  }

  void _startBoost() {
    if (!widget.enabled || !widget.playing || _seeking) return;
    _hideTimer?.cancel();
    setState(() => _boosting = true);
    _control(widget.player.setRate(2));
  }

  void _endBoost() {
    if (!_boosting) return;
    if (mounted) setState(() => _boosting = false);
    _control(widget.player.setRate(_rate));
    _scheduleHide();
  }

  Future<void> _showRates() async {
    _hideTimer?.cancel();
    _sheetOpen = true;
    final selected = await showModalBottomSheet<double>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('播放速度', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  for (final rate in PlayerPreferences.playbackRates)
                    ChoiceChip(
                      label: Text('${_rateLabel(rate)}×'),
                      selected: rate == _rate,
                      onSelected: (_) => Navigator.pop(context, rate),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    _sheetOpen = false;
    if (selected != null) {
      ++_rateGeneration;
      setState(() => _rate = selected);
      await _control(widget.player.setRate(selected));
      try {
        await PlayerPreferences.savePlaybackRate(selected);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('倍速已生效，但未能保存设置')));
        }
      }
    }
    if (mounted) _scheduleHide();
  }

  Future<void> _showEpisodes() async {
    _hideTimer?.cancel();
    _sheetOpen = true;
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: _EpisodeSheet(
          episodes: widget.episodes,
          currentIndex: widget.currentIndex,
        ),
      ),
    );
    if (!mounted) return;
    _sheetOpen = false;
    if (selected != null && selected != widget.currentIndex) {
      await widget.onSelectEpisode(selected);
    }
    if (mounted) _scheduleHide();
  }

  Future<void> _toggleFullScreen() async {
    _systemUiTouched = true;
    setState(() => _fullScreen = !_fullScreen);
    final fullScreen = _fullScreen;
    final operation = _systemUiUpdates.then((_) async {
      if (!mounted || _fullScreen != fullScreen) return;
      if (fullScreen) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        final landscape = widget.player.videoWidth > widget.player.videoHeight;
        await SystemChrome.setPreferredOrientations(
          landscape
              ? [
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]
              : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
        );
      } else {
        await _restoreSystemUi();
      }
    });
    _systemUiUpdates = operation.catchError((Object _) {});
    await _systemUiUpdates;
    if (mounted) _scheduleHide();
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds;
    final positionMs = widget.position.inMilliseconds.clamp(0, durationMs);
    final value =
        _seekValue ?? (durationMs > 0 ? positionMs / durationMs : 0.0);
    return PopScope(
      canPop: !_fullScreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _fullScreen) _toggleFullScreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                key: const ValueKey('video-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: _togglePlayback,
                onLongPressStart: (_) => _startBoost(),
                onLongPressEnd: (_) => _endBoost(),
                onLongPressCancel: _endBoost,
                child: widget.child,
              ),
              if (_visible) ...[
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          BackButton(
                            color: Colors.white,
                            onPressed: () {
                              if (_fullScreen) {
                                _toggleFullScreen();
                              } else {
                                Navigator.maybePop(context);
                              }
                            },
                          ),
                          Expanded(
                            child: Text(
                              widget.episodes[widget.currentIndex].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              '${widget.currentIndex + 1}/${widget.episodes.length}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (widget.enabled)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      key: const ValueKey('video-controls'),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * 0.65,
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
                            child: Theme(
                              data: ThemeData.dark(useMaterial3: true),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Slider(
                                    key: const ValueKey('video-seek'),
                                    value: value.clamp(0.0, 1.0),
                                    onChangeStart: durationMs > 0
                                        ? _startSeek
                                        : null,
                                    onChanged: durationMs > 0
                                        ? (value) =>
                                              setState(() => _seekValue = value)
                                        : null,
                                    onChangeEnd: durationMs > 0
                                        ? _finishSeek
                                        : null,
                                  ),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _time(
                                            Duration(
                                              milliseconds: (durationMs * value)
                                                  .round(),
                                            ),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          _time(widget.duration),
                                          textAlign: TextAlign.end,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 8,
                                    children: [
                                      IconButton(
                                        tooltip: '上一集',
                                        onPressed: widget.currentIndex > 0
                                            ? () => widget.onSelectEpisode(
                                                widget.currentIndex - 1,
                                              )
                                            : null,
                                        icon: const Icon(Icons.skip_previous),
                                      ),
                                      IconButton(
                                        tooltip: '快退10秒',
                                        onPressed: durationMs > 0
                                            ? () => _seekBy(-10)
                                            : null,
                                        icon: const Icon(Icons.replay_10),
                                      ),
                                      IconButton(
                                        tooltip: widget.playing ? '暂停' : '播放',
                                        onPressed: _togglePlayback,
                                        iconSize: 40,
                                        icon: Icon(
                                          widget.playing
                                              ? Icons.pause_circle
                                              : Icons.play_circle,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '快进10秒',
                                        onPressed: durationMs > 0
                                            ? () => _seekBy(10)
                                            : null,
                                        icon: const Icon(Icons.forward_10),
                                      ),
                                      IconButton(
                                        tooltip: '下一集',
                                        onPressed:
                                            widget.currentIndex <
                                                widget.episodes.length - 1
                                            ? () => widget.onSelectEpisode(
                                                widget.currentIndex + 1,
                                              )
                                            : null,
                                        icon: const Icon(Icons.skip_next),
                                      ),
                                    ],
                                  ),
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 12,
                                    children: [
                                      TextButton(
                                        onPressed: _showRates,
                                        child: Text('倍速 ${_rateLabel(_rate)}×'),
                                      ),
                                      TextButton.icon(
                                        onPressed: _showEpisodes,
                                        icon: const Icon(Icons.playlist_play),
                                        label: const Text('选集'),
                                      ),
                                      IconButton(
                                        tooltip: _fullScreen ? '退出全屏' : '全屏',
                                        onPressed: _toggleFullScreen,
                                        icon: Icon(
                                          _fullScreen
                                              ? Icons.fullscreen_exit
                                              : Icons.fullscreen,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
              if (_boosting)
                const Align(
                  alignment: Alignment.center,
                  child: IgnorePointer(child: Chip(label: Text('2× 加速中'))),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _rateLabel(double rate) =>
    rate == rate.roundToDouble() ? rate.toInt().toString() : rate.toString();

String _time(Duration value) {
  final seconds = value.inSeconds;
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
}

class _EpisodeSheet extends StatefulWidget {
  final List<Chapter> episodes;
  final int currentIndex;

  const _EpisodeSheet({required this.episodes, required this.currentIndex});

  @override
  State<_EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<_EpisodeSheet> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: (widget.currentIndex * 64.0 - 100).clamp(
      0,
      double.infinity,
    ),
  );
  String _query = '';

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexes = [
      for (var i = 0; i < widget.episodes.length; i++)
        if (_query.isEmpty ||
            '${i + 1}'.contains(_query) ||
            widget.episodes[i].title.toLowerCase().contains(
              _query.toLowerCase(),
            ))
          i,
    ];
    return Column(
      children: [
        Text(
          '选集 · ${widget.episodes.length} 集',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索集数或标题',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) {
              setState(() => _query = value.trim());
              if (_scroll.hasClients) _scroll.jumpTo(0);
            },
          ),
        ),
        Expanded(
          child: indexes.isEmpty
              ? const Center(child: Text('没有匹配的剧集'))
              : ListView.builder(
                  controller: _scroll,
                  itemExtent: 64,
                  itemCount: indexes.length,
                  itemBuilder: (context, position) {
                    final index = indexes[position];
                    return ListTile(
                      selected: index == widget.currentIndex,
                      leading: Text('${index + 1}'),
                      title: Text(
                        widget.episodes[index].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: index == widget.currentIndex
                          ? const Icon(Icons.play_arrow)
                          : null,
                      onTap: () => Navigator.pop(context, index),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
