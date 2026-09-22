import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/audio_extra.dart';
import '../models/media_item.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/player_preferences.dart';
import 'player/player_cover.dart';
import 'player/player_video_layout.dart';
import 'player/story_player_panel.dart';
import 'player/story_seek_bar.dart';

class VideoPlayerChrome extends StatefulWidget {
  final NativePlayer? player;
  final String title;
  final List<Chapter> episodes;
  final int currentIndex;
  final int? playingIndex;
  final Duration duration;
  final bool playing;
  final bool enabled;
  final Widget child;
  final String coverUrl;
  final ValueChanged<bool>? onPagingChanged;
  final Future<void> Function(int) onSelectEpisode;
  final void Function(Object) onError;

  /// 已看集（选集面板灰字 `#66000000`，官方 `hj3/r0.java:224-235` 观看历史
  /// 的本地等价：续播点之前的集 + 本次会话播过的集，由宿主维护）。
  final Set<int> watchedEpisodes;

  /// 官方短剧播放页形态（`apf.xml` + `VideoGestureDetectLayout`）：竖屏没有
  /// 通用播放器的运输条（上一集/±10/暂停/下一集），暂停入口是单击画面
  /// （feed 卡同款）；横屏是官方底条（`c0i` 控制行 + `cw7` 进度块，见
  /// `_landscapeBar`）。详情页的电影/电视剧仍走通用形态（默认 false）。
  final bool shortSeries;

  /// 官方播放页右侧竖栏（`rightview` 家族，与 feed 卡同款 46dp 图标 +
  /// 12sp 文案）：星=追剧、心=点赞。追剧文案由宿主给（有 `followed_cnt`
  /// 时是 formatCounter 后的计数，无则「追剧/已追剧」）；评论/分享需要
  /// 账号或分享链路，不显示（官方也是默认 gone）。
  final String? followerLabel;
  final VoidCallback? onFollow;
  final VoidCallback? onLike;

  /// 「作者声明：内容由AI生成」行（`video_detail.ai_usage_type`）。
  final bool aiGenerated;

  /// 「左右滑动可调整进度」首次引导（`@string/cha`，引导层距底 138dp，
  /// `of3/a.java`）。显示与否由宿主决定（每台设备一次）。
  final bool showSeekHint;
  final VoidCallback? onSeekHintConsumed;

  /// 底部 band 的两块服务端装饰（官方截图第二十二轮）：完结状态
  /// （「选集 · 已完结 · 全82集」胶囊，`@string/ag_`/`e6r`）与
  /// 原著书卡（「原著《…》」，`/related` 的 book 关联）。缺省就不显示。
  final String? seriesStatus;
  final RelatedWork? originalBook;
  final VoidCallback? onOpenOriginalBook;

  const VideoPlayerChrome({
    super.key,
    required this.player,
    this.title = '',
    required this.episodes,
    required this.currentIndex,
    this.playingIndex,
    required this.duration,
    required this.playing,
    this.enabled = true,
    required this.child,
    this.coverUrl = '',
    this.watchedEpisodes = const <int>{},
    this.onPagingChanged,
    required this.onSelectEpisode,
    required this.onError,
    this.shortSeries = false,
    this.followerLabel,
    this.onFollow,
    this.onLike,
    this.aiGenerated = false,
    this.showSeekHint = false,
    this.onSeekHintConsumed,
    this.seriesStatus,
    this.originalBook,
    this.onOpenOriginalBook,
  });

  @override
  State<VideoPlayerChrome> createState() => _VideoPlayerChromeState();
}

class _VideoPlayerChromeState extends State<VideoPlayerChrome>
    with WidgetsBindingObserver {
  late final PageController _pages;
  final _panel = DraggableScrollableController();
  final _panelExtent = ValueNotifier<double>(0);
  final _position = ValueNotifier<Duration>(Duration.zero);
  final _seekValue = ValueNotifier<double?>(null);

  /// Latest target of a relative +/-10s seek whose native call has not settled
  /// yet; back-to-back taps accumulate onto it instead of reusing the last
  /// acknowledged position.
  Duration? _pendingSeek;
  late final _timeline = Listenable.merge([_position, _seekValue]);
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playWhenReadySubscription;
  Timer? _hideTimer;
  bool _visible = true;
  bool _seeking = false;
  bool _resumeAfterSeek = false;
  bool _modalOpen = false;
  bool _panelOpen = false;

  /// 面板形态：横屏（短剧全屏）走右侧深色抽屉（`StoryEpisodeDrawer`，
  /// 官方截图第二十三轮），竖屏走白色 bottom sheet（`StoryPlayerPanel`）。
  bool _panelDrawer = false;
  bool _panelDrawerClosing = false;
  Timer? _panelDrawerTimer;
  bool _panelAnimating = false;
  bool _panelWasVisible = false;
  bool _panelHeaderDragging = false;
  bool _fullScreen = false;

  /// 清屏（持久沉浸）：点右下角「清屏」后隐藏全部浮层，只留右下角文字行
  /// 的「恢复」出口；再点「恢复」回到正常态。官方 `o.java:1860-1884 H1()`
  /// 翻转清屏态、清屏时遮罩 `setVisibility(4)`（`SingleVideoHolder.java:
  /// 1245-1247,1193-1210`），是运行时状态、不持久化。
  bool _clearScreen = false;
  bool _boosting = false;
  bool _paging = false;
  bool _appActive = true;
  bool _resumeOnForeground = false;
  int _panelAnimation = 0;
  int _interaction = 0;
  double _panelRestFraction = .55;
  double _panelMaxFraction = .55;
  List<double> _panelSnapSizes = const [.55];
  double _rate = 1;
  int _rateGeneration = 0;
  Future<void> _systemUiUpdates = Future<void>.value();
  bool _systemUiTouched = false;

  /// 横滑调进度的起手位置与激活状态。null = 没有进行中的横滑；
  /// `_dragSeekActive` = 已证明是横向主导的拖动（见 [_updateDragSeek]）。
  Offset? _dragSeekOrigin;
  bool _dragSeekActive = false;

  /// The orientation list currently pinned while fullscreen, so an unchanged
  /// answer does not re-issue a rotation request.
  List<DeviceOrientation>? _appliedOrientations;

  /// The video size [appliedOrientations] was decided from. The player mutates
  /// its own size when the media loads, so comparing widget generations would
  /// read the new value on both sides and never notice the change.
  Size _appliedVideoSize = Size.zero;

  double get _panelFraction => _panelExtent.value;

  /// 遮罩/淡入强度：面板相对静止档的展开比例（0 关 → 1 全开）。
  double get _panelStrength =>
      (_panelFraction / math.max(_panelRestFraction, .01)).clamp(0.0, 1.0);
  double get _progressValue {
    final durationMs = math.max(0, widget.duration.inMilliseconds);
    return _seekValue.value ??
        (durationMs > 0
            ? _position.value.inMilliseconds.clamp(0, durationMs) / durationMs
            : 0.0);
  }

  bool get _ready => widget.enabled && (widget.player?.isCreated ?? false);
  bool get _playbackRequested =>
      widget.playing ||
      ((widget.player?.playWhenReady ?? false) &&
          !(widget.player?.completed ?? false));
  Size get _videoSize => Size(
    (widget.player?.videoWidth ?? 9).toDouble(),
    (widget.player?.videoHeight ?? 16).toDouble(),
  );
  String get _episodeTitle => widget.episodes.isEmpty
      ? '暂无剧集'
      : widget.episodes[widget.currentIndex].title;
  String get _seriesTitle =>
      widget.title.isEmpty ? _episodeTitle : widget.title;

  @override
  void initState() {
    super.initState();
    _pages = PageController(initialPage: widget.currentIndex);
    _panel.addListener(_panelChanged);
    _listenToPosition();
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    unawaited(_loadRate());
    _scheduleHide();
  }

  @override
  void didUpdateWidget(VideoPlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) _listenToPosition();
    if (oldWidget.player != widget.player ||
        oldWidget.enabled && !widget.enabled) {
      if (_boosting && oldWidget.player != null) {
        unawaited(oldWidget.player!.setRate(_rate).catchError((Object _) {}));
      }
      ++_interaction;
      _seeking = false;
      _seekValue.value = null;
      _resumeAfterSeek = false;
      _resumeOnForeground = false;
      _boosting = false;
    }
    if (_ready && (oldWidget.player != widget.player || !oldWidget.enabled)) {
      unawaited(_control((player) => player.setRate(_rate)));
      if (_fullScreen) unawaited(_applySystemUi());
    }
    if (oldWidget.currentIndex != widget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pages.hasClients) return;
        if ((_pages.page ?? 0).round() != widget.currentIndex) {
          _pages.jumpToPage(widget.currentIndex);
        }
      });
    }
    // The video size arrives a moment after a player is created, so this is
    // where a fullscreen episode learns whether it is landscape. The check is
    // size-based because the player mutates its own size in place.
    _adoptVideoOrientation();
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
    _pages.dispose();
    _panel.dispose();
    _panelExtent.dispose();
    unawaited(_positionSubscription?.cancel());
    unawaited(_playWhenReadySubscription?.cancel());
    _position.dispose();
    _seekValue.dispose();
    if (_boosting && widget.player != null) {
      unawaited(widget.player!.setRate(_rate).catchError((Object _) {}));
    }
    if (_systemUiTouched) {
      unawaited(_systemUiUpdates.then((_) => _restoreSystemUi()));
    }
    super.dispose();
  }

  void _listenToPosition() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_playWhenReadySubscription?.cancel());
    final player = widget.player;
    _pendingSeek = null;
    _position.value = player?.position ?? Duration.zero;
    // The native 200ms ticks belong to the timeline only. In particular, they
    // must not rebuild the episode pager, description or the video texture.
    _positionSubscription = player?.positionStream.listen((position) {
      if (mounted && identical(widget.player, player)) {
        _position.value = position;
      }
    });
    _playWhenReadySubscription = player?.playWhenReadyStream.listen((_) {
      if (mounted && identical(widget.player, player)) setState(() {});
    });
  }

  Future<void> _loadRate() async {
    final generation = _rateGeneration;
    try {
      final rate = await PlayerPreferences.loadPlaybackRate();
      if (!mounted || generation != _rateGeneration) return;
      setState(() => _rate = rate);
      await _control((player) => player.setRate(_boosting ? 2 : rate));
    } catch (_) {}
  }

  Future<void> _control(Future<void> Function(NativePlayer) operation) async {
    final player = widget.player;
    if (player == null || !_ready) return;
    try {
      await operation(player);
    } catch (error) {
      if (mounted && widget.player == player && _ready) widget.onError(error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (!active && _appActive) {
      _appActive = false;
      ++_interaction;
      _resumeOnForeground =
          _ready && (_playbackRequested || (_seeking && _resumeAfterSeek));
      _cancelSeek(resume: false);
      _endBoost();
      _hideTimer?.cancel();
      unawaited(_control((player) => player.pause()));
    } else if (active && !_appActive) {
      _appActive = true;
      if (_resumeOnForeground) unawaited(_control((player) => player.play()));
      _resumeOnForeground = false;
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_ready ||
        !_appActive ||
        !widget.playing ||
        _seeking ||
        _modalOpen ||
        _panelOpen ||
        _boosting ||
        _paging) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _toggleControls() {
    // 清屏态下单击不再唤回浮层（官方清屏时遮罩 `setVisibility(4)`），
    // 出口只有右下角的「恢复」。
    if (_clearScreen) return;
    if (_panelOpen || _modalOpen || _seeking || _boosting || _paging) return;
    setState(() => _visible = !_visible);
    if (_visible) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  /// 清屏/恢复（官方 `SingleVideoHolder.java:1140-1210` → `o.java:1860-1884`）：
  /// 清屏=隐藏全部浮层与遮罩、只留右下角文字行；恢复=回到正常态并重新计时
  /// 自动隐藏。运行时状态，不持久化。
  void _setClearScreen(bool clear) {
    _endBoost();
    _cancelSeek();
    ++_interaction;
    _hideTimer?.cancel();
    setState(() {
      _clearScreen = clear;
      _visible = true;
    });
    if (!clear) _scheduleHide();
  }

  /// 横滑调进度：与 feed 卡同一条官方规则——把横向拖动位置映射到整集
  /// 时间轴（feed 的 `_CardGestures` 与播放页引导层 `o.java K6` 同源）。
  /// 拖动中实时 seek（feed 亦如此），不进入进度条的 `_seeking` 暂停语义。
  ///
  /// start 只记起点不 seek：竖直翻页不可用时（横屏、面板打开等），单击/
  /// 长按识别器会因移动放弃，竞技场可能把**纯竖直滑动**判给水平识别器
  /// （未达横向阈值也会判胜，`onlyAcceptDragOnThreshold` 默认 false）。
  /// 是否真是横滑由 [_updateDragSeek] 用横向主导的位移判定。
  void _startDragSeek(DragStartDetails details) {
    if (!_ready ||
        _panelOpen ||
        _modalOpen ||
        _seeking ||
        widget.duration <= Duration.zero) {
      return;
    }
    _endBoost();
    ++_interaction;
    _hideTimer?.cancel();
    _dragSeekOrigin = details.localPosition;
    _dragSeekActive = false;
  }

  void _updateDragSeek(DragUpdateDetails details) {
    final origin = _dragSeekOrigin;
    if (origin == null) return;
    final dx = details.localPosition.dx - origin.dx;
    final dy = details.localPosition.dy - origin.dy;
    if (!_dragSeekActive) {
      if (dx.abs() < kTouchSlop || dx.abs() < dy.abs()) return;
      _dragSeekActive = true;
      widget.onSeekHintConsumed?.call();
    }
    final fraction = _dragFraction(details.localPosition.dx);
    _seekValue.value = fraction;
    unawaited(
      _control(
        (player) => player.seek(
          Duration(
            milliseconds: (widget.duration.inMilliseconds * fraction).round(),
          ),
        ),
      ),
    );
  }

  void _endDragSeek(DragEndDetails details) {
    _dragSeekOrigin = null;
    if (!_dragSeekActive) return;
    _dragSeekActive = false;
    final fraction = _dragFraction(
      // DragEnd 没有位置；沿用最后一次 update 的预览值。
      _seekValue.value == null
          ? 0
          : (_seekValue.value! * MediaQuery.sizeOf(context).width),
    );
    unawaited(
      () async {
        await _control(
          (player) => player.seek(
            Duration(
              milliseconds: (widget.duration.inMilliseconds * fraction)
                  .round(),
            ),
          ),
        );
        if (mounted && !_seeking) _seekValue.value = null;
      }(),
    );
    if (widget.showSeekHint) widget.onSeekHintConsumed?.call();
  }

  double _dragFraction(double dx) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return 0;
    return (dx / width).clamp(0.0, 1.0);
  }

  void _togglePlayback() {    if (!_ready ||
        !_appActive ||
        _panelOpen ||
        _modalOpen ||
        _seeking ||
        _paging) {
      return;
    }
    _endBoost();
    final interaction = ++_interaction;
    final pause = _playbackRequested;
    unawaited(
      _control((player) async {
        if (pause) {
          await player.pause();
        } else {
          if (player.completed) await player.seek(Duration.zero);
          if (!mounted ||
              widget.player != player ||
              interaction != _interaction ||
              !_appActive ||
              !_ready) {
            return;
          }
          await player.play();
        }
      }),
    );
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _startSeek(double value) {
    if (!_ready) return;
    _endBoost();
    ++_interaction;
    _hideTimer?.cancel();
    _resumeAfterSeek = _playbackRequested;
    setState(() {
      _seeking = true;
      _seekValue.value = value;
    });
    unawaited(_control((player) => player.pause()));
  }

  Future<void> _finishSeek(double value) async {
    final player = widget.player;
    if (player == null || !_seeking) return;
    final interaction = _interaction;
    final target = Duration(
      milliseconds: (widget.duration.inMilliseconds * value.clamp(0.0, 1.0))
          .round(),
    );
    try {
      await player.seek(target);
      if (!mounted || widget.player != player || interaction != _interaction) {
        return;
      }
      if (_resumeAfterSeek && _appActive && _ready) await player.play();
    } catch (error) {
      if (mounted && widget.player == player && interaction == _interaction) {
        widget.onError(error);
      }
    } finally {
      if (mounted && widget.player == player && interaction == _interaction) {
        setState(() {
          _seeking = false;
          _seekValue.value = null;
        });
        _scheduleHide();
      }
    }
  }

  void _cancelSeek({bool resume = true}) {
    if (!_seeking) return;
    ++_interaction;
    final shouldResume = resume && _resumeAfterSeek && _appActive;
    setState(() {
      _seeking = false;
      _seekValue.value = null;
    });
    if (shouldResume) unawaited(_control((player) => player.play()));
    _scheduleHide();
  }

  void _seekBy(int seconds) {
    final base = _pendingSeek ?? _position.value;
    final milliseconds = (base.inMilliseconds + seconds * 1000).clamp(
      0,
      math.max(0, widget.duration.inMilliseconds),
    );
    final target = Duration(milliseconds: milliseconds.toInt());
    // Remember the optimistic target before awaiting the native seek so the
    // next relative tap accumulates on top of it.
    _pendingSeek = target;
    unawaited(
      _control((player) async {
        try {
          await player.seek(target);
        } finally {
          if (identical(widget.player, player) && _pendingSeek == target) {
            _pendingSeek = null;
          }
        }
      }),
    );
    _scheduleHide();
  }

  void _startBoost() {
    if (!_ready ||
        !widget.playing ||
        _seeking ||
        _paging ||
        _panelOpen ||
        _modalOpen) {
      return;
    }
    _hideTimer?.cancel();
    setState(() => _boosting = true);
    unawaited(_control((player) => player.setRate(2)));
  }

  void _endBoost() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    unawaited(_control((player) => player.setRate(_rate)));
    _scheduleHide();
  }

  /// 官方 ⋮ 更多面板（`ShortSeriesMorePanelDialogV2`，布局 `aae.xml`：顶部
  /// 圆角 16dp、底 `@color/aae`=#fffafafa、拖拽把手、无行分隔；倍速行是
  /// 行内档位 `b72/b74.xml` + `ScrollableMultipleOptionsView`，档位文案
  /// `0.75x/1x/1.25x/1.5x/1.75x/2x`）。
  ///
  /// 官方面板的其余行（清晰度/小窗/默认静音/画面撑满/一键发评/弹幕/投屏…）
  /// 都要服务端下发或账号链路，本仓库一律不显示占位（诚实清单，见对照
  /// 文档 §27）。
  Future<void> _showRates() async {
    if (_modalOpen) return;
    _endBoost();
    _cancelSeek();
    _hideTimer?.cancel();
    setState(() => _modalOpen = true);
    final selected = await showModalBottomSheet<double>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFFFAFAFA),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Row(
            key: const ValueKey('player-more-rate-row'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  '倍速',
                  style: TextStyle(fontSize: 14, color: Color(0xFF1B1B1B)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final rate in PlayerPreferences.playbackRates)
                      ChoiceChip(
                        label: Text(_rateChipLabel(rate)),
                        selected: rate == _rate,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        onSelected: (_) => Navigator.pop(context, rate),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _modalOpen = false);
    if (selected != null) {
      final generation = ++_rateGeneration;
      setState(() => _rate = selected);
      try {
        // Persist in selection order. A slow reply to an older native rate
        // change must not save that value after the user's newer selection.
        await Future.wait<void>([
          PlayerPreferences.savePlaybackRate(selected),
          _control((player) => player.setRate(selected)),
        ]);
      } catch (_) {
        if (mounted && generation == _rateGeneration) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('倍速已生效，但未能保存设置')));
        }
      }
    }
    if (mounted) _scheduleHide();
  }

  void _openPanel() {
    _endBoost();
    _cancelSeek();
    _hideTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    final size = MediaQuery.sizeOf(context);
    setState(() {
      _panelDrawer = widget.shortSeries && _fullScreen && size.width > size.height;
      _panelDrawerClosing = false;
      _panelRestFraction = PlayerVideoLayout.panelFractionFor(_videoSize);
      _panelMaxFraction = _panelRestFraction;
      // Keep this list stable while the panel follows a drag. Replacing it
      // makes DraggableScrollableSheet start a new snap on every rebuild.
      _panelSnapSizes = [_panelRestFraction];
      _panelOpen = true;
      _panelWasVisible = false;
      _panelHeaderDragging = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panelOpen) unawaited(_animatePanel(_panelRestFraction));
    });
  }

  /// 关面板：抽屉态走 200ms 退场动画后摘除；sheet 态走 extent 动画。
  Future<void> _closePanel() async {
    if (!_panelDrawer) {
      await _animatePanel(0);
      return;
    }
    if (_panelDrawerClosing) return;
    setState(() => _panelDrawerClosing = true);
    _panelDrawerTimer?.cancel();
    _panelDrawerTimer = Timer(const Duration(milliseconds: 220), () {
      _panelDrawerClosing = false;
      if (mounted) _removePanel();
    });
  }

  void _panelChanged() {
    if (!mounted || !_panel.isAttached) return;
    _panelExtent.value = _panel.size;
    if (_panelFraction > .01) _panelWasVisible = true;
    if (_panelFraction <= .001 && _panelWasVisible && !_panelAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _panelFraction <= .001 && !_panelAnimating) {
          _removePanel();
        }
      });
    }
  }

  Future<void> _animatePanel(double target) async {
    if (!_panel.isAttached) return;
    final animation = ++_panelAnimation;
    _panelAnimating = true;
    if (target > _panelMaxFraction) {
      setState(() => _panelMaxFraction = 1);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || animation != _panelAnimation || !_panel.isAttached) {
        return;
      }
    }
    await _panel.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || animation != _panelAnimation) return;
    _panelAnimating = false;
    if (target == 0) {
      _removePanel();
    } else if (target == _panelRestFraction) {
      setState(() => _panelMaxFraction = _panelRestFraction);
    }
  }

  bool _onPanelScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // A body drag can cancel the controller's animation future. Invalidate
      // its completion so a later drag-to-close can still remove the panel.
      ++_panelAnimation;
      _panelAnimating = false;
    } else if (notification is ScrollEndNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_panelOpen ||
            _panelAnimating ||
            _panelHeaderDragging) {
          return;
        }
        if ((_panelFraction - _panelRestFraction).abs() < .001 &&
            _panelMaxFraction != _panelRestFraction) {
          setState(() => _panelMaxFraction = _panelRestFraction);
        }
      });
    }
    return false;
  }

  void _removePanel() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _panelOpen = false;
      _panelExtent.value = 0;
      _panelWasVisible = false;
      _panelHeaderDragging = false;
      _visible = true;
    });
    _scheduleHide();
  }

  void _startPanelDrag(DragStartDetails details) {
    ++_panelAnimation;
    _panelAnimating = false;
    _panelHeaderDragging = true;
    // Like the reference's drag area, only the header unlocks expansion above
    // the resting height. Scrolling the body keeps the video visible.
    setState(() => _panelMaxFraction = 1);
  }

  void _dragPanel(DragUpdateDetails details, double height) {
    if (!_panel.isAttached || height <= 0) return;
    ++_panelAnimation;
    _panelAnimating = false;
    _panel.jumpTo((_panel.size - details.delta.dy / height).clamp(0.0, 1.0));
  }

  void _endPanelDrag(DragEndDetails details) {
    if (!_panelHeaderDragging) return;
    _panelHeaderDragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final size = _panelFraction;
    final rest = _panelRestFraction;
    final target = velocity > 600
        ? (size > rest + .1 ? rest : 0.0)
        : velocity < -600
        ? (size < rest - .1 ? rest : 1.0)
        : size < rest / 2
        ? 0.0
        : size < (rest + 1) / 2
        ? rest
        : 1.0;
    unawaited(_animatePanel(target));
  }

  Future<void> _selectEpisode(int index) async {
    if (index < 0 ||
        index >= widget.episodes.length ||
        index == widget.currentIndex) {
      return;
    }
    _endBoost();
    _cancelSeek(resume: false);
    await widget.onSelectEpisode(index);
    if (mounted) _scheduleHide();
  }

  Future<void> _back() async {
    if (_panelOpen) {
      await _closePanel();
    } else if (_fullScreen) {
      await _toggleFullScreen();
    } else {
      await Navigator.maybePop(context);
    }
  }

  Future<void> _toggleFullScreen() async {
    _endBoost();
    _cancelSeek();
    setState(() => _fullScreen = !_fullScreen);
    await _applySystemUi();
    if (mounted) _scheduleHide();
  }

  Future<void> _applySystemUi() async {
    _systemUiTouched = true;
    final fullScreen = _fullScreen;
    final operation = _systemUiUpdates.then((_) async {
      if (!mounted || _fullScreen != fullScreen) return;
      if (fullScreen) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        final orientations = _orientationsForVideo;
        // A freshly created player reports no video size, so the orientation is
        // unknown rather than portrait. Deciding "0 > 0 is false, therefore
        // portrait" is what snapped landscape playback back to portrait every
        // time the next episode auto-played. With no answer, leave the device in
        // the orientation the viewer already chose; [_adoptVideoOrientation]
        // applies the real one once the size arrives.
        _appliedOrientations = orientations;
        _appliedVideoSize = _playerVideoSize;
        if (orientations == null) return;
        await SystemChrome.setPreferredOrientations(orientations);
      } else {
        _appliedOrientations = null;
        _appliedVideoSize = Size.zero;
        await _restoreSystemUi();
      }
    });
    _systemUiUpdates = operation.catchError((Object _) {});
    await _systemUiUpdates;
  }

  /// The player's reported video size; 0x0 until the media has loaded.
  Size get _playerVideoSize => Size(
    (widget.player?.videoWidth ?? 0).toDouble(),
    (widget.player?.videoHeight ?? 0).toDouble(),
  );

  /// The orientations fullscreen should use, or null while the video size is
  /// still unknown (a new player starts at 0x0).
  ///
  /// Note: 未知尺寸不得判成竖屏，否则连播会把横屏掰回竖屏 — 见
  /// .agents/notes/implemented/bug-fix/2026-09-11-player-orientation-on-auto-advance.md
  List<DeviceOrientation>? get _orientationsForVideo {
    final size = _playerVideoSize;
    if (size.width <= 0 || size.height <= 0) return null;
    return size.width > size.height
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];
  }

  /// Applies the video's orientation once its size is known.
  ///
  /// Called from [didUpdateWidget], which runs on the rebuild the size event
  /// triggers. Without it a fullscreen episode would keep whatever orientation
  /// was in effect while its size was still unknown.
  void _adoptVideoOrientation() {
    if (!_fullScreen) return;
    final orientations = _orientationsForVideo;
    if (orientations == null) return;
    if (_playerVideoSize == _appliedVideoSize &&
        listEquals(orientations, _appliedOrientations)) {
      return;
    }
    unawaited(_applySystemUi());
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_panelOpen && !_fullScreen,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && (_panelOpen || _fullScreen)) unawaited(_back());
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final insets = MediaQuery.paddingOf(context);
          final window = constraints.biggest;
          final landscape = _fullScreen && window.width > window.height;
          final layout = PlayerVideoLayout.calculate(
            window: window,
            insets: insets,
            videoSize: _videoSize,
            fit: VideoFit.contain,
            panelFraction: _panelFraction,
            restingPanelFraction: _panelRestFraction,
            fullScreen: _fullScreen,
          );
          final durationMs = math.max(0, widget.duration.inMilliseconds);
          final unobstructed = !_panelOpen && !_modalOpen;
          final controls =
              _visible && unobstructed && !_seeking && !_clearScreen;
          // 短剧竖屏没有运输条，单击就是暂停/恢复（feed 卡同款）；不注册
          // 双击——快速双击等价两次单击，回到原播放状态。
          final tapTogglesPlayback = widget.shortSeries && !landscape;
          final canPage =
              unobstructed && !_seeking && !_boosting && !landscape;
          // 短剧横屏底条（批次四）：官方 `c0i.xml` + `cw7.xml` 的形态，
          // 替换通用运输条在此朝向的全部残留（prev/±10/全屏钮）。
          final landscapeBar = widget.shortSeries && landscape;
          // 常驻 band（官方截图第二十二轮）：控制条自动收起后，信息层
          // （剧名/原著卡）、贴底进度条与选集胶囊仍然常驻——官方截图里
          // 无顶栏/右栏/全屏 pill/倍速清屏行，只有这三层。
          final bandVisible =
              widget.shortSeries && !landscape && _ready && !_visible;
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                key: const ValueKey('video-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: tapTogglesPlayback ? _togglePlayback : _toggleControls,
                onDoubleTap: tapTogglesPlayback ? null : _togglePlayback,
                onHorizontalDragStart: _startDragSeek,
                onHorizontalDragUpdate: _updateDragSeek,
                onHorizontalDragEnd: _endDragSeek,
                onLongPressStart: (_) => _startBoost(),
                onLongPressEnd: (_) => _endBoost(),
                onLongPressCancel: _endBoost,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth != 0) return false;
                    if (notification is ScrollStartNotification) {
                      _paging = true;
                      _hideTimer?.cancel();
                      widget.onPagingChanged?.call(true);
                    } else if (notification is ScrollEndNotification) {
                      _paging = false;
                      widget.onPagingChanged?.call(false);
                      _scheduleHide();
                    }
                    return false;
                  },
                  child: PageView.builder(
                    key: const ValueKey('episode-pager'),
                    controller: _pages,
                    scrollDirection: Axis.vertical,
                    physics: canPage
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    itemCount: math.max(1, widget.episodes.length),
                    onPageChanged: (index) => unawaited(_selectEpisode(index)),
                    itemBuilder: (context, index) => Stack(
                      key: ValueKey('episode-page-$index'),
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        if (index == widget.currentIndex)
                          _positionVideo(
                            window: window,
                            insets: insets,
                            fitVideo: _ready,
                            child: SizedBox(
                              key: const ValueKey('video-frame'),
                              child: widget.child,
                            ),
                          )
                        else
                          _positionVideo(
                            window: window,
                            insets: insets,
                            child: PlayerCover(
                              url: widget.coverUrl,
                              label: widget.episodes[index].title,
                            ),
                          ),
                      ],
                    ),
                  ),
                  ),
                ),
              // 「左右滑动可调整进度」首次引导（`@string/cha`，距底 138dp，
              // `o.java K6` 的引导层）。
              if (widget.showSeekHint && !_panelOpen)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: insets.bottom + 138,
                  child: IgnorePointer(
                    child: Center(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0xCC222222),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(
                                Icons.swap_horiz,
                                size: 16,
                                color: Colors.white,
                              ),
                              SizedBox(width: 4),
                              Text(
                                '左右滑动可调整进度',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (controls) ...[
                _topBar(insets, landscape: landscape),
                if (!landscape) _rightBar(insets),
              ],
              // 信息层/选集胶囊压在进度条与画面之上，但必须保持transport在
              // 其上方（Stack 后者在上）：通用播放器的运输条按钮不能被信息
              // 层的渐变 Container 挡住点击。
              if (!landscape && (controls || bandVisible)) ...[
                _information(insets, showPill: controls, showBook: bandVisible),
                _catalogBar(insets, compact: bandVisible),
              ],
              if (bandVisible) _clearScreenButton(insets),
              // 官方播放页（`apf.xml`）竖屏没有运输条；运输条只剩通用
              // 播放器（详情页影视）在用，短剧两个朝向都不走它。
              if (controls && _ready && !widget.shortSeries)
                _transport(insets, landscape),
              if (landscapeBar &&
                  _ready &&
                  unobstructed &&
                  !_clearScreen &&
                  (_visible || _seeking))
                _landscapeBar(insets),
              // 官方那条右下角文字行只属于短剧播放页（`SingleVideoHolder`
              // 家族）；通用播放器（详情页影视）保留运输条，不需要它，也避免
              // 与运输条右端的「下一集」抢点击。竖屏清屏时它是唯一出口。
              if (widget.shortSeries &&
                  !landscape &&
                  (controls || _clearScreen))
                Positioned(
                  right: insets.right + 16,
                  bottom: insets.bottom + 88,
                  child: _screenTexts(),
                ),
              if ((_visible || _seeking || bandVisible) &&
                  unobstructed &&
                  _ready &&
                  !_clearScreen &&
                  !landscapeBar)
                Positioned(
                  // Controls leave this Stack while seeking. Keep the outer
                  // layer keyed so the active drag recognizer survives that
                  // sibling change until the finger is released.
                  key: const ValueKey('video-seek-layer'),
                  left: insets.left + 12,
                  right: insets.right + 12,
                  bottom: insets.bottom + 60,
                  child: RepaintBoundary(
                    child: ListenableBuilder(
                      listenable: _timeline,
                      builder: (context, child) => StorySeekBar(
                        key: const ValueKey('video-seek'),
                        value: _progressValue,
                        enabled: durationMs > 0,
                        seeking: _seeking,
                        onStart: _startSeek,
                        onChanged: (value) => _seekValue.value = value,
                        onEnd: (value) => unawaited(_finishSeek(value)),
                        onCancel: _cancelSeek,
                        progressColor: widget.shortSeries
                            ? const Color(0xFFFA6725)
                            : Colors.white,
                        trackColor: widget.shortSeries
                            ? const Color(0x4DFFFFFF)
                            : Colors.white24,
                      ),
                    ),
                  ),
                ),
              // 暂停态只留官方截图里的半透明大三角（第十七轮对齐）；原先
              // 三角下的「00:00 / 05:03」时间文字是通用播放器遗产——官方
              // 布局里没有任何暂停浮层的时间文字（`apktool/res/layout/cjc.xml`
              // 只有铺满的进度/手势/空注入容器），已删（对照文档 §27）。
              if (_ready &&
                  !_playbackRequested &&
                  unobstructed &&
                  _visible &&
                  !_seeking)
                Positioned.fromRect(
                  rect: layout.viewport,
                  child: IgnorePointer(
                    child: Center(
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 86,
                        color: Colors.white.withValues(alpha: .2),
                      ),
                    ),
                  ),
                ),
              if (_seeking)
                Center(
                  child: IgnorePointer(
                    child: ListenableBuilder(
                      listenable: _timeline,
                      builder: (context, child) => Text(
                        '${_time(Duration(milliseconds: (durationMs * _progressValue).round()))} / ${_time(widget.duration)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          shadows: [Shadow(blurRadius: 8)],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_boosting)
                Positioned(
                  top: insets.top + 56,
                  left: 0,
                  right: 0,
                  child: const Center(
                    child: IgnorePointer(child: Chip(label: Text('2× 加速中'))),
                  ),
                ),
              if (_panelOpen && _panelDrawer) ...[
                // 横屏右侧抽屉（官方截图第二十三轮）：200ms 滑入滑出 +
                // 0.5 遮罩，点遮罩/✕/返回键关闭。
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _panelDrawerClosing ? 0.0 : 1.0),
                    duration: const Duration(milliseconds: 200),
                    builder: (context, t, _) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(_closePanel()),
                      child: ColoredBox(
                        key: const ValueKey('story-panel-scrim'),
                        color: Color.fromRGBO(0, 0, 0, 0.5 * t),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: math.min(math.max(window.width * 0.34, 280), 420),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _panelDrawerClosing ? 0.0 : 1.0),
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => FractionalTranslation(
                      translation: Offset(1 - t, 0),
                      child: Opacity(opacity: t, child: child!),
                    ),
                    child: StoryEpisodeDrawer(
                      episodes: widget.episodes,
                      currentIndex: widget.currentIndex,
                      playingIndex:
                          widget.playingIndex ??
                          (_ready ? widget.currentIndex : null),
                      playing: widget.playing,
                      watched: widget.watchedEpisodes,
                      onSelectEpisode: (index) {
                        unawaited(_closePanel());
                        unawaited(_selectEpisode(index));
                      },
                      onClose: () => unawaited(_closePanel()),
                    ),
                  ),
                ),
              ],
              if (_panelOpen && !_panelDrawer) ...[
                // 官方弹层遮罩：dim 0.5、随面板开合淡入淡出、点遮罩关闭
                // （`AnimationBottomDialog.java:312-316,604`）。
                Positioned.fill(
                  child: ListenableBuilder(
                    listenable: _panel,
                    builder: (context, _) {
                      final strength = _panelStrength;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(_animatePanel(0)),
                        child: ColoredBox(
                          key: const ValueKey('story-panel-scrim'),
                          color: Color.fromRGBO(0, 0, 0, 0.5 * strength),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  top: insets.top,
                  left: insets.left,
                  right: insets.right,
                  bottom: 0,
                  // 官方进出场 200ms 位移+淡入（`:268-337`）：位移由 sheet 的
                  // extent 动画承担，透明度跟随同一进度。child 提升避免每个
                  // extent tick 重建面板子树（渲染测试的 0-rebuild 断言）。
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onPanelScroll,
                    child: ListenableBuilder(
                      listenable: _panel,
                      child: DraggableScrollableSheet(
                        controller: _panel,
                        initialChildSize: 0,
                        minChildSize: 0,
                        maxChildSize: _panelMaxFraction,
                        snap: true,
                        snapSizes: _panelSnapSizes,
                        shouldCloseOnMinExtent: false,
                        builder: (context, scroll) => StoryPlayerPanel(
                          scrollController: scroll,
                          episodes: widget.episodes,
                          currentIndex: widget.currentIndex,
                          playingIndex:
                              widget.playingIndex ??
                              (_ready ? widget.currentIndex : null),
                          playing: widget.playing,
                          watched: widget.watchedEpisodes,
                          onSelectEpisode: (index) {
                            unawaited(_animatePanel(0));
                            unawaited(_selectEpisode(index));
                          },
                          onDragStart: _startPanelDrag,
                          onDragUpdate: (details) =>
                              _dragPanel(details, layout.availableHeight),
                          onDragEnd: _endPanelDrag,
                          onDragCancel: () => _endPanelDrag(DragEndDetails()),
                        ),
                      ),
                      builder: (context, child) => Opacity(
                        opacity: _panelStrength,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    ),
  );

  Widget _positionVideo({
    required Size window,
    required EdgeInsets insets,
    required Widget child,
    bool fitVideo = false,
  }) => ValueListenableBuilder<double>(
    valueListenable: _panelExtent,
    child: child,
    builder: (context, fraction, child) {
      final layout = PlayerVideoLayout.calculate(
        window: window,
        insets: insets,
        videoSize: _videoSize,
        fit: VideoFit.contain,
        panelFraction: fraction,
        restingPanelFraction: _panelRestFraction,
        fullScreen: _fullScreen,
      );
      // Retain the video/cover subtree while only its rectangle follows the
      // panel. DraggableScrollableSheet already retains its own content.
      return Positioned.fromRect(
        rect: fitVideo ? layout.video : layout.viewport,
        child: child!,
      );
    },
  );

  Widget _topBar(EdgeInsets insets, {required bool landscape}) => Positioned(
    left: insets.left,
    right: insets.right,
    top: 0,
    child: Container(
      padding: EdgeInsets.only(top: insets.top),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              onPressed: _back,
              icon: const Icon(
                Icons.arrow_back_ios_new,
                color: Colors.white,
                size: 22,
              ),
            ),
            Expanded(
              child: Text(
                // 官方播放页顶栏标题就是「第1集」这样的集数（截图），
                // 剧名在底部信息层；横屏顶栏是「剧名 第1集」（官方横屏
                // 截图第二十三轮），剧名与集数同行、剧名加粗。
                landscape
                    ? '$_seriesTitle 第${widget.currentIndex + 1}集'
                    : '第${widget.currentIndex + 1}集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            IconButton(
              tooltip: '更多',
              onPressed: _showRates,
              icon: const Icon(Icons.more_vert, color: Colors.white),
            ),
          ],
        ),
      ),
    ),
  );

  /// 官方播放页右侧竖栏（`cjq.xml` 家族：46dp 图标 + 12sp bold、色
  /// `@color/u`=#ccffffff、项间距 12dp）：星=追剧、心=点赞。选集走底部
  /// 目录条、倍速在长按/传输条、清屏在顶栏。
  /// 官方播放页右侧竖栏（`cjq.xml` + `cuv.xml`/`cuh.xml`：图标 **46dp**、
  /// 12sp bold、色 `@color/u`=#ccffffff、图标与文案间距 2dp、项间距
  /// **12dp**）：星=追剧、心=点赞。官方的评论/分享默认 gone，本仓库无
  /// 数据也不显示。
  Widget _rightBar(EdgeInsets insets) {
    Widget railButton(
      String? key,
      String label,
      IconData icon,
      VoidCallback? onTap,
    ) => GestureDetector(
      key: key == null ? null : ValueKey(key),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 46, color: Colors.white, shadows: const [
            Shadow(color: Colors.black38, blurRadius: 6),
          ]),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              height: 1.1,
              fontWeight: FontWeight.bold,
              color: Color(0xCCFFFFFF),
            ),
          ),
        ],
      ),
    );
    return Positioned(
      right: insets.right + 12,
      bottom: insets.bottom + 172,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          railButton(
            'player-follow-button',
            widget.followerLabel ?? '追剧',
            Icons.star_rounded,
            widget.onFollow,
          ),
          const SizedBox(height: 12),
          railButton(
            'player-like-button',
            '点赞',
            Icons.favorite_rounded,
            widget.onLike,
          ),
        ],
      ),
    );
  }

  /// 官方播放页底部信息层（截图）：居中「全屏观看」pill（`aqi.xml`：圆角
  /// 8dp、底 `@color/avv`=#B3262626、图标 20dp + 14sp bold 白字）→ 剧名
  /// 16sp bold + 8×16dp 箭头（`d6g.xml` 同款）→ 「ⓘ 作者声明：内容由AI
  /// 生成」（`video_detail.ai_usage_type`，有才显示）。
  ///
  /// 官方右下角文字行（`SingleVideoHolder.java:1131-1153` 的
  /// `q8()/W4()`：14sp bold `@color/a3`=#ffffffff、项间距 24dp、无分隔符）。
  ///
  /// 官方 XML 是条目布局里独立的 `bottom 15dp / end 16dp` 容器；我们的底部
  /// band 被贴底进度条与选集底栏占满，落 15dp 会与两者互相遮挡且点不到，
  /// 故整行放在进度条之上（bottom 88dp、end 16dp），信息层整体上抬到 96dp
  /// 让位（对照文档 §27 记偏差）。
  Widget _screenTexts() {
    const style = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.bold,
      color: Color(0xFFFFFFFF),
      shadows: [Shadow(color: Colors.black45, blurRadius: 8)],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const ValueKey('player-rate-text'),
          behavior: HitTestBehavior.opaque,
          onTap: _showRates,
          child: Text(_rateText(_rate), style: style),
        ),
        const SizedBox(width: 24),
        GestureDetector(
          key: const ValueKey('player-clear-screen'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _setClearScreen(!_clearScreen),
          child: Text(_clearScreen ? '恢复' : '清屏', style: style),
        ),
      ],
    );
  }

  /// 底部信息层（官方截图第二十二轮，常驻 band）：
  /// - 控制条可见时：居中「全屏观看」pill（`aqi.xml`：圆角 8dp、底
  ///   `@color/avv`=#B3262626、图标 20dp + 14sp bold 白字）+ 剧名。
  /// - 控制条收起后：剧名 + 原著书卡（「原著《…》」，`/related` 的 book
  ///   关联，点击开原著详情）。
  /// 官方截图里的「热评」行与分享箭头+计数需要评论/分享后端（§21 暂缓），
  /// 不显示；胶囊右侧的方形图标钮 = 清屏开关（用户指认），见
  /// `_clearScreenButton`。
  Widget _information(
    EdgeInsets insets, {
    required bool showPill,
    required bool showBook,
  }) => Positioned(
    left: insets.left,
    right: insets.right,
    bottom: insets.bottom + 96,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showPill)
            Center(
              child: GestureDetector(
                key: const ValueKey('player-fullscreen-pill'),
                onTap: _toggleFullScreen,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB3262626),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/drama/fullscreen.webp',
                        width: 20,
                        height: 20,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '全屏观看',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (showPill) const SizedBox(height: 12),
          Row(
            children: [
              Flexible(
                child: Text(
                  _seriesTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black45, blurRadius: 8)],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 8,
                height: 16,
                child: Image.asset(
                  'assets/images/drama/info_arrow.webp',
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
          if (widget.aiGenerated) ...[
            const SizedBox(height: 8),
            Row(
              children: const [
                Icon(Icons.info_outline, size: 13, color: Color(0x99FFFFFF)),
                SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '作者声明：内容由AI生成',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Color(0x99FFFFFF)),
                  ),
                ),
              ],
            ),
          ],
          if (showBook && widget.originalBook != null)
            _originalBookCard(widget.originalBook!),
        ],
      ),
    ),
  );

  /// 原著书卡（官方截图第二十二轮）：深色圆角条，白色小方徽 + 深色书本
  /// 图标 + 「原著《书名》」14sp bold 白 + 8×16dp 右箭头（`info_arrow`），
  /// 点击进原著详情页（`/related` kind=book，audio 页同一条跳转链路）。
  Widget _originalBookCard(RelatedWork book) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: GestureDetector(
      key: const ValueKey('player-original-book'),
      onTap: widget.onOpenOriginalBook,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.all(Radius.circular(5)),
              ),
              child: const Icon(
                Icons.menu_book_rounded,
                size: 13,
                color: Color(0xFF1B1B1B),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '原著《${book.title}》',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 8,
              height: 16,
              child: Image.asset('assets/images/drama/info_arrow.webp',
                  fit: BoxFit.contain),
            ),
          ],
        ),
      ),
    ),
  );

  /// 官方选集底栏（截图第二十二轮）：圆角深灰条「选集 · 已完结 · 全82集」
  /// + 上箭头，点击弹选集面板（`key_launch_catalog_panel` 弹的就是它）。
  /// 状态段用 `@string/ag_`（已完结）/`agb`（连载中），由宿主从
  /// `book_detail.creation_status` 取好传入；无数据只显示「选集 · 全N集」
  /// （官方文案 `@string/e6r`「全%s集」）。`compact` = 右端给清屏图标钮
  /// 让位（官方截图：胶囊与图标钮同行，间距 8dp）。
  Widget _catalogBar(EdgeInsets insets, {required bool compact}) => Positioned(
    left: insets.left + 12,
    right: insets.right + (compact ? 52 : 12),
    bottom: insets.bottom + 8,
    child: GestureDetector(
      key: const ValueKey('player-catalog-bar'),
      onTap: _openPanel,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xE6222222),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Text(
              '选集',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Expanded(
              child: Text(
                widget.seriesStatus == null
                    ? ' · 全${widget.episodes.length}集'
                    : ' · ${widget.seriesStatus} · 全${widget.episodes.length}集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_up_rounded,
              color: Colors.white,
              size: 22,
            ),
          ],
        ),
      ),
    ),
  );

  /// 清屏图标钮（官方截图第二十二轮，用户指认 = 清屏）：胶囊右侧的
  /// 「页面 + 禁止角标」图标钮，属常驻 band（控制条收起后仍在）；点击进
  /// 清屏态，出口仍是右下「恢复」文字行。控制条可见时清屏入口是
  /// 倍速｜清屏 文字行（`SingleVideoHolder.s8()`），两者并存不冲突。
  Widget _clearScreenButton(EdgeInsets insets) => Positioned(
    right: insets.right + 12,
    bottom: insets.bottom + 8,
    child: GestureDetector(
      key: const ValueKey('player-clear-icon'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _setClearScreen(true),
      child: SizedBox(
        width: 40,
        height: 48,
        child: Center(
          child: CustomPaint(
            size: const Size(30, 30),
            painter: _ClearScreenIconPainter(),
          ),
        ),
      ),
    ),
  );

  Widget _transport(EdgeInsets insets, bool landscape) => Positioned(
    left: insets.left + 8,
    right: insets.right + 8,
    bottom: insets.bottom + (landscape ? 0 : 74),
    child: SizedBox(
      key: const ValueKey('video-controls'),
      height: 61,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _transportButton(
            '上一集',
            Icons.skip_previous_rounded,
            widget.currentIndex > 0
                ? () => _selectEpisode(widget.currentIndex - 1)
                : null,
          ),
          _transportButton(
            '快退10秒',
            Icons.replay_10,
            widget.duration > Duration.zero ? () => _seekBy(-10) : null,
          ),
          _transportButton(
            _playbackRequested ? '暂停' : '播放',
            _playbackRequested ? Icons.pause_rounded : Icons.play_arrow_rounded,
            _togglePlayback,
          ),
          _transportButton(
            '快进10秒',
            Icons.forward_10,
            widget.duration > Duration.zero ? () => _seekBy(10) : null,
          ),
          _transportButton(
            '下一集',
            Icons.skip_next_rounded,
            widget.currentIndex < widget.episodes.length - 1
                ? () => _selectEpisode(widget.currentIndex + 1)
                : null,
          ),
          if (landscape) ...[
            TextButton(
              onPressed: _showRates,
              child: Text(
                '${_rateLabel(_rate)}×',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            TextButton(
              onPressed: _openPanel,
              child: const Text('选集', style: TextStyle(color: Colors.white)),
            ),
          ],
          _transportButton(
            _fullScreen ? '退出全屏' : '全屏',
            _fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
            _toggleFullScreen,
          ),
        ],
      ),
    ),
  );

  Widget _transportButton(
    String tooltip,
    IconData icon,
    VoidCallback? onPressed,
  ) => SizedBox(
    width: 40,
    height: 48,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      color: Colors.white,
      disabledColor: Colors.white24,
      icon: Icon(icon, size: 25),
    ),
  );

  /// 官方横屏底条（官方截图第二十三轮，真实 app 形态，替代第二十一轮按
  /// `c0i/cw7` 取证的单行布局）：130dp 渐变上两行——
  /// - 控制行：播放/暂停 32dp（`btu/btv`）→ 下一集 32dp（仅集数>1）→
  ///   当前时长（拖动中实时）→ 橙色进度条（轨道 4/滑块 16）→ 总时长；
  ///   时长恒 `HH:MM:SS`（`o2()` → `d7.o(sec, true)`，截图 00:00:02/00:02:05）。
  /// - 功能行：点赞（无计数数据源，只显示图标）、追剧+计数
  ///   （`followed_cnt` → formatCounter）｜倍速文本、选集（仅集数>1）。
  /// 官方该行还有评论计数、弹幕开关+弹幕输入框、720P 清晰度——均无数据
  /// 源，不显示（诚实清单）。
  Widget _landscapeBar(EdgeInsets insets) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: Container(
      height: insets.bottom + 130,
      padding: EdgeInsets.only(
        bottom: insets.bottom,
        left: insets.left + 16,
        right: insets.right + 16,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0x7F000000)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                _landIconButton(
                  'landscape-play',
                  _playbackRequested
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  _playbackRequested ? '暂停' : '播放',
                  _togglePlayback,
                ),
                const SizedBox(width: 12),
                if (widget.episodes.length > 1)
                  _landIconButton(
                    'landscape-next',
                    Icons.skip_next_rounded,
                    '下一集',
                    _nextEpisodeOrToast,
                  ),
                const SizedBox(width: 16),
                ListenableBuilder(
                  listenable: _timeline,
                  builder: (context, _) {
                    final duration = widget.duration;
                    final shown =
                        _seekValue.value != null && duration > Duration.zero
                        ? Duration(
                            milliseconds:
                                (_seekValue.value! * duration.inMilliseconds)
                                    .round(),
                          )
                        : _position.value;
                    return Text(
                      key: const ValueKey('landscape-time'),
                      _hms(shown),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [_landShadow],
                      ),
                    );
                  },
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StorySeekBar(
                    key: const ValueKey('landscape-seek'),
                    value: _progressValue,
                    enabled: widget.duration > Duration.zero,
                    seeking: _seeking,
                    onStart: _startSeek,
                    onChanged: (value) => _seekValue.value = value,
                    onEnd: (value) => unawaited(_finishSeek(value)),
                    onCancel: _cancelSeek,
                    trackWidth: 4,
                    thumbRadius: 8,
                    progressColor: const Color(0xFFFA6725),
                    trackColor: const Color(0x4DFFFFFF),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  key: const ValueKey('landscape-total-time'),
                  _hms(widget.duration),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [_landShadow],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                _landRailItem(
                  'landscape-like',
                  Icons.favorite_rounded,
                  null,
                  widget.onLike,
                ),
                const SizedBox(width: 20),
                _landRailItem(
                  'landscape-follow',
                  Icons.star_rounded,
                  widget.followerLabel ?? '追剧',
                  widget.onFollow,
                ),
                const Spacer(),
                _landText('landscape-rate', _rateText(_rate), _showRates),
                const SizedBox(width: 24),
                if (widget.episodes.length > 1)
                  _landText('landscape-episodes', '选集', _openPanel),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  /// 官方横屏时长格式（`o2()` → `d7.o(sec, true)`）：恒 `HH:MM:SS`，
  /// 与共享的 `mm:ss` 格式器（音频页同源）分开。
  String _hms(Duration value) {
    final seconds = value.inSeconds.clamp(0, 0x7fffffff);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(seconds ~/ 3600)}:${p((seconds % 3600) ~/ 60)}:${p(seconds % 60)}';
  }

  /// 横屏功能行的追剧/点赞项（官方截图：图标 + 下方计数）。计数由宿主给
  /// （追剧 = followed_cnt；点赞/评论无数据源，只出图标或不出）。
  Widget _landRailItem(
    String key,
    IconData icon,
    String? label,
    VoidCallback? onTap,
  ) => GestureDetector(
    key: ValueKey(key),
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 22, color: Colors.white, shadows: const [_landShadow]),
        if (label != null)
          Text(
            label,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 11,
              height: 1.2,
              color: Colors.white,
              shadows: [_landShadow],
            ),
          ),
      ],
    ),
  );

  Widget _landIconButton(
    String key,
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
  ) => IconButton(
    key: ValueKey(key),
    tooltip: tooltip,
    onPressed: onPressed,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    color: Colors.white,
    iconSize: 32,
    icon: Icon(icon, shadows: const [_landShadow]),
  );

  Widget _landText(String key, String label, VoidCallback onPressed) =>
      GestureDetector(
        key: ValueKey(key),
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [_landShadow],
          ),
        ),
      );

  /// 官方横屏文字/图标阴影（`c0i`/`c0h`：`@color/da`=#33000000，dx/dy 1、
  /// 半径 1）。
  static const _landShadow = Shadow(
    color: Color(0x33000000),
    offset: Offset(1, 1),
    blurRadius: 1,
  );

  /// 下一集（`a.java:963-976`）：未集则切集；最后一集 toast「当前已在
  /// 最后一集」（`@string/dxx`）。
  void _nextEpisodeOrToast() {
    if (widget.currentIndex < widget.episodes.length - 1) {
      _selectEpisode(widget.currentIndex + 1);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('当前已在最后一集')));
  }
}

// Both formatters are shared with the audio page (services/playback_format.dart)
// so the two players can never drift apart again.
String _rateLabel(double rate) => formatPlaybackRate(rate);

/// 官方倍速文案（`SingleVideoHolder.java:1155-1171`）：1.0 显示「倍速」，
/// 其余 `数值x`（如 `1.5x`）。
String _rateText(double rate) => rate == 1 ? '倍速' : '${_rateLabel(rate)}x';

/// 官方档位 chip 文案（`ShortSeriesMorePanelDialogV2.java:873-892`）：
/// `0.75x / 1x / 1.25x / 1.5x / 1.75x / 2x`。
String _rateChipLabel(double rate) => '${_rateLabel(rate)}x';

String _time(Duration value) => formatPlaybackTime(value);

/// 清屏图标（官方截图第二十二轮）：圆角页面 + 两条文字行 + 右下角
/// 「禁止」圆环斜杠角标；页面轮廓在角标处留缺口（Path.difference）。
class _ClearScreenIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * s
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    const badge = Offset(17.9, 17.6);
    final page = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3.2 * s, 3.2 * s, 16.3 * s, 17.6 * s),
          Radius.circular(4 * s),
        ),
      );
    final cut = Path()
      ..addOval(
        Rect.fromCircle(center: Offset(badge.dx * s, badge.dy * s), radius: 6.1 * s),
      );
    canvas.drawPath(Path.combine(PathOperation.difference, page, cut), stroke);
    canvas.drawLine(
      Offset(7.8 * s, 9 * s),
      Offset(16.4 * s, 9 * s),
      stroke..strokeWidth = 1.5 * s,
    );
    canvas.drawLine(
      Offset(7.8 * s, 13 * s),
      Offset(15.2 * s, 13 * s),
      stroke,
    );
    final radius = 4.4 * s;
    final center = Offset(badge.dx * s, badge.dy * s);
    canvas.drawCircle(center, radius, stroke);
    final r = radius / math.sqrt2;
    canvas.drawLine(
      Offset(center.dx - r, center.dy + r),
      Offset(center.dx + r, center.dy - r),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
