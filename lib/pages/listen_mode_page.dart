import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/episode_source_cache.dart';
import '../services/native_player.dart';
import '../services/player_preferences.dart';

/// 听书模式页（官方 `jm3.d0.y()` 的 `ShortSeriesLaunchArgs.setIsListenMode`
/// 语义）：独立于视频播放页的音频页——封面、剧名/集名、进度条、上一集/
/// 播放暂停/下一集与选集入口，播完自动连播到下一集。
///
/// 与官方的差异（取证与取舍 — 见
/// .agents/notes/implemented/feature/2026-09-29-listen-mode-and-font-scale.md）：
/// 官方是独立 Activity + 服务端听书数据链路；本页复用现有取流缓存，自建
/// [NativePlayer] 实例只听不看。后台续听靠 `ListenKeepAliveService` 前台
/// 服务保活（MIUI 会冻结无前台组件的后台进程）；本页**不注册**生命周期
/// 暂停——后台照常出声是本页的存在意义。退出时回传最终进度，宿主把它
/// 写回视频播放页。
class ListenModePage extends StatefulWidget {
  const ListenModePage({
    super.key,
    required this.seriesTitle,
    required this.coverUrl,
    required this.episodes,
    required this.initialIndex,
    required this.resolveSource,
    this.playerFactory,
  });

  final String seriesTitle;
  final String coverUrl;
  final List<Chapter> episodes;
  final int initialIndex;

  /// 解析某集的播放地址（宿主传 [EpisodeSourceCache] 的取流链路）。
  final Future<EpisodeSource?> Function(Chapter episode) resolveSource;

  /// 测试注入点；生产用 [NativePlayer.new]。
  final NativePlayer Function()? playerFactory;

  @override
  State<ListenModePage> createState() => _ListenModePageState();
}

class _ListenModePageState extends State<ListenModePage> {
  NativePlayer? _player;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Duration>? _positionSub;
  bool _switching = false;
  bool _popped = false;

  late int _index = widget.initialIndex.clamp(0, widget.episodes.length - 1);
  String _episodeTitle(int i) =>
      widget.episodes.isEmpty ? '' : widget.episodes[i].title;

  static const _rates = <double>[0.75, 1.0, 1.25, 1.5, 2.0];
  double _rate = 1.0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(_index, autoplay: true));
    PlayerPreferences.loadPlaybackRate().then((rate) {
      if (!mounted) return;
      _rate = _rates.contains(rate) ? rate : 1.0;
      unawaited(_player?.setRate(_rate));
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _popped = true;
    _completedSub?.cancel();
    _positionSub?.cancel();
    unawaited(_stopForeground());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _load(int index, {required bool autoplay}) async {
    if (_switching || widget.episodes.isEmpty) return;
    _switching = true;
    // messenger 要等首个 await 之后再取：initState 的同步前缀里
    // dependOnInheritedWidget 会触发框架断言。
    ScaffoldMessengerState? messenger;
    try {
      final source = await widget.resolveSource(widget.episodes[index]);
      if (!mounted || _popped) return;
      messenger = ScaffoldMessenger.maybeOf(context);
      if (source == null || source.url.isEmpty) {
        messenger?.showSnackBar(const SnackBar(content: Text('本集暂时无法收听')));
        return;
      }
      // 选当前画质档（同一地址），没有档位信息就用主地址。
      final variants = source.variants;
      final variant = variants.isEmpty
          ? null
          : variants.firstWhere(
              (v) => v.url == source.url,
              orElse: () => variants.first,
            );
      final url = variant?.url ?? source.url;
      final keyHex = variant?.keyHex ?? source.keyHex;
      await _player?.dispose();
      final player = (widget.playerFactory ?? NativePlayer.new)();
      await player.create(url, keyHex);
      await player.setRate(_rate);
      if (autoplay) unawaited(player.play());
      _completedSub?.cancel();
      _completedSub = player.completedStream.listen((completed) {
        if (completed) _onEpisodeEnded();
      });
      _positionSub?.cancel();
      _positionSub = player.positionStream.listen((_) {
        if (mounted && !_switching) setState(() {});
      });
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _index = index;
      });
      unawaited(_startForeground());
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text('本集暂时无法收听')));
    } finally {
      _switching = false;
    }
  }

  void _onEpisodeEnded() {
    if (!mounted || _index >= widget.episodes.length - 1) return;
    // 官方听书列表连播：下一集自动接上。
    unawaited(_load(_index + 1, autoplay: true));
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    if (player.playWhenReady) {
      await player.pause();
      await _stopForeground();
    } else {
      await player.play();
      await _startForeground();
    }
    if (mounted) setState(() {});
  }

  Future<void> _step(int delta) async {
    final target = _index + delta;
    if (target < 0 || target >= widget.episodes.length) return;
    await _load(target, autoplay: true);
  }

  Future<void> _startForeground() => _foreground('startListenForeground');

  Future<void> _stopForeground() => _foreground('stopListenForeground');

  /// 前台服务保活：只抬高进程优先级防 MIUI 冻结，不拥有播放器。
  /// 通道缺失（测试/旧宿主）静默忽略。
  Future<void> _foreground(String method) async {
    try {
      await const MethodChannel('fqapp/native_player').invokeMethod(method, {
        'title': widget.seriesTitle,
        'episode': _episodeTitle(_index),
      });
    } on PlatformException catch (_) {
      // 旧宿主没有这两个方法：后台续听退化为「尽力而为」。
    } on MissingPluginException catch (_) {
      // 测试环境没有宿主。
    }
  }

  void _seekTo(double value) {
    final player = _player;
    if (player == null || player.duration.inMilliseconds <= 0) return;
    unawaited(
      player.seek(Duration(milliseconds: (value * player.duration.inMilliseconds).round())),
    );
  }

  void _exitWithResult() =>
      Navigator.pop(context, (_index, _player?.position ?? Duration.zero));

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final playing = player?.playWhenReady ?? false;
    final position = player?.position ?? Duration.zero;
    final duration = player?.duration ?? Duration.zero;
    // 返回时把「听到哪一集 + 进度」一起交给宿主：听书页可能已自动连播
    // 跨集，宿主要跟到那一集续看（官方 sync_progress_strategy_listen_mode）。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitWithResult();
      },
      child: Scaffold(
      key: const ValueKey('listen-page'),
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          key: const ValueKey('listen-page-back'),
          onPressed: _exitWithResult,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(
          widget.seriesTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    ApiClient.instance.absoluteUrl(widget.coverUrl),
                    key: const ValueKey('listen-cover'),
                    width: 220,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const SizedBox(width: 220, height: 220),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '第 ${_index + 1} 集 · ${_episodeTitle(_index)}',
                    key: const ValueKey('listen-episode-title'),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_fmt(position)} / ${_fmt(duration)}',
                    key: const ValueKey('listen-time'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0x99FFFFFF),
                    ),
                  ),
                  Slider(
                    key: const ValueKey('listen-seek'),
                    value: duration.inMilliseconds <= 0
                        ? 0
                        : (position.inMilliseconds / duration.inMilliseconds)
                              .clamp(0.0, 1.0),
                    onChanged: duration.inMilliseconds <= 0 ? null : _seekTo,
                    activeColor: const Color(0xFFFA6725),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        key: const ValueKey('listen-prev'),
                        onPressed: _index > 0 ? () => unawaited(_step(-1)) : null,
                        icon: const Icon(Icons.skip_previous, size: 40),
                        color: Colors.white,
                        disabledColor: const Color(0x33FFFFFF),
                      ),
                      const SizedBox(width: 24),
                      IconButton(
                        key: const ValueKey('listen-play'),
                        onPressed: player == null
                            ? null
                            : () => unawaited(_togglePlay()),
                        icon: Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          size: 64,
                        ),
                        color: const Color(0xFFFA6725),
                      ),
                      const SizedBox(width: 24),
                      IconButton(
                        key: const ValueKey('listen-next'),
                        onPressed: _index < widget.episodes.length - 1
                            ? () => unawaited(_step(1))
                            : null,
                        icon: const Icon(Icons.skip_next, size: 40),
                        color: Colors.white,
                        disabledColor: const Color(0x33FFFFFF),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      for (final rate in _rates)
                        _ratePill(context, rate),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
      ),
    );
  }

  Widget _ratePill(BuildContext context, double rate) {
    final selected = rate == _rate;
    return InkWell(
      key: ValueKey('listen-rate-$rate'),
      onTap: () async {
        await _player?.setRate(rate);
        await PlayerPreferences.savePlaybackRate(rate);
        if (mounted) setState(() => _rate = rate);
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFA6725) : const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          '${rate == rate.roundToDouble() ? rate.toInt() : rate}x',
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : const Color(0x99FFFFFF),
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
