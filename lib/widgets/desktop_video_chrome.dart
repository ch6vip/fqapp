import '../services/player_preferences.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/desktop_platform.dart';
import 'video_player_chrome.dart';
import 'player/playlet_danmaku_layer.dart';
import 'player/playlet_danmaku_settings.dart';

class DesktopVideoChrome extends StatefulWidget {
  const DesktopVideoChrome({
    super.key,
    required this.configuration,
    required this.onRateSelected,
    this.onVolumeSelected,
  });
  final VideoPlayerChrome configuration;
  final Future<void> Function(double) onRateSelected;
  final Future<void> Function(double)? onVolumeSelected;
  @override
  State<DesktopVideoChrome> createState() => _DesktopVideoChromeState();
}

class _DesktopVideoChromeState extends State<DesktopVideoChrome> {
  VideoPlayerChrome get c => widget.configuration;
  bool _visible = true;
  bool _dockCollapsed = false;
  double _volume = 1;
  double _rate = 1;
  double? _scrub;
  Timer? _hide;
  final _position = ValueNotifier<Duration>(Duration.zero);
  StreamSubscription<Duration>? _positionSub;
  final _catalogController = ScrollController();

  // 选集网格几何：面板宽固定 304，桌面鼠标操作按 6 列小按钮排（旧版
  // 4 列大按钮一屏约 24 集，这个密度一屏两倍以上，长剧翻集不再逐屏
  // 滚）。行距由这些常量反推，区间跳集与「回到当前集」靠它算滚动
  // 偏移，改几何必须同步这里。
  static const _catalogWidth = 304.0;
  static const _catalogColumns = 6;
  static const _catalogSpacing = 6.0;
  static const _catalogGridPadding = 12.0;
  static const _catalogAspectRatio = 1.45;
  static const _catalogSegmentSize = 50;

  double get _catalogRowPitch {
    final cellWidth =
        (_catalogWidth -
            _catalogGridPadding * 2 -
            _catalogSpacing * (_catalogColumns - 1)) /
        _catalogColumns;
    return cellWidth / _catalogAspectRatio + _catalogSpacing;
  }

  @override
  void initState() {
    super.initState();
    _bindPosition();
    _scrollCatalogTo(c.currentIndex, animate: false);
    unawaited(
      PlayerPreferences.loadPlaybackRate().then((value) {
        if (mounted) setState(() => _rate = value);
      }),
    );
    _volume = c.defaultMute ? 0 : 1;
  }

  void _bindPosition() {
    _positionSub?.cancel();
    _position.value = c.player?.position ?? Duration.zero;
    _positionSub = c.player?.positionStream.listen(
      (value) => _position.value = value,
    );
  }

  @override
  void didUpdateWidget(covariant DesktopVideoChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration.player != c.player) _bindPosition();
    if (oldWidget.configuration.currentIndex != c.currentIndex) {
      _ensureCatalogCurrentVisible();
    }
  }

  bool get _ready => c.enabled && c.player?.isCreated == true;
  @override
  void dispose() {
    _hide?.cancel();
    _positionSub?.cancel();
    _catalogController.dispose();
    _position.dispose();
    if (DesktopPlatform.fullscreen.value) {
      unawaited(DesktopPlatform.instance.setFullscreen(false));
    }
    super.dispose();
  }

  void _show() {
    _hide?.cancel();
    if (!_visible) setState(() => _visible = true);
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && c.playing && _scrub == null) {
        setState(() => _visible = false);
      }
    });
  }

  Future<void> _toggle() async {
    if (!_ready || c.interactionBlocked) return;
    try {
      c.player!.playWhenReady
          ? await c.player!.pause()
          : await c.player!.play();
    } catch (e) {
      c.onError(e);
    }
    _show();
  }

  Future<void> _seek(Duration target) async {
    if (!_ready) return;
    final end = c.duration.inMilliseconds;
    target = Duration(
      milliseconds: target.inMilliseconds.clamp(0, math.max(0, end)),
    );
    try {
      await c.player!.seek(target);
      c.onSeeked?.call(target);
    } catch (e) {
      c.onError(e);
    }
  }

  Future<void>? _applyVolume(double volume) =>
      widget.onVolumeSelected?.call(volume) ?? c.player?.setVolume(volume);

  Future<void> _full() =>
      DesktopPlatform.instance.setFullscreen(!DesktopPlatform.fullscreen.value);

  /// 画面区滚轮：宿主接了切剧回调才响应，纵向滚动转 ±1（下滚下一条）。
  /// 监听层只盖画面区，停靠面板的选集网格不在其命中路径内，照常自滚。
  void _onPointerSignal(PointerEvent event) {
    final navigate = c.onWheelNavigate;
    if (navigate == null || event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    navigate(dy > 0 ? 1 : -1);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || c.interactionBlocked) {
      return KeyEventResult.ignored;
    }
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      unawaited(_toggle());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(
        _seek(
          (c.player?.position ?? Duration.zero) - const Duration(seconds: 10),
        ),
      );
    } else if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(
        _seek(
          (c.player?.position ?? Duration.zero) + const Duration(seconds: 10),
        ),
      );
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      setState(
        () => _volume =
            (_volume + (key == LogicalKeyboardKey.arrowUp ? .05 : -.05)).clamp(
              0,
              1,
            ),
      );
      unawaited(_applyVolume(_volume) ?? Future<void>.value());
    } else if (key == LogicalKeyboardKey.keyF) {
      unawaited(_full());
    } else if (key == LogicalKeyboardKey.escape &&
        DesktopPlatform.fullscreen.value) {
      unawaited(_full());
    } else {
      return KeyEventResult.ignored;
    }
    _show();
    return KeyEventResult.handled;
  }

  String _time(Duration value) {
    final seconds = math.max(0, value.inSeconds);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// 把选集网格滚到 [index] 所在行（行顶对齐，钳制在可滚范围内）。
  /// 网格可能还没挂载（弹窗刚打开、面板刚展开），统一推到帧后执行，
  /// 没挂上时再等一帧。
  void _scrollCatalogTo(int index, {required bool animate, int retries = 1}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_catalogController.hasClients) {
        if (retries > 0) {
          _scrollCatalogTo(index, animate: animate, retries: retries - 1);
        }
        return;
      }
      final position = _catalogController.position;
      final target = ((index ~/ _catalogColumns) * _catalogRowPitch).clamp(
        0.0,
        position.maxScrollExtent,
      );
      if (animate) {
        unawaited(
          _catalogController.animateTo(
            target,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          ),
        );
      } else {
        _catalogController.jumpTo(target);
      }
    });
  }

  /// 切集后把当前集滚进视野；在视野内就不动，免得用户正翻网格时被拽走。
  void _ensureCatalogCurrentVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_catalogController.hasClients) return;
      final position = _catalogController.position;
      final rowTop = (c.currentIndex ~/ _catalogColumns) * _catalogRowPitch;
      final rowBottom = rowTop + _catalogRowPitch - _catalogSpacing;
      if (rowTop < position.pixels ||
          rowBottom > position.pixels + position.viewportDimension) {
        _scrollCatalogTo(c.currentIndex, animate: true);
      }
    });
  }

  Widget _catalog() => SizedBox(
    width: _catalogWidth,
    child: ColoredBox(
      color: const Color(0xff1c1c1f),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.seriesTitle.isEmpty ? c.title : c.seriesTitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '共 ${c.episodes.length} 集 · ${c.episodeLabel}',
                  style: const TextStyle(color: Colors.white60),
                ),
                if (c.synopsis.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    c.synopsis,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              if (c.onOpenSeriesDetail != null)
                TextButton(
                  onPressed: c.onOpenSeriesDetail,
                  child: const Text('作品详情'),
                ),
              if (c.onComments != null)
                TextButton(
                  onPressed: c.onComments,
                  child: Text('评论 ${c.commentCount}'),
                ),
              if (c.onOpenOfflineCache != null)
                TextButton(
                  onPressed: c.onOpenOfflineCache,
                  child: const Text('下载'),
                ),
              if (c.onOpenListenMode != null)
                TextButton(
                  onPressed: c.onOpenListenMode,
                  child: const Text('听剧'),
                ),
              if (c.onOpenRelatedSeries != null)
                TextButton(
                  onPressed: c.onOpenRelatedSeries,
                  child: const Text('同系列'),
                ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('选集', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          // 长剧（如 600+ 集）逐行翻太慢：给一段 50 集的区间跳集，
          // 外加一枚随时回到当前集的定位 chip。
          if (c.episodes.length > _catalogSegmentSize)
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: const Icon(Icons.my_location, size: 14),
                      label: const Text('当前集'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          _scrollCatalogTo(c.currentIndex, animate: true),
                    ),
                  ),
                  for (
                    var start = 0;
                    start < c.episodes.length;
                    start += _catalogSegmentSize
                  )
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                          '${start + 1}-${math.min(start + _catalogSegmentSize, c.episodes.length)}',
                        ),
                        selected:
                            c.currentIndex >= start &&
                            c.currentIndex < start + _catalogSegmentSize,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) =>
                            _scrollCatalogTo(start, animate: true),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: GridView.builder(
              controller: _catalogController,
              padding: const EdgeInsets.fromLTRB(
                _catalogGridPadding,
                0,
                _catalogGridPadding,
                16,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _catalogColumns,
                mainAxisSpacing: _catalogSpacing,
                crossAxisSpacing: _catalogSpacing,
                childAspectRatio: _catalogAspectRatio,
              ),
              itemCount: c.episodes.length,
              itemBuilder: (context, index) => FilledButton.tonal(
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: index == c.currentIndex
                      ? const Color(0xffef5038)
                      : const Color(0xff2c2c30),
                  foregroundColor:
                      c.watchedEpisodes.contains(index) &&
                          index != c.currentIndex
                      ? Colors.white54
                      : Colors.white,
                ),
                onPressed: () => c.onSelectEpisode(index),
                child: Text('${index + 1}'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  Future<void> _showCatalog() {
    // 弹窗打开后把网格定位到当前集（帧后执行，等网格挂载）。
    _scrollCatalogTo(c.currentIndex, animate: false);
    return showDialog<void>(
      context: context,
      builder: (context) => Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: Dialog(
          alignment: Alignment.centerRight,
          insetPadding: const EdgeInsets.all(12),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height - 24,
            child: _catalog(),
          ),
        ),
      ),
    );
  }
  @override
  Widget build(BuildContext context) => Theme(
    data: ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffef5038),
        brightness: Brightness.dark,
      ),
    ),
    child: ValueListenableBuilder<bool>(
      valueListenable: DesktopPlatform.fullscreen,
      builder: (context, full, _) => PopScope(
        canPop: !full,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && full) unawaited(_full());
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: _key,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: LayoutBuilder(
              builder: (context, constraints) {
                final canDock = !full && constraints.maxWidth >= 1000;
                final docked = canDock && !_dockCollapsed;
                return Row(
                  children: [
                    Expanded(
                      child: MouseRegion(
                        onHover: (_) => _show(),
                        onEnter: (_) => _show(),
                        child: Column(
                          children: [
                            if (!full)
                              SizedBox(
                                height: 48,
                                child: Row(
                                  children: [
                                    // 返回只留壳层顶栏一处：这里再放一枚
                                    // 与它重复（同一 Navigator 的 maybePop），
                                    // 只白占视频上方的高度。
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: docked
                                          ? const SizedBox.shrink()
                                          : Text(
                                              c.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                    ),
                                    if (canDock)
                                      IconButton(
                                        tooltip: docked ? '收起面板' : '展开面板',
                                        onPressed: () {
                                          setState(
                                            () => _dockCollapsed =
                                                !_dockCollapsed,
                                          );
                                          // 面板重挂载后滚动位置会丢，
                                          // 展开时重新定位到当前集。
                                          if (!_dockCollapsed) {
                                            _scrollCatalogTo(
                                              c.currentIndex,
                                              animate: false,
                                            );
                                          }
                                        },
                                        icon: Icon(
                                          docked
                                              ? Icons.view_sidebar
                                              : Icons.view_sidebar_outlined,
                                        ),
                                      ),
                                    if (!canDock)
                                      IconButton(
                                        tooltip: '选集与作品信息',
                                        onPressed: _showCatalog,
                                        icon: const Icon(Icons.view_list),
                                      ),
                                  ],
                                ),
                              ),
                            Expanded(
                              child: Center(
                                child: AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _toggle,
                                    onDoubleTap: _full,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Center(
                                          child: AspectRatio(
                                            aspectRatio:
                                                c.player != null &&
                                                    c.player!.videoWidth > 0 &&
                                                    c.player!.videoHeight > 0
                                                ? c.player!.videoWidth /
                                                      c.player!.videoHeight
                                                : 16 / 9,
                                            child: c.child,
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: Listener(
                                            behavior:
                                                HitTestBehavior.translucent,
                                            onPointerSignal: _onPointerSignal,
                                          ),
                                        ),
                                        if (c.danmakuEnabled)
                                          IgnorePointer(
                                            child: PlayletDanmakuLayer(
                                              entries: c.danmaku,
                                              position: _position,
                                              playing: c.playing,
                                              enabled: true,
                                              settings: c.danmakuSettings,
                                              rate: _rate,
                                              landscape: true,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Reserve transport height even while hidden, keeping picture geometry stable.
                            SizedBox(
                              height: 112,
                              child: AnimatedOpacity(
                                opacity: _visible || !c.playing ? 1 : 0,
                                duration: const Duration(milliseconds: 150),
                                child: IgnorePointer(
                                  ignoring: !_visible && c.playing,
                                  child: StreamBuilder<Duration>(
                                    stream: c.player?.positionStream,
                                    initialData:
                                        c.player?.position ?? Duration.zero,
                                    builder: (context, snapshot) {
                                      final max = math
                                          .max(1, c.duration.inMilliseconds)
                                          .toDouble();
                                      final position =
                                          snapshot.data ?? Duration.zero;
                                      return Column(
                                        children: [
                                          Row(
                                            children: [
                                              const SizedBox(width: 16),
                                              Text(_time(position)),
                                              Expanded(
                                                child: Slider(
                                                  value:
                                                      (_scrub ??
                                                              position
                                                                  .inMilliseconds
                                                                  .toDouble())
                                                          .clamp(0, max),
                                                  max: max,
                                                  onChanged: _ready
                                                      ? (v) => setState(
                                                          () => _scrub = v,
                                                        )
                                                      : null,
                                                  onChangeEnd: (v) {
                                                    unawaited(
                                                      _seek(
                                                        Duration(
                                                          milliseconds: v
                                                              .round(),
                                                        ),
                                                      ),
                                                    );
                                                    setState(
                                                      () => _scrub = null,
                                                    );
                                                    _show();
                                                  },
                                                ),
                                              ),
                                              Text(_time(c.duration)),
                                              const SizedBox(width: 16),
                                            ],
                                          ),
                                          Row(
                                            children: [
                                              IconButton(
                                                tooltip: '上一集',
                                                onPressed: c.currentIndex > 0
                                                    ? () => c.onSelectEpisode(
                                                        c.currentIndex - 1,
                                                      )
                                                    : null,
                                                icon: const Icon(
                                                  Icons.skip_previous,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '快退 10 秒',
                                                onPressed: _ready
                                                    ? () => _seek(
                                                        position -
                                                            const Duration(
                                                              seconds: 10,
                                                            ),
                                                      )
                                                    : null,
                                                icon: const Icon(
                                                  Icons.replay_10,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '播放 / 暂停（空格）',
                                                onPressed: _ready
                                                    ? _toggle
                                                    : null,
                                                icon: Icon(
                                                  c.playing
                                                      ? Icons.pause
                                                      : Icons.play_arrow,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '快进 10 秒',
                                                onPressed: _ready
                                                    ? () => _seek(
                                                        position +
                                                            const Duration(
                                                              seconds: 10,
                                                            ),
                                                      )
                                                    : null,
                                                icon: const Icon(
                                                  Icons.forward_10,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '下一集',
                                                onPressed:
                                                    c.currentIndex + 1 <
                                                        c.episodes.length
                                                    ? () => c.onSelectEpisode(
                                                        c.currentIndex + 1,
                                                      )
                                                    : null,
                                                icon: const Icon(
                                                  Icons.skip_next,
                                                ),
                                              ),
                                              const Spacer(),
                                              if (c.onToggleDanmaku != null)
                                                IconButton(
                                                  tooltip: '弹幕',
                                                  onPressed: c.onToggleDanmaku,
                                                  icon: Icon(
                                                    c.danmakuEnabled
                                                        ? Icons.subtitles
                                                        : Icons.subtitles_off,
                                                  ),
                                                ),
                                              if (c.onDanmakuSettingsChanged !=
                                                  null)
                                                IconButton(
                                                  tooltip: '弹幕设置',
                                                  onPressed: () => showDialog<void>(
                                                    context: context,
                                                    builder: (_) => Dialog(
                                                      child: SizedBox(
                                                        width: 420,
                                                        child: PlayletDanmakuSettingsPanel(
                                                          settings:
                                                              c.danmakuSettings,
                                                          landscape: true,
                                                          onChanged: c
                                                              .onDanmakuSettingsChanged,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  icon: const Icon(Icons.tune),
                                                ),
                                              PopupMenuButton<double>(
                                                tooltip: '倍速',
                                                initialValue: _rate,
                                                onSelected: (v) {
                                                  setState(() => _rate = v);
                                                  unawaited(
                                                    widget.onRateSelected(v),
                                                  );
                                                },
                                                itemBuilder: (_) => [
                                                  for (final rate
                                                      in PlayerPreferences
                                                          .playbackRates)
                                                    PopupMenuItem(
                                                      value: rate,
                                                      child: Text('${rate}x'),
                                                    ),
                                                ],
                                                child: Padding(
                                                  padding: const EdgeInsets.all(
                                                    8,
                                                  ),
                                                  child: Text('${_rate}x'),
                                                ),
                                              ),
                                              if (c
                                                      .qualityVariants
                                                      .isNotEmpty &&
                                                  c.onQualitySelected != null)
                                                PopupMenuButton<int>(
                                                  tooltip: '清晰度',
                                                  onSelected: (i) =>
                                                      c.onQualitySelected!(
                                                        c.qualityVariants[i],
                                                      ),
                                                  itemBuilder: (_) => [
                                                    for (
                                                      var i = 0;
                                                      i <
                                                          c
                                                              .qualityVariants
                                                              .length;
                                                      i++
                                                    )
                                                      PopupMenuItem(
                                                        value: i,
                                                        child: Text(
                                                          c
                                                              .qualityVariants[i]
                                                              .name,
                                                        ),
                                                      ),
                                                  ],
                                                  child: const Padding(
                                                    padding: EdgeInsets.all(8),
                                                    child: Text('清晰度'),
                                                  ),
                                                ),
                                              IconButton(
                                                tooltip: '静音',
                                                onPressed: () {
                                                  setState(
                                                    () => _volume = _volume == 0
                                                        ? 1
                                                        : 0,
                                                  );
                                                  unawaited(
                                                    _applyVolume(_volume) ??
                                                        Future<void>.value(),
                                                  );
                                                },
                                                icon: Icon(
                                                  _volume == 0
                                                      ? Icons.volume_off
                                                      : Icons.volume_up,
                                                ),
                                              ),
                                              if (constraints.maxWidth >= 900)
                                                SizedBox(
                                                  width: 82,
                                                  child: Slider(
                                                    value: _volume,
                                                    onChanged: (v) {
                                                      setState(
                                                        () => _volume = v,
                                                      );
                                                      unawaited(
                                                        _applyVolume(v) ??
                                                            Future<
                                                              void
                                                            >.value(),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              IconButton(
                                                tooltip: '选集',
                                                onPressed: _showCatalog,
                                                icon: const Icon(
                                                  Icons.playlist_play,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '全屏（F / Esc）',
                                                onPressed: _full,
                                                icon: Icon(
                                                  full
                                                      ? Icons.fullscreen_exit
                                                      : Icons.fullscreen,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (docked) _catalog(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
