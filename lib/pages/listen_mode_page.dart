import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/app_theme.dart';
import '../services/audio_floating_routes.dart';
import '../services/audio_preferences.dart';
import '../services/episode_source_cache.dart';
import '../services/native_player.dart';
import '../services/player_preferences.dart';
import '../widgets/home/home_design.dart';
import '../widgets/listen_progress_bar.dart';

/// 听书模式页（官方 `jm3.d0.y()` 的 `ShortSeriesLaunchArgs.setIsListenMode`
/// 语义）：独立于视频播放页的音频页——封面、剧名/集名、进度条、上一集/
/// 播放暂停/下一集与选集入口，播完自动连播到下一集。
///
/// 与官方的差异（取证与取舍 — 见
/// .agents/notes/implemented/feature/2026-09-29-listen-mode-and-font-scale.md）：
/// 官方是独立 Activity + 服务端听书数据链路；本页复用现有取流缓存，自建
/// [NativePlayer] 实例只听不看。后台续听靠 `ListenKeepAliveService` 前台
/// 服务保活（MIUI 会冻结无前台组件的后台进程）；在后台听书开关开启时
/// 后台照常出声。退出时回传最终进度，宿主把它写回视频播放页。
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

class _ListenModePageState extends State<ListenModePage>
    with WidgetsBindingObserver {
  NativePlayer? _player;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  bool _switching = false;
  bool _popped = false;

  late int _index = widget.initialIndex.clamp(0, widget.episodes.length - 1);
  String _episodeTitle(int i) =>
      widget.episodes.isEmpty ? '' : widget.episodes[i].title;

  static const _rates = <double>[0.75, 1.0, 1.25, 1.5, 2.0];
  double _rate = 1.0;

  /// 播放位置（原生位置流约 5Hz）：只喂给进度区，不触发整页重建。
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);

  /// 总时长：`create` 完成时原生可能还不知道时长，`duration` 事件随后才到；
  /// 页面位置流不再整页 setState，所以它也必须有自己的通知。
  final ValueNotifier<Duration> _duration = ValueNotifier(Duration.zero);

  // Official listen mode is ShortSeriesActivity, which hides the capsule.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AudioFloatingRouteScope.configure(context, hidden: true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AudioPreferences.instance.load());
    NativePlayer.setRemoteCommandHandler(
      onAction: _handleRemoteAction,
      onBecomingNoisy: _handleBecomingNoisy,
    );
    unawaited(_load(_index, autoplay: true));
    PlayerPreferences.loadPlaybackRate().then((rate) {
      if (!mounted) return;
      _rate = _rates.contains(rate) ? rate : 1.0;
      unawaited(_player?.setRate(_rate));
      if (mounted) setState(() {});
    });
  }

  void _handleRemoteAction(String action) {
    if (!mounted) return;
    switch (action) {
      case 'playPause':
        unawaited(_togglePlay());
      case 'prev':
        if (_index > 0) unawaited(_step(-1));
      case 'next':
        if (_index < widget.episodes.length - 1) unawaited(_step(1));
      case 'stop':
        unawaited(_player?.pause());
        unawaited(_stopForeground());
        if (mounted) setState(() {});
    }
  }

  void _handleBecomingNoisy() {
    if (!mounted) return;
    unawaited(_player?.pause());
    unawaited(_stopForeground());
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        !AudioPreferences.instance.backgroundPlayback.value) {
      unawaited(_player?.pause());
      unawaited(_stopForeground());
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _popped = true;
    WidgetsBinding.instance.removeObserver(this);
    NativePlayer.clearRemoteCommandHandler();
    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _position.dispose();
    _duration.dispose();
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
      // 旧播放器释放后立即把字段置空：否则下面任何一步抛异常都会让 `_player`
      // 继续指向已释放的句柄，播放按钮可点却静默无响应。
      final previous = _player;
      _player = null;
      await previous?.dispose();
      NativePlayer? created;
      try {
        final player =
            (widget.playerFactory ?? () => NativePlayer(audioOnly: true))();
        created = player;
        await player.create(url, keyHex);
        await player.setRate(_rate);
        if (autoplay) unawaited(player.play());
        _completedSub?.cancel();
        _completedSub = player.completedStream.listen((completed) {
          if (completed) _onEpisodeEnded();
        });
        _positionSub?.cancel();
        _positionSub = player.positionStream.listen((position) {
          if (mounted && !_switching) _position.value = position;
        });
        _durationSub?.cancel();
        _durationSub = player.durationStream.listen((duration) {
          if (mounted && !_switching) _duration.value = duration;
        });
        if (!mounted) return;
        setState(() {
          _player = player;
          _index = index;
          _position.value = player.position;
          // 新集重置；已经拿到时长（事件早于订阅）时沿用播放器的值。
          _duration.value = player.duration;
        });
        // 所有权已交给 `_player`，不能在这里释放。
        created = null;
        unawaited(_startForeground());
      } finally {
        // 创建/初始化失败，或页面已卸载：新建的播放器不能泄漏。
        await created?.dispose();
      }
    } catch (_) {
      // `messenger` 要等首个 await 之后才能取（见上），而这里正是那条 await
      // 抛出的路径——不补取一次，取流失败会被静默吞掉，界面毫无提示。
      final state =
          messenger ?? (mounted ? ScaffoldMessenger.maybeOf(context) : null);
      state?.showSnackBar(const SnackBar(content: Text('本集暂时无法收听')));
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
      await _startForeground();
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

  Future<void> _startForeground() {
    if (!AudioPreferences.instance.backgroundPlayback.value) {
      return _stopForeground();
    }
    final player = _player;
    return NativePlayer.startListenForeground(
      title: widget.seriesTitle,
      episode: _episodeTitle(_index),
      // 通知左上角与系统媒体卡片显示的就是这张封面（对齐官方）。
      coverUrl: widget.coverUrl,
      playing: player?.playWhenReady ?? true,
      hasPrev: _index > 0,
      hasNext: _index < widget.episodes.length - 1,
      // 位置 + 倍速交给系统外推；总时长决定媒体卡片两侧的时间。
      positionMs: player?.position.inMilliseconds ?? 0,
      durationMs: player?.duration.inMilliseconds ?? 0,
      speed: _rate,
    );
  }

  Future<void> _stopForeground() => NativePlayer.stopListenForeground();

  Future<void> _seekTo(double value) async {
    final player = _player;
    if (player == null || player.duration.inMilliseconds <= 0) return;
    final target = Duration(
      milliseconds: (value * player.duration.inMilliseconds).round(),
    );
    // 拖动结束才走到这里：先把滑块钉在目标位置，等位置流回填。
    _position.value = target;
    await player.seek(target);
    if (!mounted) return;
    await _startForeground();
  }

  void _exitWithResult() =>
      Navigator.pop(context, (_index, _player?.position ?? Duration.zero));

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final playing = player?.playWhenReady ?? false;
    final colors = _listenColors;
    // 返回时把「听到哪一集 + 进度」一起交给宿主：听书页可能已自动连播
    // 跨集，宿主要跟到那一集续看（官方 sync_progress_strategy_listen_mode）。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitWithResult();
      },
      child: Scaffold(
        key: const ValueKey('listen-page'),
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: colors.foreground,
          elevation: 0,
          leading: IconButton(
            key: const ValueKey('listen-page-back'),
            onPressed: _exitWithResult,
            icon: const Icon(LucideIcons.arrow_left),
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
                    // 系列海报全应用都是竖版：信息流卡与官方详情页封面
                    // 都是 5/7。这里给出明确框，而不是只给宽度——只给宽度时
                    // 高度由图片自身撑，受限时 BoxFit.cover 会裁掉海报；失败
                    // 占位也从正方形改成同一比例（issue #85）。
                    child: SizedBox(
                      width: 220,
                      height: 308,
                      child: Image.network(
                        ApiClient.instance.absoluteUrl(widget.coverUrl),
                        key: const ValueKey('listen-cover'),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.expand(),
                      ),
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
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colors.foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ListenProgressBar(
                      position: _position,
                      duration: _duration,
                      onSeek: _seekTo,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          key: const ValueKey('listen-prev'),
                          onPressed: _index > 0
                              ? () => unawaited(_step(-1))
                              : null,
                          icon: const Icon(LucideIcons.skip_back, size: 40),
                          color: colors.foreground,
                          disabledColor: colors.disabled,
                        ),
                        const SizedBox(width: 24),
                        IconButton(
                          key: const ValueKey('listen-play'),
                          onPressed: player == null
                              ? null
                              : () => unawaited(_togglePlay()),
                          icon: Icon(
                            playing
                                ? LucideIcons.circle_pause
                                : LucideIcons.circle_play,
                            size: 64,
                          ),
                          color: colors.accent,
                        ),
                        const SizedBox(width: 24),
                        IconButton(
                          key: const ValueKey('listen-next'),
                          onPressed: _index < widget.episodes.length - 1
                              ? () => unawaited(_step(1))
                              : null,
                          icon: const Icon(LucideIcons.skip_forward, size: 40),
                          color: colors.foreground,
                          disabledColor: colors.disabled,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        for (final rate in _rates) _ratePill(context, rate),
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

  /// 整页配色：官方深色 #121212 / OLED 纯黑 / 墨水屏白底黑字。
  ///
  /// 深色下 AppBar 与按钮本来就是透明 + 白字；墨水屏必须单独翻成黑字。
  ({Color background, Color foreground, Color accent, Color disabled})
  get _listenColors {
    final palette = HomePalette.of(context);
    if (palette.eink) {
      return (
        background: palette.canvas,
        foreground: palette.ink,
        accent: palette.ink,
        disabled: palette.ink.withValues(alpha: 0.35),
      );
    }
    return (
      background: oledActive() ? Colors.black : const Color(0xFF121212),
      foreground: Colors.white,
      accent: const Color(0xFFFA6725),
      disabled: const Color(0x33FFFFFF),
    );
  }

  Widget _ratePill(BuildContext context, double rate) {
    final selected = rate == _rate;
    final palette = HomePalette.of(context);
    final eink = palette.eink;
    final background = eink
        ? (selected ? palette.ink : palette.canvas)
        : (selected ? const Color(0xFFFA6725) : const Color(0x14FFFFFF));
    final foreground = eink
        ? (selected ? palette.canvas : palette.ink)
        : (selected ? Colors.white : const Color(0x99FFFFFF));
    return InkWell(
      key: ValueKey('listen-rate-$rate'),
      onTap: () async {
        await _player?.setRate(rate);
        await PlayerPreferences.savePlaybackRate(rate);
        if (mounted) setState(() => _rate = rate);
        // 倍速是系统进度条外推的乘数，改了就得同步一次。
        unawaited(_startForeground());
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: eink && !selected ? Border.all(color: palette.line) : null,
        ),
        child: Text(
          '${rate == rate.roundToDouble() ? rate.toInt() : rate}x',
          style: TextStyle(fontSize: 12, color: foreground),
        ),
      ),
    );
  }
}
