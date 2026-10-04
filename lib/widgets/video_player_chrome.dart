import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';

import '../models/audio_extra.dart';
import '../models/media_item.dart';
import '../services/episode_source_cache.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/player_preferences.dart';
import '../services/player_style_config.dart';
import '../services/short_series_font_scale.dart';
import '../models/playlet_comment.dart';
import 'player/playlet_danmaku_layer.dart';
import 'player/playlet_danmaku_settings.dart';
import 'player/story_player_panel.dart';
import 'player/playlet_hot_comment_bar.dart';
import 'player/playlet_more_panel.dart';
import 'player/playlet_more_panel_light.dart';
import 'player/quality_icon.dart';
import 'player/player_cover.dart';
import 'player/player_video_layout.dart';
import 'player/story_seek_bar.dart';

// Note: 移除短剧互动入口的范围见
// .agents/notes/implemented/simplification/2026-09-26-playlet-social-controls.md
// Note: 截图形态、视频底边定位与触区取舍见
// .agents/notes/implemented/bug-fix/2026-09-26-playlet-portrait-layout.md
class VideoPlayerChrome extends StatefulWidget {
  final NativePlayer? player;
  final String title;
  final List<Chapter> episodes;
  final int currentIndex;
  final int? playingIndex;
  final Duration duration;
  final bool playing;
  final bool enabled;

  /// 评论等由宿主打开的弹层也要中断画面手势。
  final bool interactionBlocked;
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

  /// 「作者声明：内容由AI生成」行（`video_detail.ai_usage_type`）。
  final bool aiGenerated;

  /// 「左右滑动可调整进度」首次引导（`@string/cha`，引导层距底 138dp，
  /// `of3/a.java`）。显示与否由宿主决定（每台设备一次）。
  final bool showSeekHint;
  final VoidCallback? onSeekHintConsumed;

  /// 官方底栏配置 `player_bottom_style_config`（`PlayerBottomStyleConfig.a()`）。
  /// 当前新栏按用户选定截图使用「选集 + 清屏图标」，清屏后用文字恢复；
  /// 这是本地外观选择，不将其推断成官方所有新栏配置的固定样式。
  /// 旧栏仍保留独立配置门，自动收起不切换底栏分支。
  final bool newPlayerBottomStyle;
  final bool hasBanner;

  /// 旧底栏（`jj3/i` + `bom.xml`）里「清屏」（Lottie + 文案）与「还原」两项
  /// 只在 `NsUtilsDepend.isPadDevice() && PadFitPhaseTwo.newBottomStyle` 时
  /// 可见（`jj3/i.java:620-637`）。手机上的旧底栏只有「清晰度 / 倍速」，
  /// 没有清屏入口——不能凭 `PlayerBottomStyleConfig` 一个开关推断出来。
  final bool padNewBottomStyle;

  /// 官方 `func_reverse_of_clear_screen_v691.reverse`：为真时清屏整体不可用
  /// （`o.H1()` 的第一道门）。
  final bool reverseClearScreen;

  /// 官方 `landscape_func_config_v705.enable_lock`：横屏防误触锁的配置门，
  /// 默认关闭（`LandLockOptV705` 默认 false）。
  final bool landscapeLockEnabled;

  /// 评论入口：官方右栏第三项。计数 0 时文案是「评论」。为 null 时该项
  /// 不出现（官方该项本身默认 gone，见 \`res/layout/cjs.xml:11\`）。
  final int commentCount;
  final VoidCallback? onComments;

  /// 热评信息行（官方 `InfoPanelHotCommentView`）：列表来自 `hotOf` 的本地筛选，
  /// 为空时整条不出现。
  final List<PlayletComment> hotComments;
  final ValueChanged<PlayletComment>? onHotCommentTap;

  /// 更多面板的开关行（官方 `ShortSeriesMorePanelDialogV2`）：
  /// 画面撑满 / 默认静音。为 null 时该行不出现。
  final bool fillScreen;
  final ValueChanged<bool>? onFillScreenChanged;
  final bool defaultMute;
  final ValueChanged<bool>? onDefaultMuteChanged;

  /// 选集面板头部的剧信息（官方 \`aa8.xml:7-15\`）。
  final String seriesTitle;

  /// 标题行「剧名 >」点击 → 官方进剧集详情页（`series_detail`，ql3/v0
  /// `a1()` 的默认分支）。null 时不响应（非短剧形态）。
  final VoidCallback? onOpenSeriesDetail;
  final String seriesCover;
  final String episodeLabel;

  /// 选集面板的关联原著条（官方 `series_relate_book_config_v659`
  /// 的 `relate_book_in_episodes_dialog`，**默认 false**）。
  final EpisodeRelateBook? relateBook;
  final VoidCallback? onOpenRelateBook;

  /// 弹幕（官方 \`DanmakuRequestHelper\`）：时间轴条目 + 开关状态。
  final List<PlayletComment> danmaku;
  final bool danmakuEnabled;
  final VoidCallback? onToggleDanmaku;

  /// 弹幕设置（官方 `danmaku_config`）。回调为 null 时「弹幕设置」
  /// 入口不出现（官方 jm3.e 的 `e()` 门）。
  final DanmakuSettings danmakuSettings;
  final ValueChanged<DanmakuSettings>? onDanmakuSettingsChanged;

  /// 听视频（官方 `jm3.d0.y()`：打开听书模式页）。null 时浅色面板的
  /// 听视频行不出现（feed 长按未接）。
  final VoidCallback? onOpenListenMode;

  /// 离线缓存（官方 `jm3.u`：打开选集下载弹窗）。null 时浅色面板的
  /// 离线缓存行退化为「暂未支持」占位。
  final VoidCallback? onOpenOfflineCache;

  /// 可选播放档位（高→低）与当前档 URL。空列表 = 上游单流，
  /// 「清晰度」行不显示（官方 `oi3/k.P()` 门）。
  final List<EpisodeVariant> qualityVariants;
  final String? currentQualityUrl;
  final ValueChanged<EpisodeVariant>? onQualitySelected;

  /// 最终确定的 seek 目标（进度条拖动收尾、横滑收尾、±10s 快进/回拖、
  /// 播完重播回零）。拖动过程中的实时 seek 不上报，只报收尾值，
  /// 对齐官方 `seekTo()` 的 `ON_SEEK_FINISH` 时机（l.java:1213-1227）。
  final void Function(Duration target)? onSeeked;

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
    this.interactionBlocked = false,
    required this.child,
    this.coverUrl = '',
    this.watchedEpisodes = const <int>{},
    this.onPagingChanged,
    required this.onSelectEpisode,
    required this.onError,
    this.shortSeries = false,
    this.aiGenerated = false,
    this.showSeekHint = false,
    this.onSeekHintConsumed,
    this.seriesStatus,
    this.originalBook,
    this.onOpenOriginalBook,
    this.newPlayerBottomStyle = true,
    this.hasBanner = false,
    this.padNewBottomStyle = false,
    this.reverseClearScreen = false,
    this.landscapeLockEnabled = false,
    this.commentCount = 0,
    this.onComments,
    this.onSeeked,
    this.hotComments = const [],
    this.onHotCommentTap,
    this.seriesTitle = '',
    this.onOpenSeriesDetail,
    this.seriesCover = '',
    this.episodeLabel = '',
    this.relateBook,
    this.onOpenRelateBook,
    this.fillScreen = false,
    this.onFillScreenChanged,
    this.defaultMute = true,
    this.onDefaultMuteChanged,
    this.danmaku = const [],
    this.danmakuEnabled = true,
    this.onToggleDanmaku,
    this.danmakuSettings = const DanmakuSettings(),
    this.onDanmakuSettingsChanged,
    this.onOpenListenMode,
    this.onOpenOfflineCache,
    this.qualityVariants = const [],
    this.currentQualityUrl,
    this.onQualitySelected,
  });

  @override
  State<VideoPlayerChrome> createState() => _VideoPlayerChromeState();
}

class _VideoPlayerChromeState extends State<VideoPlayerChrome>
    with WidgetsBindingObserver, TickerProviderStateMixin {
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
  Timer? _doubleTapGuard;

  /// 「弹幕设置」级联打开标记：更多面板收起后再开设置面板。
  bool _pendingDanmakuSettings = false;

  /// 「字体大小」级联打开标记：官方 `jm3.t0.m()` 同款——更多面板收起后
  /// 再开字号弹层（`nm3.e`）。
  bool _pendingFontScale = false;

  /// 双击按下的位置：官方双击的中带判定需要 y 坐标
  /// （`jq3/x$q.onDoubleTap` 的 44dp..屏高-240dp）。
  Offset? _doubleTapDownPosition;
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
  Size _viewportSize = Size.zero;

  /// 清屏独立于控件自动收起，暂停、切集与旋转均保留本次会话的选择。
  /// Note: 新底栏文字/图标两分支与手势取舍 — 见
  /// .agents/notes/proposed/architecture/2026-09-25-f01-f03-official-evidence.md
  bool _clearScreen = false;

  /// 横屏防误触锁（官方 `fullscreen.b` 单例的本地等价）：锁定后画面手势、
  /// 播放控件、选集/更多面板与清屏全部被吞；退出横屏或换播放器即解除
  /// （官方 `ShortSeriesLandActivity.onDestroy` → `EXIST_LAND_ACTIVITY`）。
  bool _locked = false;
  bool _lockVisible = true;
  Timer? _lockHideTimer;

  /// 官方 `uk3/c` 的 Lottie 驱动：`op`=20、`fr`=30 → 666ms；锁定时停在
  /// 第 20 帧（`value == 1`），解锁时停在帧 0。
  late final AnimationController _lockController;

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
  bool get _overlayOpen => _modalOpen || widget.interactionBlocked;
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
    _lockController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 666),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed ||
              status == AnimationStatus.dismissed) {
            final endpoint = _locked ? 1.0 : 0.0;
            if (_lockController.value != endpoint) {
              _lockController.value = endpoint;
            }
          }
        });
    unawaited(_loadRate());
    // 官方 o.W7()：holder 初始化时，若清屏未被反向禁用（O1()）且当前是
    // 旧底栏分支（SingleVideoHolder.F6()：k9()=新栏样式为假、场景默认 1），
    // 进页即清屏（T7(true)）。新栏分支 F6() 恒 false，不清屏；官方的听书
    // 模式条件（T9/is_listen_mode）本客户端不存在。Z5 的「每 holder 一次」
    // = 每个播放页实例一次（initState 天然满足）。旧底栏栏内无出口，
    // 退出走更多面板的「退出清屏」行。
    if (widget.shortSeries &&
        !widget.newPlayerBottomStyle &&
        !widget.hasBanner &&
        !widget.reverseClearScreen) {
      _clearScreen = true;
    }
    _scheduleHide();
    _scheduleLockHide();
  }

  @override
  void didUpdateWidget(VideoPlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _listenToPosition();
      // 换播放器等于换 holder：官方 `d.release()` 会摘掉锁监听，本地等价是
      // 撤销锁态，避免下一个剧集继承上一个的锁定。
      _releaseLock();
      _doubleTapGuard?.cancel();
    }
    if (oldWidget.landscapeLockEnabled && !widget.landscapeLockEnabled) {
      _releaseLock();
      _scheduleHide();
    }
    // 清屏态的对账：栏内入口消失（配置翻转）时退出清屏，除非面板行还在
    // ——官方旧底栏手机分支本来就没有栏内入口，出口只在面板行（jm3.a），
    // 只要它可用就不许制造没有出口的状态。
    if (_clearScreen && !_clearScreenConfigured && !_clearScreenPanelAvailable) {
      _clearScreen = false;
      _visible = true;
      _scheduleHide();
    }
    if (!oldWidget.interactionBlocked && widget.interactionBlocked) {
      _endBoost();
      _cancelSeek();
      _doubleTapGuard?.cancel();
      _hideTimer?.cancel();
    } else if (oldWidget.interactionBlocked && !widget.interactionBlocked) {
      _visible = true;
      _scheduleHide();
    }
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
      _dragSeekOrigin = null;
      _dragSeekActive = false;
      _doubleTapGuard?.cancel();
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
    _doubleTapGuard?.cancel();
    _lockHideTimer?.cancel();
    _panelDrawerTimer?.cancel();
    _lockController.dispose();
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
      _doubleTapGuard?.cancel();
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
    // 官方竖屏新底栏播放页没有整层隐藏控件的定时器（apf.xml/cjc.xml 链路
    // 取证：顶栏、全屏观看、信息区、选集栏常驻，右栏淡出只跟追剧/点赞状态
    // 走；淡出仅随面板滑出 o.g6(1-f2) 与清屏发生）。此前的 3s 自动收起是
    // 推断值（f01-f08 总表:117「官方自动收起计时值未定位」），按官方行为
    // 让该形态常驻；通用播放器与横屏保留原计时。
    if (widget.shortSeries && _catalogStyle && !_isLandscape) return;
    if (!_ready ||
        _clearScreen ||
        _locked ||
        !_appActive ||
        !widget.playing ||
        _seeking ||
        _overlayOpen ||
        _panelOpen ||
        _boosting ||
        _paging) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  /// 官方 `fullscreen/d.G6()`：已锁定时把锁按钮的自动隐藏排在 5 秒后；
  /// 未锁定时不排（锁按钮随控件条一起显示/隐藏）。
  void _scheduleLockHide() {
    _lockHideTimer?.cancel();
    if (!_locked || !widget.landscapeLockEnabled) return;
    _lockHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _locked) setState(() => _lockVisible = false);
    });
  }

  /// 官方 `d.K6`：点锁按钮就切换锁定状态，锁定时重新计时，解锁时立即
  /// 恢复可见；锁本身不改变播放状态。
  void _toggleLock() {
    if (!_isLandscape || _panelOpen || _overlayOpen || _clearScreen) return;
    ++_interaction;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    final lock = !_locked;
    setState(() {
      _locked = lock;
      _lockVisible = true;
      _visible = true;
    });
    // 官方 \`uk3/c.j(z)\`：锁 → 从第 20 帧反向播到 0；解锁 → 从 0 正向播到
    // 第 20 帧，结束后停在对应端点。
    if (lock) {
      _lockController.reverse(from: 1);
    } else {
      _lockController.forward(from: 0);
    }
    _scheduleLockHide();
    if (!lock) _scheduleHide();
  }

  void _guardDoubleTap() {
    _doubleTapGuard?.cancel();
    // 官方 VideoGestureDetectLayout.java:162 在双击后 800ms 内吞掉单击。
    _doubleTapGuard = Timer(const Duration(milliseconds: 800), () {});
  }

  /// 按官方 `H6()` 自动隐藏规则同步锁按钮可见性（`getCurrentViewVisible`
  /// 为真就隐藏，否则显示）。
  void _refreshLockVisibility() {
    if (!_locked) return;
    if (_lockVisible) {
      _lockHideTimer?.cancel();
      setState(() => _lockVisible = false);
    } else {
      setState(() => _lockVisible = true);
      _scheduleLockHide();
    }
  }

  /// 退出横屏 / 换播放器：官方在 Activity 销毁时无条件解锁
  /// （`EXIST_LAND_ACTIVITY`），本地等价是离开横屏与替换播放器。
  void _releaseLock() {
    _lockHideTimer?.cancel();
    if (_locked) _visible = true;
    _locked = false;
    _lockVisible = true;
    _lockController.stop();
    _lockController.value = 0;
  }

  void _toggleControls() {
    // 控件显隐不退出清屏；短剧清屏时单击画面仍走播放/暂停。
    if (_clearScreen) return;
    if (_panelOpen || _overlayOpen || _seeking || _boosting || _paging) return;
    setState(() => _visible = !_visible);
    if (_visible) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  /// 官方 `o.H1(z)`：`func_reverse_of_clear_screen_v691.reverse` 为真时
  /// 整个清屏入口不可用；`b7()` 取当前持有者的 `yp3.k.b()`，本地等价是
  /// 「播放器就绪」。新底栏文字行与旧底栏图标都走这一个入口。
  /// 官方 `o.H1()` 的门是 `!O1() || !yp3.k.a()`：前者是清屏反转配置，
  /// 后者是「这个持有者允许清屏」。它**不要求视频已就绪**——加载中就退不出
  /// 清屏会制造一个没有出口的状态，所以本地不把 `_ready` 放进门里。
  bool get _clearScreenConfigured =>
      !widget.reverseClearScreen &&
      (widget.newPlayerBottomStyle ||
          widget.hasBanner ||
          widget.padNewBottomStyle);

  bool get _clearScreenAvailable => _clearScreenConfigured && !_locked;

  /// 更多面板「清屏播放/退出清屏」行的门（官方 `oi3/k.G()`：只看
  /// `FuncReverseOfClearScreen.reverse`，与底栏样式无关）。旧底栏手机分支
  /// 栏内没有清屏入口，面板行就是官方给的全部出口。非短剧的通用面板不
  /// 消费这个回调，行本身只出现在短剧面板里。
  bool get _clearScreenPanelAvailable =>
      !widget.reverseClearScreen && !_locked;

  bool get _catalogStyle =>
      widget.shortSeries && (widget.newPlayerBottomStyle || widget.hasBanner);

  /// 沿用官方独立清屏状态；新底栏文字入口 vs 旧底栏图标的互斥分支见
  /// .agents/notes/proposed/architecture/2026-09-25-f01-f03-official-evidence.md §1。
  /// 守门用面板级的 `_clearScreenPanelAvailable`：旧底栏手机分支没有栏内
  /// 入口，但官方面板行仍可切换（jm3.a），守门不能把那条官方出口堵死。
  void _setClearScreen(bool clear) {
    if (!_clearScreenPanelAvailable) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
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
        _locked ||
        _panelOpen ||
        _overlayOpen ||
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
      setState(() => _dragSeekActive = true);
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
    setState(() => _dragSeekActive = false);
    final fraction = _dragFraction(
      // DragEnd 没有位置；沿用最后一次 update 的预览值。
      _seekValue.value == null
          ? 0
          : (_seekValue.value! * MediaQuery.sizeOf(context).width),
    );
    unawaited(() async {
      final target = Duration(
        milliseconds: (widget.duration.inMilliseconds * fraction).round(),
      );
      await _control((player) => player.seek(target));
      // 横滑收尾才报最终目标；拖动中的实时 seek 不上报。
      widget.onSeeked?.call(target);
      if (mounted && !_seeking) _seekValue.value = null;
    }());
    if (widget.showSeekHint) widget.onSeekHintConsumed?.call();
  }

  double _dragFraction(double dx) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return 0;
    return (dx / width).clamp(0.0, 1.0);
  }

  void _togglePlayback() {
    if (!_ready ||
        !_appActive ||
        _locked ||
        _panelOpen ||
        _overlayOpen ||
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
          if (player.completed) {
            await player.seek(Duration.zero);
            // 播完重播回零也是一次最终 seek（官方 seekTo 的 ON_SEEK_FINISH）。
            widget.onSeeked?.call(Duration.zero);
          }
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
      // 进度条拖动的收尾 seek：只报真正落盘的目标。
      widget.onSeeked?.call(target);
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
    _dragSeekOrigin = null;
    _dragSeekActive = false;
    if (!_seeking) _seekValue.value = null;
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
    // ±10s 的目标在点击时就已确定，直接上报；连续快进按累计目标取数。
    widget.onSeeked?.call(target);
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
        _locked ||
        !widget.playing ||
        _seeking ||
        _paging ||
        _panelOpen ||
        _overlayOpen) {
      return;
    }
    _hideTimer?.cancel();
    HapticFeedback.lightImpact();
    setState(() => _boosting = true);
    unawaited(_control((player) => player.setRate(2)));
  }

  /// 官方 K6() 的横向中心带：竖屏取屏宽 50%、横屏取 33%（J6()），
  /// Y 方向不限。dx 是 Flutter 逻辑像素，与官方 dp 同单位可直接比较。
  bool _inLongPressBand(double dx) {
    final width = _viewportSize.width;
    if (width <= 0) return false;
    final factor = _fullScreen && width > _viewportSize.height ? 0.33 : 0.5;
    final start = width * (1 - factor) / 2;
    return dx >= start && dx <= width - start;
  }

  void _endBoost() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    unawaited(_control((player) => player.setRate(_rate)));
    _scheduleHide();
  }

  /// 弹幕设置面板（官方 `ay1/v.java`）：竖屏整宽底部，横屏 372dp 右对齐。
  /// 滑杆变化实时回调宿主并落盘（官方 UpdateDanmakuConfigEvent）。
  Future<void> _showDanmakuSettings() async {
    final onSettings = widget.onDanmakuSettingsChanged;
    if (onSettings == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _modalOpen = true);
    final landscape = _fullScreen;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: landscape ? Colors.transparent : const Color(0xFF1C1C1C),
      shape: landscape
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
      builder: (sheetContext) {
        final panel = PlayletDanmakuSettingsPanel(
          settings: widget.danmakuSettings,
          landscape: landscape,
          onChanged: (settings) {
            onSettings(settings);
            unawaited(DanmakuSettings.save(settings));
          },
          onReset: () => messenger.showSnackBar(
            const SnackBar(content: Text('设置成功')),
          ),
        );
        if (!landscape) return panel;
        return Container(
          alignment: Alignment.bottomRight,
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: SizedBox(
            width: 372,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1C),
                borderRadius: BorderRadius.circular(12),
              ),
              child: panel,
            ),
          ),
        );
      },
    );
    if (mounted) setState(() => _modalOpen = false);
  }

  /// 字号弹层（官方 `nm3.e`）：标准/大号/超大号三档药丸 + 选中档的预览
  /// 文本（官方是 `ShortSeriesScaleTextView` 样张）。选中即生效并持久化
  /// （SP `short_series_font_scale_manager/current_selected_index`）。
  /// Note: 字号档作用域/弹幕豁免/弹层不自动关的取舍 — 见
  /// .agents/notes/implemented/feature/2026-09-29-listen-mode-and-font-scale.md
  Future<void> _showFontScaleSheet() async {
    if (_overlayOpen || _panelOpen || _locked) return;
    setState(() => _modalOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 200),
        reverseDuration: Duration(milliseconds: 200),
      ),
      barrierColor: Colors.transparent,
      backgroundColor: const Color(0xFFFAFAFA),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final current = ShortSeriesFontScale.instance.clamp(0, 2);
          return SafeArea(
            top: false,
            child: Padding(
              key: const ValueKey('player-font-scale-sheet'),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '字体大小',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF000000),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final (index, label) in ShortSeriesFontScale.labels
                          .indexed)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Semantics(
                            label: label,
                            button: true,
                            selected: index == current,
                            onTap: () {},
                            excludeSemantics: true,
                            child: InkWell(
                              key: ValueKey('player-font-scale-$index'),
                              onTap: () {
                                unawaited(ShortSeriesFontScale.save(index));
                                setState(() {});
                                setSheetState(() {});
                              },
                              borderRadius: BorderRadius.circular(15),
                              child: Container(
                                height: 30,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: index == current
                                      ? Colors.white
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(
                                    color: index == current
                                        ? const Color(0x1F000000)
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: index == current
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: index == current
                                        ? const Color(0xFF000000)
                                        : const Color(0x66000000),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // 预览行按选中档即时缩放（官方样张语义）。
                  Text(
                    '播放页文字大小预览',
                    key: const ValueKey('player-font-scale-preview'),
                    textScaler: TextScaler.linear(ShortSeriesFontScale.scale),
                    style: TextStyle(fontSize: 14, color: const Color(0xFF000000)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) setState(() => _modalOpen = false);
    if (mounted) _scheduleHide();
  }

  /// 更多面板样式分支：官方 `play_control_panel_style_v681.style` 未下发
  /// 或为 0 时是浅色面板（`#FAFAFA`、药丸选项、无取消行），下发 1/2 才是
  /// 深色 V2（`Q0()` 染 `#FF1C1C1C`）。两支共用弹层门控与速率持久化。
  /// Note: 深/浅两支并存的配置门与死行取舍 — 见
  /// .agents/notes/implemented/feature/2026-09-29-more-panel-light-branch.md
  Future<void> _showRates() async {
    if (_overlayOpen || _panelOpen || _locked) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    final dark = PlayerStyleConfig.instance.morePanelDarkStyle;
    setState(() => _modalOpen = true);
    var sheetDanmaku = widget.danmakuEnabled;
    var sheetMute = widget.defaultMute;
    var sheetFill = widget.fillScreen;
    final selected = await showModalBottomSheet<Object>(
      context: context,
      useSafeArea: true,
      isScrollControlled: widget.shortSeries,
      showDragHandle: !widget.shortSeries,
      constraints: widget.shortSeries
          ? const BoxConstraints(maxWidth: double.infinity)
          : null,
      sheetAnimationStyle: widget.shortSeries
          ? const AnimationStyle(
              duration: Duration(milliseconds: 200),
              reverseDuration: Duration(milliseconds: 200),
            )
          : null,
      barrierColor: widget.shortSeries ? Colors.transparent : null,
      backgroundColor: widget.shortSeries
          // 浅色支也跟随夜间皮肤（官方 SkinDelegate 翻白），否则夜间
          // 主题下 FAFAFA 底配白字不可见。
          ? (dark || Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF1C1C1C)
                : const Color(0xFFFAFAFA))
          : const Color(0xFFFAFAFA),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          // aae.xml 的 ak1：浅色支 16dp 顶圆角；深色支沿用已核对的 12dp。
          top: Radius.circular(widget.shortSeries ? (dark ? 12 : 16) : 16),
        ),
      ),
      builder: (context) {
        if (widget.shortSeries && !dark) {
          return PlayletMorePanelLight(
            rate: _rate,
            qualityVariants: widget.qualityVariants,
            currentQualityUrl: widget.currentQualityUrl,
            onQualitySelected: widget.onQualitySelected,
            clearScreen: _clearScreen,
            onToggleClearScreen: _clearScreenPanelAvailable
                ? () => _setClearScreen(!_clearScreen)
                : null,
            danmakuEnabled: widget.danmakuEnabled,
            onToggleDanmaku: widget.onToggleDanmaku,
            // 官方 `jm3.t0`：行尾当前档 + 点击级联打开字号弹层。
            fontScaleLabel: ShortSeriesFontScale.label,
            onOpenFontSettings: () => _pendingFontScale = true,
            onOpenListenMode: widget.onOpenListenMode,
            onOpenOfflineCache: widget.onOpenOfflineCache,
          );
        }
        return widget.shortSeries
            ? PlayletMorePanel(
                rate: _rate,
                fillScreen: widget.fillScreen,
                onFillScreenChanged: widget.onFillScreenChanged,
                defaultMute: widget.defaultMute,
                onDefaultMuteChanged: widget.onDefaultMuteChanged,
                danmakuEnabled: widget.danmakuEnabled,
                onToggleDanmaku: widget.onToggleDanmaku,
                // 清屏态面板出口：官方清屏后的倍速文字仍打开面板，
                // 面板内「退出清屏」行回画面（jm3.a 的 p0(!zB0)）。
                // 行随 jm3.a 的门（只看 reverse），不随底栏样式——旧底栏
                // 手机分支栏内无入口，这条是官方给的全部出口。
                clearScreen: _clearScreen,
                onToggleClearScreen: _clearScreenPanelAvailable
                    ? () => _setClearScreen(!_clearScreen)
                    : null,
                // 官方 jm3.e：弹幕设置入口在弹幕开关之后。
                onOpenDanmakuSettings: widget.onDanmakuSettingsChanged != null
                    ? () {
                        _pendingDanmakuSettings = true;
                        Navigator.pop(context);
                      }
                    : null,
                qualityVariants: widget.qualityVariants,
                currentQualityUrl: widget.currentQualityUrl,
                onQualitySelected: widget.onQualitySelected,
              )
            : StatefulBuilder(
              builder: (context, setSheetState) => SafeArea(
                top: false,
                // 面板会随大字体变高；矮窗口下必须可滚，否则 RenderFlex 溢出
                // （官方面板本身就是 RecyclerView）。
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        key: const ValueKey('player-more-rate-row'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 10),
                            child: Text(
                              '倍速',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF1B1B1B),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final rate
                                    in PlayerPreferences.playbackRates)
                                  ChoiceChip(
                                    label: Text(_rateChipLabel(rate)),
                                    selected: rate == _rate,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    onSelected: (_) =>
                                        Navigator.pop(context, rate),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // 官方更多面板第 5 行：弹幕开关（`oi3/k.java:554-568`，
                      // SP `video_danmaku_switch_sp/key_enable_danmaku_by_user`）。
                      // 只有宿主提供了开关回调时才出现。
                      if (widget.onToggleDanmaku != null) ...[
                        const SizedBox(height: 12),
                        Row(
                          key: const ValueKey('player-more-danmaku-row'),
                          children: [
                            const Text(
                              '弹幕',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF1B1B1B),
                              ),
                            ),
                            const Spacer(),
                            Switch(
                              key: const ValueKey('player-more-danmaku-switch'),
                              value: sheetDanmaku,
                              onChanged: widget.onToggleDanmaku == null
                                  ? null
                                  : (value) {
                                      widget.onToggleDanmaku!.call();
                                      setSheetState(() => sheetDanmaku = value);
                                    },
                            ),
                          ],
                        ),
                      ],
                      // 官方更多面板：默认静音行（`tm3.b`，只存在内存里）。
                      if (widget.onDefaultMuteChanged != null) ...[
                        const SizedBox(height: 12),
                        _sheetSwitch(
                          'player-more-mute-row',
                          'player-more-mute-switch',
                          '默认静音',
                          sheetMute,
                          onChanged: (value) {
                            widget.onDefaultMuteChanged!.call(value);
                            setSheetState(() => sheetMute = value);
                          },
                        ),
                      ],
                      // 官方更多面板：画面撑满行（SP `is_fill_screen`）。
                      if (widget.onFillScreenChanged != null) ...[
                        const SizedBox(height: 12),
                        _sheetSwitch(
                          'player-more-fill-row',
                          'player-more-fill-switch',
                          '画面撑满',
                          sheetFill,
                          onChanged: (value) {
                            widget.onFillScreenChanged!.call(value);
                            setSheetState(() => sheetFill = value);
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
      }
    );
    if (!mounted) return;
    setState(() => _modalOpen = false);
    // 浅色支回传 EpisodeVariant（清晰度），深色支回传 double（倍速）。
    if (selected is EpisodeVariant) {
      widget.onQualitySelected?.call(selected);
    } else if (selected is double) {
      final rate = selected;
      final generation = ++_rateGeneration;
      setState(() => _rate = rate);
      try {
        // Persist in selection order. A slow reply to an older native rate
        // change must not save that value after the user's newer selection.
        await Future.wait<void>([
          PlayerPreferences.savePlaybackRate(rate),
          _control((player) => player.setRate(rate)),
        ]);
      } catch (_) {
        if (mounted && generation == _rateGeneration) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('倍速已生效，但未能保存设置')));
        }
      }
    }
    // 更多面板里的「弹幕设置」：等面板收起后再级联打开设置面板，
    // 避免 _modalOpen 的置位被 _showRates 的收尾覆盖。
    if (_pendingDanmakuSettings) {
      _pendingDanmakuSettings = false;
      unawaited(_showDanmakuSettings());
      return;
    }
    // 「字体大小」同款级联（官方 `jm3.t0.m()`：面板收起 → 字号弹层）。
    if (_pendingFontScale) {
      _pendingFontScale = false;
      unawaited(_showFontScaleSheet());
      return;
    }
    if (mounted) _scheduleHide();
  }

  /// 官方更多面板的开关行：整行可点、Switch 自身由行承担点击
  /// （官方的 `SwitchButtonV2` 都调用 `setClickable(false)`）。
  Widget _sheetSwitch(
    String rowKey,
    String switchKey,
    String label,
    bool value, {
    required ValueChanged<bool> onChanged,
  }) => GestureDetector(
    key: ValueKey(rowKey),
    behavior: HitTestBehavior.opaque,
    onTap: () => onChanged(!value),
    child: Row(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF1B1B1B)),
        ),
        const Spacer(),
        Switch(key: ValueKey(switchKey), value: value, onChanged: onChanged),
      ],
    ),
  );

  void _openPanel() {
    if (_locked || _overlayOpen || _panelOpen) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _panelDrawer = widget.shortSeries && _isLandscape;
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
    // 跳集与换播放器并发时，sheet 的 scroll position 可能被重建替换，
    // animateTo 的 future 会**永不完成**（真机实测：extent 冻结在 0.64，
    // 面板悬空遮住画面，点遮罩才能恢复）。超时兜底让收起流程必然收敛；
    // 用户拖动打断的场景由下方计数守卫接管，不受超时影响。
    await _panel
        .animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        )
        .timeout(const Duration(milliseconds: 300), onTimeout: () {});
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
    _doubleTapGuard?.cancel();
    // 官方在 Activity 退出横屏时无条件解锁（`EXIST_LAND_ACTIVITY`）。
    if (_fullScreen) _releaseLock();
    setState(() => _fullScreen = !_fullScreen);
    await _applySystemUi();
    if (mounted) {
      setState(() {});
      _scheduleHide();
    }
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

  /// 官方「画面撑满」（SP `is_fill_screen`）：只改画面铺排，
  /// 不打断播放。`fillsFrame` 为假的横版片源会被降级成按宽度铺满，
  /// 与官方 `ShortVideoCropConfig.landscapeRatio` 的规则一致。
  VideoFit get _videoFit =>
      widget.fillScreen ? VideoFit.fillFrame : VideoFit.contain;

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

  /// 画面是否处于横屏全屏态。锁只在横屏有效，退出横屏即解锁。
  bool get _isLandscape {
    return _fullScreen && _viewportSize.width > _viewportSize.height;
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
    child: _buildChrome(context),
  );

  Widget _buildChrome(BuildContext context) {
    // 官方字号档（`jk3/b`：标准 1.0/大号 1.15/超大号 1.3）作用在播放页
    // UI 文本上：外层 scaler 再乘档位系数。弹幕层在内部单独还原外层
    // scaler（弹幕有自己的字号配置，官方 `ShortSeriesScaleTextView`
    // 也不覆盖弹幕）。弹出的 sheet 走根 Navigator 的 overlay，不受此作用域影响。
    final outerScaler = MediaQuery.textScalerOf(context);
    final scaledScaler = TextScaler.linear(
      outerScaler.scale(14) * ShortSeriesFontScale.scale / 14,
    );
    return PopScope(
    canPop: !_panelOpen && !_fullScreen,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && (_panelOpen || _fullScreen)) unawaited(_back());
    },
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: scaledScaler),
      child: Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final insets = MediaQuery.paddingOf(context);
          final window = constraints.biggest;
          _viewportSize = window;
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
          final unobstructed = !_panelOpen && !_overlayOpen;
          // 退出横屏运行时解锁：官方 Activity 销毁时用 EXIST_LAND_ACTIVITY
          // 复位全局锁态，本地没有独立 Activity，只能在布局里对账。
          if (_locked && !landscape) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_isLandscape) setState(_releaseLock);
            });
          }
          // 锁定时官方整条控件/清屏链路被吞（fullscreen/d.H6() 与
          // jq3/x.q 的 B4()/G6() 早退），只留锁按钮本身。
          final showChrome = unobstructed && !_clearScreen && !_locked;
          final controls = _visible && showChrome && !_seeking;
          // 短剧竖屏双击点赞按用户要求移除；单击仍控制播放。
          // 横屏单击切换控件，双击播放继续由横屏配置控制。
          final portraitSeries = widget.shortSeries && !landscape;
          final catalogStyle = _catalogStyle && !landscape;
          final tapTogglesPlayback =
              widget.shortSeries && (!landscape || _clearScreen);
          final canPage =
              unobstructed && !_seeking && !_boosting && !_locked && !landscape;
          // 短剧横屏底条（批次四）：官方 `c0i.xml` + `cw7.xml` 的形态，
          // 替换通用运输条在此朝向的全部残留（prev/±10/全屏钮）。
          final landscapeBar = widget.shortSeries && landscape;
          // 自动收起保留信息区，清屏则统一隐藏；计时器不是清屏状态来源。
          final bandVisible =
              widget.shortSeries &&
              !landscape &&
              _ready &&
              !_visible &&
              !_seeking &&
              showChrome;
          // 热评只在信息区可见时出现；新栏采用截图中的无底色信息行。
          final hotBar =
              widget.shortSeries &&
              !_locked &&
              !_clearScreen &&
              !_seeking &&
              widget.hotComments.isNotEmpty &&
              (controls || bandVisible);
          final showTextActions =
              widget.shortSeries &&
              unobstructed &&
              !_locked &&
              !_seeking &&
              ((!landscape && !catalogStyle) || _clearScreen);
          // 旧底栏清屏/还原只在 pad 配置开启时出现（`jj3/i.java:620-637`）。
          // 手机旧栏项序「清晰度 / 倍速」（bom.xml），清晰度仅多档流在场。
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                key: const ValueKey('video-surface'),
                behavior: HitTestBehavior.opaque,
                // 官方 G6()：锁定后触摸只切换锁按钮的可见性。
                onTap: () {
                  if (!unobstructed) return;
                  if (_locked) {
                    _refreshLockVisibility();
                  } else if (!(_doubleTapGuard?.isActive ?? false)) {
                    tapTogglesPlayback ? _togglePlayback() : _toggleControls();
                  }
                },
                onDoubleTapDown: (details) =>
                    _doubleTapDownPosition = details.localPosition,
                // Note: 官方短剧双击从不切播放，`video_landscape_style_609`
                // 是点赞皮肤键（原挪用已删）— 见
                // .agents/notes/implemented/bug-fix/2026-09-27-playlet-evidence-flips.md
                onDoubleTap: () {
                  if (!unobstructed) return;
                  if (_locked) {
                    _refreshLockVisibility();
                  } else if (portraitSeries) {
                    // 保留吞单击窗口，避免双击尾部的触摸误切播放状态。
                    if (_ready && !_clearScreen) _guardDoubleTap();
                  } else if (!widget.shortSeries) {
                    _togglePlayback();
                  } else {
                    // 官方短剧双击从不切换播放（jq3/x$q.onDoubleTap
                    // :2155-2188）：中带（y ∈ 44dp..屏高-240dp）触发
                    // x.X6()->o.x7()->fullscreen/c 的横屏控制条隐藏。
                    _guardDoubleTap();
                    final position = _doubleTapDownPosition;
                    final height = window.height;
                    if (landscape &&
                        !_clearScreen &&
                        _visible &&
                        position != null &&
                        height > 0 &&
                        position.dy > 44 &&
                        position.dy < height - 240) {
                      _hideTimer?.cancel();
                      setState(() => _visible = false);
                    }
                  }
                },
                onHorizontalDragStart: _startDragSeek,
                onHorizontalDragUpdate: _updateDragSeek,
                onHorizontalDragEnd: _endDragSeek,
                // 官方长按分两支（jq3/x.java:2250-2252）：横向中心带
                // （K6():2690-2711，竖屏 50%/横屏 33% 宽，Y 不限）命中且
                // y7() 处理成功 → 打开「show_more_panel_from_long_click」
                // 的更多面板；带外（或非短剧）才是倍速覆盖层。
                onLongPressStart: (details) {
                  if (_locked) {
                    _refreshLockVisibility();
                    return;
                  }
                  if (widget.shortSeries &&
                      _inLongPressBand(details.localPosition.dx)) {
                    if (!_seeking && !_paging) _showRates();
                    return;
                  }
                  _startBoost();
                },
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
              // 弹幕层：官方在竖屏画面内滚动，锁屏/清屏时隐藏
              // （container/l.java 的渲染参数未取证，这里只放已证时间轴语义）。
              if (widget.shortSeries &&
                  widget.danmakuEnabled &&
                  !_locked &&
                  !_clearScreen &&
                  widget.danmaku.isNotEmpty)
                Positioned.fill(
                  child: SafeArea(
                    bottom: false,
                    child: KeyedSubtree(
                      key: ObjectKey(widget.player),
                      // 弹幕不受官方字号档影响（弹幕有自己的字号配置）：
                      // 还原外层 textScaler。
                      child: MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          textScaler: outerScaler,
                        ),
                        child: PlayletDanmakuLayer(
                          key: const ValueKey('player-danmaku-layer'),
                          entries: widget.danmaku,
                          position: _position,
                          rate: _boosting ? 2 : _rate,
                          // 官方横屏飞行 12000ms、竖屏 10000ms。
                          landscape: landscape,
                          settings: widget.danmakuSettings,
                          playing:
                              _ready &&
                              widget.playing &&
                              !(widget.player?.buffering ?? false) &&
                              _appActive &&
                              !_seeking &&
                              !_dragSeekActive,
                        ),
                      ),
                    ),
                  ),
                ),
              // 「左右滑动可调整进度」首次引导（`@string/cha`，距底 138dp，
              // `o.java K6` 的引导层）。
              if (widget.showSeekHint && showChrome && widget.enabled)
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
                if (!landscape && !catalogStyle) _rightBar(insets),
              ],
              if (catalogStyle && (controls || bandVisible))
                _portraitControls(
                  insets: insets,
                  videoBottom: layout.video.intersect(layout.viewport).bottom,
                  controls: controls,
                  hotBar: hotBar,
                ),
              // 信息层/选集胶囊压在进度条与画面之上，但必须保持transport在
              // 其上方（Stack 后者在上）：通用播放器的运输条按钮不能被信息
              // 层的渐变 Container 挡住点击。
              if ((!catalogStyle && !landscape && (controls || bandVisible)) ||
                  showTextActions)
                Positioned(
                  left: insets.left,
                  right: insets.right,
                  bottom:
                      insets.bottom +
                      (widget.shortSeries ? (landscape ? 16 : 56) : 96),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!landscape && (controls || bandVisible))
                        _information(showPill: controls, showBook: bandVisible),
                      // 官方热评胶囊在信息面板下方（\`e0.java:2136-2161\` 的
                      // "below_abstract" 位），只在有热评时出现。
                      if (!landscape && hotBar)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: PlayletHotCommentBar(
                            comments: widget.hotComments,
                            onTap: widget.onHotCommentTap,
                            // 官方 sel&&vis：页面不可见或被弹层遮挡即停表。
                            active:
                                _appActive && !_overlayOpen && !_panelOpen,
                          ),
                        ),
                      // 标题/原著卡排在操作行上方，文字放大时也不占它的点击区。
                      if (showTextActions)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _screenTexts(),
                          ),
                        ),
                    ],
                  ),
                ),
              if (!landscape && (controls || bandVisible))
                _catalogBar(insets, compact: catalogStyle),
              // 官方播放页（`apf.xml`）竖屏没有运输条；运输条只剩通用
              // 播放器（详情页影视）在用，短剧两个朝向都不走它。
              if (controls && _ready && !widget.shortSeries)
                _transport(insets, landscape),
              if (landscapeBar &&
                  _ready &&
                  showChrome &&
                  (_visible || _seeking))
                _landscapeBar(insets),
              if ((_visible || _seeking || bandVisible) &&
                  showChrome &&
                  _ready &&
                  !landscapeBar)
                Positioned(
                  // Controls leave this Stack while seeking. Keep the outer
                  // layer keyed so the active drag recognizer survives that
                  // sibling change until the finger is released.
                  key: const ValueKey('video-seek-layer'),
                  left: insets.left + (catalogStyle ? 16 : 12),
                  right: insets.right + (catalogStyle ? 16 : 12),
                  // 新栏的 30dp 进度触区止于选集/清屏的 48dp 触区上沿。
                  bottom:
                      insets.bottom +
                      (catalogStyle ? 60 : (widget.shortSeries ? 41 : 60)),
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
                        trackWidth: catalogStyle ? 4 : 2,
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
                  showChrome &&
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
                          seriesTitle: widget.seriesTitle,
                          seriesCover: widget.seriesCover,
                          episodeLabel: widget.episodeLabel,
                          // 选集面板头部箭头与播放页标题行同一路跳转
                          // （官方详情入口）。
                          onOpenSeries: widget.onOpenSeriesDetail,
                          relateBook: widget.relateBook,
                          onOpenRelateBook: widget.onOpenRelateBook,
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
                      builder: (context, child) =>
                          Opacity(opacity: _panelStrength, child: child),
                    ),
                  ),
                ),
              ],
              _lockButton(window),
            ],
          );
        },
      ),
      ),
    ),
    );
  }

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
        // 官方「画面撑满」只换铺排方式，不动解码与进度：本地用同一套
        // PlayerVideoLayout，切换 fillFrame/contain 即可，无需重新起播。
        fit: _videoFit,
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

  /// 追剧、点赞、分享移除后，右侧只保留已接入的评论入口。
  Widget _rightBar(EdgeInsets insets) {
    if (widget.onComments == null) return const SizedBox.shrink();
    return Positioned(
      right: insets.right + 12,
      bottom: insets.bottom + 172,
      child: _commentButton(),
    );
  }

  Widget _commentButton() => Semantics(
    button: true,
    label: '评论',
    child: GestureDetector(
      key: const ValueKey('player-comment-button'),
      onTap: widget.onComments,
      behavior: HitTestBehavior.opaque,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/drama/rail_comment.webp',
              width: 46,
              height: 46,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 2),
            Text(
              PlayletCommentPage.entryLabel(widget.commentCount),
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
      ),
    ),
  );

  /// 按视频下沿放全屏/评论，并用实际信息区高度让位，避免长字和原著卡
  /// 挤住按钮。空白区域不参与命中测试，仍交给画面手势。
  Widget _portraitControls({
    required EdgeInsets insets,
    required double videoBottom,
    required bool controls,
    required bool hotBar,
  }) => Positioned.fill(
    child: CustomMultiChildLayout(
      delegate: _PortraitControlsLayout(
        insets: insets,
        videoBottom: videoBottom,
      ),
      children: [
        LayoutId(
          id: _PortraitSlot.information,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _information(showPill: false, showBook: false),
              if (hotBar)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: PlayletHotCommentBar(
                    comments: widget.hotComments,
                    onTap: widget.onHotCommentTap,
                    active: _appActive && !_overlayOpen && !_panelOpen,
                  ),
                ),
              if (widget.originalBook != null)
                _originalBookCard(widget.originalBook!, edgeToEdge: true)
              else
                // 无原著条承接进度线时，热评触区必须留在进度触区之上。
                const SizedBox(height: 24),
            ],
          ),
        ),
        if (controls)
          LayoutId(id: _PortraitSlot.fullscreen, child: _fullscreenPill()),
        if (controls && widget.onComments != null)
          LayoutId(id: _PortraitSlot.comments, child: _commentButton()),
      ],
    ),
  );

  /// 新底栏文字样式来自 `SingleVideoHolder.q8()`；48dp 点击区是本地取舍。
  /// 操作行独立于标题高度，窄屏大字可换行（源码对照文档 §32）。
  Widget _screenTexts() => widget.newPlayerBottomStyle || widget.hasBanner
      ? Wrap(
          alignment: WrapAlignment.end,
          spacing: 0,
          runSpacing: 4,
          children: [
            _screenTextButton('player-rate-text', _rateText(_rate), _showRates),
            if (_clearScreenAvailable)
              _screenTextButton(
                'player-clear-screen',
                _clearScreen ? '恢复' : '清屏',
                () => _setClearScreen(!_clearScreen),
              ),
          ],
        )
      : _legacyBottomActions();

  /// bom.xml：手机旧栏无清屏；pad 分支是 28dp 图标 + 2dp 间距 + 文案。
  /// 官方项序「清晰度 → 倍速」（`bom.xml`：`@drawable/b2s`+`@string/dqa`
  /// 在 `b2t`+`eby` 之前），清晰度仅多档流在场时出现（与面板同门，
  /// `oi3/k.P()`），单流不冒充官方恒显的分辨率名。
  Widget _legacyBottomActions() => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: Wrap(
      key: const ValueKey('player-legacy-actions'),
      alignment: WrapAlignment.end,
      spacing: 16,
      children: [
        if (widget.qualityVariants.length > 1)
          _legacyAction(
            'player-quality-text',
            _qualityLabel(),
            const SizedBox(
              width: 28,
              height: 28,
              child: CustomPaint(painter: QualityIconPainter()),
            ),
            _showRates,
          ),
        _legacyAction(
          'player-rate-text',
          _rateText(_rate),
          const SizedBox(
            width: 28,
            height: 28,
            child: CustomPaint(painter: _LegacyRatePainter()),
          ),
          _showRates,
        ),
        if (_clearScreenAvailable)
          _legacyAction(
            'player-clear-screen',
            _clearScreen ? '还原' : '清屏',
            _clearScreen
                ? Image.asset(
                    'assets/images/drama/legacy_restore.webp',
                    width: 20,
                    height: 20,
                  )
                : SizedBox(
                    width: 28,
                    height: 28,
                    child: Lottie.asset(
                      'assets/lottie/immersive_mode_on_v2.json',
                      animate: false,
                    ),
                  ),
            () => _setClearScreen(!_clearScreen),
          ),
      ],
    ),
  );

  Widget _legacyAction(
    String key,
    String label,
    Widget icon,
    VoidCallback onTap,
  ) => Semantics(
    button: true,
    child: GestureDetector(
      key: ValueKey(key),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _screenTextButton(String key, String label, VoidCallback onTap) =>
      Semantics(
        button: true,
        child: GestureDetector(
          key: ValueKey(key),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// 当前短剧截图使用 `aqh.xml` 的 5dp 纵向内边距；通用播放器保留
  /// `aqi.xml` 的 8dp。官方存在配置分支，不能把其中一套当作唯一规格。
  Widget _fullscreenPill() => Semantics(
    button: true,
    child: GestureDetector(
      key: const ValueKey('player-fullscreen-pill'),
      onTap: _toggleFullScreen,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: widget.shortSeries ? 5 : 8,
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
            const Flexible(
              child: Text(
                '全屏观看',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 新栏由 `_portraitControls` 分开定位全屏按钮与信息区；旧栏和通用
  /// 播放器保留列布局。原著数据来自 `/related`，无数据不填占位卡片。
  Widget _information({required bool showPill, required bool showBook}) {
    return Container(
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
          if (showPill) Center(child: _fullscreenPill()),
          if (showPill) const SizedBox(height: 12),
          // 官方标题行整行可点（ql3/v0 `a1()`，埋点 enter_from="title"），
          // 落点是剧集详情页。
          GestureDetector(
            key: const ValueKey('player-series-title'),
            onTap: widget.onOpenSeriesDetail,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    _seriesTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: widget.shortSeries ? 16 : 20,
                      fontWeight: FontWeight.bold,
                      shadows: const [
                        Shadow(color: Colors.black45, blurRadius: 8),
                      ],
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
    );
  }

  /// 原著书卡（官方截图第二十二轮）：深色圆角条，白色小方徽 + 深色书本
  /// 图标 + 「原著《书名》」14sp bold 白 + 8×16dp 右箭头（`info_arrow`），
  /// 点击进原著详情页（`/related` kind=book，audio 页同一条跳转链路）。
  Widget _originalBookCard(RelatedWork book, {bool edgeToEdge = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: GestureDetector(
          key: const ValueKey('player-original-book'),
          onTap: widget.onOpenOriginalBook,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: edgeToEdge ? 16 : 12),
            decoration: BoxDecoration(
              color: edgeToEdge
                  ? const Color(0xFF1C1C1C)
                  : const Color(0x14FFFFFF),
              borderRadius: edgeToEdge
                  ? const BorderRadius.vertical(bottom: Radius.circular(12))
                  : BorderRadius.circular(10),
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
                  child: Image.asset(
                    'assets/images/drama/info_arrow.webp',
                    fit: BoxFit.contain,
                  ),
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
  /// （官方文案 `@string/e6r`「全%s集」）。
  Widget _catalogBar(EdgeInsets insets, {bool compact = false}) {
    final catalog = GestureDetector(
      key: const ValueKey('player-catalog-bar'),
      onTap: _openPanel,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 48,
        child: Center(
          child: Container(
            height: compact ? 40 : 48,
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
      ),
    );
    return Positioned(
      left: insets.left + (compact ? 16 : 12),
      right: insets.right + (compact ? (_clearScreenAvailable ? 8 : 16) : 12),
      bottom: insets.bottom + (compact ? 12 : 8),
      child: compact
          ? Row(
              children: [
                Expanded(child: catalog),
                if (_clearScreenAvailable) ...[
                  const SizedBox(width: 4),
                  _clearScreenIcon(),
                ],
              ],
            )
          : catalog,
    );
  }

  Widget _clearScreenIcon() => Semantics(
    label: '清屏',
    button: true,
    child: GestureDetector(
      key: const ValueKey('player-clear-screen'),
      onTap: () => _setClearScreen(true),
      behavior: HitTestBehavior.opaque,
      child: const SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            key: ValueKey('player-clear-icon'),
            width: 28,
            height: 28,
            child: Center(
              child: CustomPaint(
                size: Size(20, 23),
                painter: _ClearScreenIconPainter(),
              ),
            ),
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

  /// 当前播放档位的显示名（官方横屏/旧栏直接亮档名，如「720P」；
  /// `jj3/i.e` 选中后 C(resolution) 更新同一文本）。
  String _qualityLabel() {
    for (final variant in widget.qualityVariants) {
      if (variant.url == widget.currentQualityUrl) return variant.name;
    }
    return '清晰度';
  }

  /// 官方横屏底条（官方截图第二十三轮，真实 app 形态，替代第二十一轮按
  /// `c0i/cw7` 取证的单行布局）：130dp 渐变上两行——
  /// - 控制行：播放/暂停 32dp（`btu/btv`）→ 下一集 32dp（仅集数>1）→
  ///   当前时长（拖动中实时）→ 橙色进度条（轨道 4/滑块 16）→ 总时长；
  ///   时长恒 `HH:MM:SS`（`o2()` → `d7.o(sec, true)`，截图 00:00:02/00:02:05）。
  /// - 功能行：清晰度（多档流在场时）、倍速文本、选集（仅集数>1）；
  ///   追剧与点赞按用户要求移除。官方该行还有评论计数、弹幕开关+弹幕输入框
  ///   ——无数据源，不显示（诚实清单）。
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
                const Spacer(),
                // 官方功能行序：… 720P 清晰度 → 倍速 → 选集（横屏控制条
                // 第二十三轮）。清晰度与倍速在官方同开 jj3.q 弹层（速率 +
                // 分辨率一屏），这里同样都进更多面板。
                if (widget.qualityVariants.length > 1) ...[
                  _landText('landscape-quality', _qualityLabel(), _showRates),
                  const SizedBox(width: 24),
                ],
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

  /// 官方横屏防误触锁（`fullscreen/d.J6()`，配置门 `landscape_func_config_v705
  /// .enable_lock`，默认关闭）：右缘偏上、`marginEnd = 屏宽 × 0.11`，36dp 的
  /// `unlock_speed.json`（帧 0 解锁 / 帧 20 锁定）。未锁定时随控件条出现，
  /// 锁定后 5 秒自动隐藏，任意触摸把它重新唤出（`d.G6()`）。
  Widget _lockButton(Size window) {
    if (!widget.shortSeries ||
        !widget.landscapeLockEnabled ||
        !_isLandscape ||
        _clearScreen ||
        _panelOpen ||
        _overlayOpen ||
        !_ready) {
      return const SizedBox.shrink();
    }
    if (!_locked && !_visible) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      right: math.max(window.width * .11, 24),
      child: SafeArea(
        child: IgnorePointer(
          ignoring: !_lockVisible,
          child: Semantics(
            button: true,
            label: _locked ? '解锁屏幕' : '锁定屏幕',
            child: GestureDetector(
              key: const ValueKey('landscape-lock'),
              behavior: HitTestBehavior.opaque,
              onTap: _toggleLock,
              // 官方对锁按钮注册了吞掉长按的监听器（`uk3/c.java:237-243`），
              // 避免长按穿透到画面的临时倍速。
              onLongPress: () {},
              child: SizedBox(
                width: 48,
                height: 48,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: _lockVisible ? 1 : 0,
                  child: Center(
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Lottie.asset(
                        'assets/lottie/unlock_speed.json',
                        // 官方 `uk3/c.j(z)`：锁 → 从第 20 帧反向播，解锁 → 从 0 帧正向播。
                        controller: _lockController,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stack) => Icon(
                          _locked
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                          size: 28,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 官方横屏时长格式（`o2()` → `d7.o(sec, true)`）：恒 `HH:MM:SS`，
  /// 与共享的 `mm:ss` 格式器（音频页同源）分开。
  String _hms(Duration value) {
    final seconds = value.inSeconds.clamp(0, 0x7fffffff);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(seconds ~/ 3600)}:${p((seconds % 3600) ~/ 60)}:${p(seconds % 60)}';
  }

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

/// 官方旧栏 drawable/b2t.xml 的 28dp 倍速图标。
class _LegacyRatePainter extends CustomPainter {
  const _LegacyRatePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 28, size.height / 28);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(8.408, 7.35)
        ..cubicTo(5.331, 10.004, 5.331, 14.001, 5.331, 14.001)
        ..cubicTo(5.331, 18.787, 9.211, 22.667, 13.997, 22.667)
        ..cubicTo(18.784, 22.667, 22.664, 18.787, 22.664, 14.001)
        ..cubicTo(22.664, 9.214, 18.784, 5.334, 13.997, 5.334)
        ..cubicTo(13.997, 6.249, 13.997, 7.741, 13.997, 7.741),
      paint,
    );
    canvas.drawLine(
      const Offset(16.164, 11.834),
      const Offset(11.831, 16.167),
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LegacyRatePainter oldDelegate) => false;
}

enum _PortraitSlot { information, fullscreen, comments }

class _PortraitControlsLayout extends MultiChildLayoutDelegate {
  _PortraitControlsLayout({required this.insets, required this.videoBottom});

  final EdgeInsets insets;
  final double videoBottom;

  @override
  void performLayout(Size size) {
    final width = math.max(0.0, size.width - insets.horizontal);
    final information = layoutChild(
      _PortraitSlot.information,
      BoxConstraints.tightFor(width: width),
    );
    final minimumTop = insets.top + 56;
    final informationTop = math.max(
      minimumTop,
      size.height - insets.bottom - 72 - information.height,
    );
    positionChild(
      _PortraitSlot.information,
      Offset(insets.left, informationTop),
    );

    if (!hasChild(_PortraitSlot.fullscreen)) return;
    final pill = layoutChild(
      _PortraitSlot.fullscreen,
      BoxConstraints(maxWidth: math.max(0.0, width - 144)),
    );
    final comments = hasChild(_PortraitSlot.comments)
        ? layoutChild(
            _PortraitSlot.comments,
            const BoxConstraints(maxWidth: 64),
          )
        : Size.zero;
    final actionHeight = math.max(pill.height, comments.height - 4);
    final maximumTop = math.max(minimumTop, informationTop - actionHeight - 16);
    final top = math.min(math.max(videoBottom + 20, minimumTop), maximumTop);
    positionChild(
      _PortraitSlot.fullscreen,
      Offset(insets.left + (width - pill.width) / 2, top),
    );
    if (hasChild(_PortraitSlot.comments)) {
      positionChild(
        _PortraitSlot.comments,
        Offset(size.width - insets.right - 4 - comments.width, top - 4),
      );
    }
  }

  @override
  bool shouldRelayout(_PortraitControlsLayout oldDelegate) =>
      insets != oldDelegate.insets || videoBottom != oldDelegate.videoBottom;
}

class _ClearScreenIconPainter extends CustomPainter {
  const _ClearScreenIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(1, size.height / size.width);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * scale
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    const badge = Offset(17.9, 17.6);
    final page = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3.2 * scale, 3.2 * scale, 16.3 * scale, 17.6 * scale),
          Radius.circular(4 * scale),
        ),
      );
    final center = Offset(badge.dx * scale, badge.dy * scale);
    final cut = Path()
      ..addOval(Rect.fromCircle(center: center, radius: 6.1 * scale));
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        cut,
      ),
    );
    canvas.drawPath(page, stroke);
    canvas.restore();
    canvas.drawLine(
      Offset(7.8 * scale, 9 * scale),
      Offset(16.4 * scale, 9 * scale),
      stroke..strokeWidth = 1.5 * scale,
    );
    canvas.drawLine(
      Offset(7.8 * scale, 13 * scale),
      Offset(15.2 * scale, 13 * scale),
      stroke,
    );
    final radius = 4.4 * scale;
    canvas.drawCircle(center, radius, stroke);
    final diagonal = radius / math.sqrt2;
    canvas.drawLine(
      Offset(center.dx - diagonal, center.dy + diagonal),
      Offset(center.dx + diagonal, center.dy - diagonal),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ClearScreenIconPainter oldDelegate) => false;
}

/// 官方倍速文案（`SingleVideoHolder.java:1155-1171`）：1.0 显示「倍速」，
/// 其余 `数值x`（如 `1.5x`）。
String _rateText(double rate) => rate == 1 ? '倍速' : '${_rateLabel(rate)}x';

/// 官方档位 chip 文案（`ShortSeriesMorePanelDialogV2.java:873-892`）：
/// `0.75x / 1x / 1.25x / 1.5x / 1.75x / 2x`。
String _rateChipLabel(double rate) => '${_rateLabel(rate)}x';

String _time(Duration value) => formatPlaybackTime(value);
