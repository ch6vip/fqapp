import '../services/desktop_platform.dart';
import 'desktop_video_chrome.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';

import '../models/audio_extra.dart';
import '../models/media_item.dart';
import '../services/episode_source_cache.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/playback_gesture_levels.dart';
import '../services/player_layout_preferences.dart';
import '../services/player_preferences.dart';
import '../services/player_style_config.dart';
import '../services/player_system_ui.dart';
import '../services/short_series_font_scale.dart';
import '../models/playlet_comment.dart';
import 'home/home_design.dart';
import 'player/playlet_clear_screen_button.dart';
import 'player/playlet_danmaku_layer.dart';
import 'player/playlet_danmaku_settings.dart';
import 'player/playlet_font_scale_sheet.dart';
import 'player/playlet_fullscreen_pill.dart';
import 'player/story_player_panel.dart';
import 'player/playlet_hot_comment_bar.dart';
import 'player/playlet_more_panel.dart';
import 'player/playlet_split_status_bar.dart';
import 'player/playlet_more_panel_light.dart';
import 'player/playlet_more_panel_side.dart';
import 'player/playlet_option_sheet.dart';
import 'player/quality_icon.dart';
import 'player/player_cover.dart';
import 'player/player_side_panel.dart';
import 'player/player_split_panel.dart' show SplitPanelAxis;
import 'player/player_toast.dart';
import 'player/player_video_layout.dart';
import 'player/story_seek_bar.dart';

// Note: 移除短剧互动入口的范围见
// .agents/notes/implemented/simplification/2026-09-26-playlet-social-controls.md
// Note: 截图形态、视频底边定位与触区取舍见
// .agents/notes/implemented/bug-fix/2026-09-26-playlet-portrait-layout.md

/// 分屏视频盒上下滑手势的作用对象。
enum _GestureKind { brightness, volume }

/// 手势 HUD 的状态：类型 + 当前档位（0..1）。
class _GestureHudState {
  const _GestureHudState(this.kind, this.value, {this.unavailable = false});

  final _GestureKind kind;
  final double value;

  /// 原生读不到设备档位（Activity 未附着等）。此时手势无法生效，HUD 改成
  /// 「暂不可用」，不能让用户以为滑动被吞了。
  final bool unavailable;
}

/// 分屏手势提示的一行：图标 + 说明。
class _SplitHintLine extends StatelessWidget {
  const _SplitHintLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: Colors.white70),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          text,
          maxLines: 2,
          style: const TextStyle(fontSize: 11, color: Colors.white),
        ),
      ),
    ],
  );
}

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

  /// 桌面 feed 的滚轮翻剧：宿主（如短剧推荐流）传入时，桌面 chrome 在视频
  /// 区把滚轮上下滚转成 ±1 的切剧请求；节流与边界由宿主负责。null 时
  /// 滚轮在视频区无动作（播放页不切剧）。
  final ValueChanged<int>? onWheelNavigate;
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

  /// 当前集的服务端方向（官方 `VideoInfo.vertical`）。为 null 时退回
  /// [episodes] 里当集的 [Chapter.vertical]；仍未知则保持旧行为（显示
  /// 「全屏观看」）。显隐判据见 `_hideFullscreenPill`。
  final bool? currentEpisodeVertical;

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

  /// 作品简介。桌面宽屏停靠面板在剧名/集数下展示；空串时不出现该段。
  final String synopsis;

  /// 标题行「剧名 >」点击 → 官方进剧集详情页（`series_detail`，ql3/v0
  /// `a1()` 的默认分支）。null 时不响应（非短剧形态）。
  final VoidCallback? onOpenSeriesDetail;
  final VoidCallback? onOpenRelatedSeries;
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
  final Future<void> Function(double)? onPlaybackRateChanged;
  final Future<void> Function(double)? onPlaybackVolumeChanged;

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

  /// 进页即全屏（官方 feed 的横屏钮是独立 `ShortSeriesLandActivity`，
  /// `jq3/x.java:4499`；本地等价是推播放页后立刻进入全屏态并请求横屏，
  /// 见 `_FullscreenRoundButton` 的调用方）。默认 false。
  final bool openFullScreen;

  /// 播放页布局偏好（设置页「外观 → 播放页布局」）。分屏只在宿主传入
  /// [splitPanel] 时生效；桌面走 [DesktopVideoChrome]，不消费该值。
  final PlayerLayoutMode layoutMode;

  /// 分屏下半区（竖屏）或右侧栏（横屏）。null = 退回沉浸式整屏。
  final Widget? splitPanel;

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
    this.onWheelNavigate,
    required this.onSelectEpisode,
    required this.onError,
    this.shortSeries = false,
    this.currentEpisodeVertical,
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
    this.synopsis = '',
    this.onOpenSeriesDetail,
    this.onOpenRelatedSeries,
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
    this.onPlaybackRateChanged,
    this.onPlaybackVolumeChanged,
    this.openFullScreen = false,
    this.layoutMode = PlayerLayoutMode.immersive,
    this.splitPanel,
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

  /// 通用播放器（非短剧）没有底栏当前档，「视频设置」里留一行倍速入口，
  /// 点它级联开档位弹层——与字号/弹幕设置同款「先收面板再开弹层」。
  bool _pendingRatePicker = false;

  /// 「清晰度」同款级联标记（底栏没有当前档可点时，面板里留入口行）。
  bool _pendingQualityPicker = false;

  /// 底栏「倍速」文字此刻是否在场，与 `_buildStage` 的 `showTextActions`
  /// **同一组判据**，但直接由布局状态推出，不读「上一帧 build 的缓存值」：
  /// 分屏切换与面板打开挨着发生时，缓存值可能落后一帧，造成底栏与面板
  /// 两边都没有倍速入口。分屏（compact）走自己的紧凑条，这里恒为 false。
  bool get _bottomRateTextVisible {
    final landscape = _windowLandscape;
    final catalogStyle = _catalogStyle && _portraitBrowse;
    return !_splitActive &&
        widget.shortSeries &&
        !_panelOpen &&
        !_overlayOpen &&
        !_locked &&
        !_seeking &&
        ((!landscape && !catalogStyle) || _clearScreen);
  }

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

  /// 从 feed 的「横屏钮」进来（[VideoPlayerChrome.openFullScreen]）时，
  /// 首次全屏按横屏处理。用户之后自己切全屏就不再沿用：`openFullScreen`
  /// 是整个页面的入场标记，恒为 true，拿它当方向判据会把竖版片源也
  /// 永久锁成横屏。
  bool _entryLandscape = false;
  Size _viewportSize = Size.zero;

  /// 退出全屏后把窗口钉在竖屏：返回键要回到原来的竖屏分屏页（简介 /
  /// 评论 + 选集）。只放开朝向的话，仍横握的设备会立刻转回横屏右栏，
  /// 看起来像「按返回反而进了横屏选集」。
  bool _portraitPinned = false;

  /// 竖屏钉是否因本页被别的路由盖住而暂停。暂停期间不动系统朝向，回到
  /// 本页再把钉恢复（钉属于播放页，不该锁住 push 出去的页面）。
  bool _portraitPinSuspended = false;

  /// 压在本页上的路由动画（0 = 本页在最上）。
  Animation<double>? _coverAnimation;
  bool _routeCovered = false;

  /// 分屏 ↔ 整屏切换会重建 PageView（父级结构变了），新挂上的 pager
  /// 从 `initialPage` 起算。画面层按 `currentIndex` 选视频、封面层按页
  /// 索引选封面，两者错位就是「声音在播、画面只剩封面」。每次 build
  /// 后对账一次，一帧内拉回当前集。
  bool _pagerSyncScheduled = false;

  /// 视频区尺寸：整屏时等于窗口，分屏时等于视频盒。横滑进度与长按中带
  /// 必须映射到这块区域，而不是整窗（左右分栏时整窗宽度会让进度只走一半）。
  Size _stageSize = Size.zero;

  /// 本次 build 是否走了分屏（手势/面板入口在 build 之后读取）。
  bool _splitActive = false;

  /// 上次确定的片源取向（宽 > 高）：换集时新播放器先是 0×0，auto 档靠它沿用。
  bool? _lastSourceWide;

  /// 用户拖过分隔条后的视频区占比（含分隔条，0..1）。null = 用布局默认值。
  ///
  /// 拖动时不走 `setState`：分屏布局单独监听这个值重排，选集面板、弹幕、
  /// 底栏等不跟着每秒重建几十次。
  final _splitRatio = ValueNotifier<double?>(null);

  /// [_splitRatio] 是在哪套轴向上拖出来的：竖屏上下 = false，横屏左右 =
  /// true。两套默认比例量级不同（竖屏约 0.28、横屏约 0.64），旋转后必须
  /// 丢弃旧轴的比例，否则视频区会缩成一条。
  bool? _splitRatioSideBySide;

  /// 下半区/右侧栏是否折叠成纯看视频。退出分屏时复位，比例本身保留。
  bool _splitCollapsed = false;

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

  /// 分屏视频盒的上下滑：左半调亮度、右半调音量。档位只走原生窗口/音频
  /// 通道，HUD 用 ValueNotifier 单独刷新，拖动时不重建整个 chrome。
  final ValueNotifier<_GestureHudState?> _gestureHud =
      ValueNotifier<_GestureHudState?>(null);
  _GestureKind _gestureKind = _GestureKind.volume;
  bool _gestureActive = false;
  double? _gestureBase;
  double _gestureDelta = 0;
  double _gestureHeight = 1;
  double? _gestureSent;
  Timer? _gestureHudTimer;
  double? _brightnessLevel;
  double? _volumeLevel;

  /// 设备音量档数（本机 160）。>0 时 HUD 与下发值都落到真实档位，避免
  /// 「连续百分比」和系统离散档位相差一格。
  int _volumeSteps = 0;
  bool _brightnessOverridden = false;
  bool _readingGestureLevels = false;

  /// 原生确认读不到档位（Activity 已销毁等）。之后起手直接提示「暂不可
  /// 用」，不再静默吞掉滑动。
  bool _gestureReadFailed = false;

  /// 横屏整屏进过一次后预读档位的标记：避免每次 build 都打通道。
  bool _gesturePrimed = false;

  /// 分屏手势提示：每次进播放页只出现一次，3.5 秒后自动淡出。
  bool _splitHintShown = false;
  bool _splitHintVisible = false;
  Timer? _splitHintTimer;

  /// 横版片源的全屏方向：manifest 把 `ShortSeriesLandActivity` 锁成
  /// `userLandscape`，横版片源照旧横过来。
  ///
  /// Note: .agents/notes/implemented/bug-fix/2026-10-19-fullscreen-landscape-alignment.md
  static const _fullScreenLandscapeOrientations = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// 竖版片源（短剧主流形态）的全屏方向：铺满竖屏，不强行横过来。
  static const _fullScreenPortraitOrientations = [DeviceOrientation.portraitUp];

  double get _panelFraction => _panelExtent.value;

  /// 视频区宽度：分屏左右分栏时只有左半区，不能用整窗宽度映射进度。
  double get _stageWidth => _stageSize.width > 0
      ? _stageSize.width
      : MediaQuery.sizeOf(context).width;

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

  /// 片源尺寸是否已就绪。切集瞬间新播放器报 0×0，此时任何「按宽高比」
  /// 的判定都必须沿用现状：`sourceSize` 的 9:16 兜底会把横版片源判成
  /// 竖版，分屏/方向就会在每集开头来回翻一次。
  bool get _sourceKnown {
    final width = widget.player?.videoWidth ?? 0;
    final height = widget.player?.videoHeight ?? 0;
    return width > 0 && height > 0;
  }

  bool get _overlayOpen => _modalOpen || widget.interactionBlocked;
  bool get _playbackRequested =>
      widget.playing ||
      ((widget.player?.playWhenReady ?? false) &&
          !(widget.player?.completed ?? false));

  Size get _videoSize => Size(
    (widget.player?.videoWidth ?? 0).toDouble(),
    (widget.player?.videoHeight ?? 0).toDouble(),
  );

  /// 全屏请求的方向：feed 的「横屏钮」进来（[openFullScreen]）一律横屏；
  /// 其余按片源宽高比，竖版片源铺满竖屏。
  ///
  /// 尺寸未知时返回 null，即不发新请求、保持当前方向。未知在连播切集时
  /// 最常见（新播放器还没解码）：无论按哪边兜底，都会让正在看的方向突然
  /// 翻一下（issue #59 是竖屏兜底造成的回弹）。
  List<DeviceOrientation>? get _fullScreenOrientationsForSource {
    if (_entryLandscape) return _fullScreenLandscapeOrientations;
    final width = widget.player?.videoWidth ?? 0;
    final height = widget.player?.videoHeight ?? 0;
    if (width <= 0 || height <= 0) return null;
    return height > width
        ? _fullScreenPortraitOrientations
        : _fullScreenLandscapeOrientations;
  }

  String get _episodeTitle => widget.episodes.isEmpty
      ? '暂无剧集'
      : widget.episodes[widget.currentIndex].title;
  String get _seriesTitle =>
      widget.title.isEmpty ? _episodeTitle : widget.title;

  /// 官方 `wp3/o1.java:301-347` 的 `isSupportShowLandIcon`：
  /// `saasVideoData != null && !saasVideoData.isVertical()`。竖屏剧集
  /// （`vertical == true`）整颗「全屏观看」不渲染；`vertical` 未知时保持
  /// 显示——官方 `EpisodeInfo.vertical` 是 primitive boolean，Gson 缺字段
  /// 即 false，所以「未知即显示」与官方一致。只影响短剧播放页。
  bool get _hideFullscreenPill {
    if (!widget.shortSeries) return false;
    final vertical =
        widget.currentEpisodeVertical ??
        (widget.currentIndex >= 0 &&
                widget.currentIndex < widget.episodes.length
            ? widget.episodes[widget.currentIndex].vertical
            : null);
    return vertical == true;
  }

  @override
  void initState() {
    super.initState();
    _pages = PageController(initialPage: widget.currentIndex);
    _panel.addListener(_panelChanged);
    _listenToPosition();
    WidgetsBinding.instance.addObserver(this);
    _appActive = playbackAppIsActive(WidgetsBinding.instance.lifecycleState);
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
    // feed 的「横屏钮」只在入场这一次生效；用户之后自己切全屏时不能再
    // 沿用（见 `_entryLandscape`）。
    _entryLandscape = widget.openFullScreen;
    if (widget.openFullScreen) {
      // 官方横屏钮进的是独立横屏 Activity，页面一起来就是横屏全屏，没有
      // 「先竖屏、再点一次」的中间态。这里同等：进页即置全屏态并请求
      // 横屏，随后照常安排控件收起（全屏态下 `_scheduleHide` 不会被
      // 竖屏常驻分支拦住）。
      _fullScreen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_applySystemUi());
        _scheduleHide();
      });
    }
    _scheduleHide();
    _scheduleLockHide();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 「本页被别的路由盖住」用路由自己的 secondaryAnimation 判断：不引入
    // 全局 RouteObserver，测试里的裸 MaterialApp 也能生效。
    final animation = ModalRoute.of(context)?.secondaryAnimation;
    if (identical(animation, _coverAnimation)) return;
    _coverAnimation?.removeListener(_handleCoverChanged);
    _coverAnimation = animation;
    _coverAnimation?.addListener(_handleCoverChanged);
    _handleCoverChanged();
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
    if (_clearScreen &&
        !_clearScreenConfigured &&
        !_clearScreenPanelAvailable) {
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
      _ensurePagerOnCurrent();
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
    _doubleTapGuard?.cancel();
    _lockHideTimer?.cancel();
    _panelDrawerTimer?.cancel();
    _gestureHudTimer?.cancel();
    _splitHintTimer?.cancel();
    _gestureHud.dispose();
    // 手势调过亮度才需要还原：没调过就别去动系统亮度。
    if (_brightnessOverridden) {
      unawaited(PlaybackGestureLevels.resetBrightness());
    }
    _lockController.dispose();
    _pages.dispose();
    _panel.dispose();
    _panelExtent.dispose();
    _splitRatio.dispose();
    _coverAnimation?.removeListener(_handleCoverChanged);
    _coverAnimation = null;
    unawaited(_positionSubscription?.cancel());
    unawaited(_playWhenReadySubscription?.cancel());
    _position.dispose();
    _seekValue.dispose();
    if (_boosting && widget.player != null) {
      unawaited(widget.player!.setRate(_rate).catchError((Object _) {}));
    }
    if (_systemUiTouched) {
      // 离开播放页要把「退出全屏后钉竖屏」一起放开，否则后面的页面
      // 会被一起锁在竖屏。
      unawaited(
        _systemUiUpdates.then((_) => _restoreSystemUi(releasePin: true)),
      );
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
    // `inactive` 只是瞬态打断（下拉通知栏/控制中心/分屏呼出）：应用仍在
    // 前台可见，播放继续；只有 hidden/paused/detached 才表示真正离场。
    if (state == AppLifecycleState.inactive && !isWindowsDesktop) return;
    final active = playbackAppIsActive(state);
    if (!active && _appActive) {
      _appActive = false;
      ++_interaction;
      // 「刚才想播吗」现读播放器，不用 [VideoPlayerChrome.playing] 属性：
      // 桌面 chrome 直接暂停播放器、不经宿主会话，该属性（会话的 playing
      // 通知器，靠 playWhenReady 事件重算）可能还停在暂停前的值，拿它
      // 记账会在回到前台时把用户的手动暂停误恢复。移动端的暂停都经会话
      // 中介，现读结果与旧记账一致。
      final resumePlayer = widget.player;
      _resumeOnForeground =
          _ready &&
          ((resumePlayer?.playing ?? false) ||
              ((resumePlayer?.playWhenReady ?? false) &&
                  !(resumePlayer?.completed ?? false)) ||
              (_seeking && _resumeAfterSeek));
      _cancelSeek(resume: false);
      _endBoost();
      _doubleTapGuard?.cancel();
      _hideTimer?.cancel();
      unawaited(_control((player) => player.pause()));
    } else if (active && !_appActive) {
      _appActive = true;
      if (_resumeOnForeground) unawaited(_control((player) => player.play()));
      _resumeOnForeground = false;
      // 回到前台时系统可能已把系统栏放回来；全屏仍在就重新隐藏（#176）。
      if (_fullScreen && !_routeCovered) {
        _queueSystemUi(() async {
          if (!mounted || !_fullScreen || _routeCovered) return;
          await PlayerSystemUi.hide();
        });
      }
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
    //
    // 「竖屏」按窗口宽高判（`_windowLandscape`），与布局层同源：设备横置
    // 却未点「全屏观看」时也是横屏底条，必须照常 3s 收起，否则控件会一直
    // 压在画面上。
    //
    // 例外：竖屏里点了「全屏观看」时设备没有转向，但用户要的就是沉浸，
    // 控件必须能收起——否则只会把按钮文案换成「退出全屏」，画面一点没变
    // （issue #59）。
    if (widget.shortSeries &&
        _catalogStyle &&
        !_windowLandscape &&
        !_fullScreen &&
        !_splitActive) {
      return;
    }
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
  bool get _clearScreenPanelAvailable => !widget.reverseClearScreen && !_locked;

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
      _seekValue.value == null ? 0 : (_seekValue.value! * _stageWidth),
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
    final width = _stageWidth;
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
    // 未就绪时不发 seek：播放器尚未 create，native seek 会丢，
    // 但 onSeeked/_pendingSeek 先写了就会污染后续的相对 seek。
    if (!_ready) return;
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
    // 控制条隐藏时侧边 seek 没有任何视觉反馈：先亮起控制条
    // （进度条随位置更新），再按原计时收起。
    if (mounted) setState(() => _visible = true);
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
    final width = _stageSize.width > 0 ? _stageSize.width : _viewportSize.width;
    final height = _stageSize.height > 0
        ? _stageSize.height
        : _viewportSize.height;
    if (width <= 0) return false;
    // 中带比例只看视频区本身是否宽：横屏整屏、左右分栏的视频盒都取 33%；
    // 竖屏整屏、上下分栏（盒子可能是宽扁裁切）保持 50%。
    final wide = height > 0 && width > height;
    final factor = wide ? 0.33 : 0.5;
    final start = width * (1 - factor) / 2;
    return dx >= start && dx <= width - start;
  }

  /// 上下滑手势的起手：左半边调亮度、右半边调音量。
  ///
  /// 两种形态会走到这里：分屏视频盒（竖直翻页已禁用）与横屏整屏
  /// （`canPage == false`；番茄官方横屏没有这两个手势，按 B站 横屏补齐）。
  /// 竖屏整屏不注册识别器，竖直翻页照旧。
  void _startGesture(DragStartDetails details, Size stage) {
    if ((!_splitActive && !_windowLandscape) ||
        _locked ||
        _seeking ||
        _boosting ||
        stage.width <= 0) {
      return;
    }
    _gestureKind = details.localPosition.dx < stage.width / 2
        ? _GestureKind.brightness
        : _GestureKind.volume;
    _gestureBase = _gestureKind == _GestureKind.brightness
        ? _brightnessLevel
        : _volumeLevel;
    // 上一轮已经确认原生读不到档位：给一次明确反馈后放弃这次手势，避免
    // 用户反复滑动却毫无反馈。
    if (_gestureBase == null && _gestureReadFailed) {
      _showGestureUnavailable(_gestureKind);
      return;
    }
    _gestureActive = true;
    _gestureDelta = 0;
    _gestureHeight = math.max(stage.height, 1);
    _gestureSent = null;
    _gestureHudTimer?.cancel();
    if (_gestureBase == null) {
      unawaited(_readGestureLevels());
    } else {
      _gestureHud.value = _GestureHudState(_gestureKind, _gestureBase!);
    }
  }

  void _updateGesture(DragUpdateDetails details) {
    if (!_gestureActive) return;
    _gestureDelta -= details.primaryDelta ?? 0;
    _applyGestureLevel();
  }

  void _applyGestureLevel() {
    final base = _gestureBase;
    if (base == null) return;
    // 亮度与原生侧同一下限：窗口亮度 0 等于关屏，原生夹在 0.02，
    // HUD 也必须从 2% 起，不能显示「0% 但画面没到最暗」。
    final floor = _gestureKind == _GestureKind.brightness ? .02 : 0.0;
    var value = (base + _gestureDelta / _gestureHeight).clamp(floor, 1.0);
    if (_gestureKind == _GestureKind.volume && _volumeSteps > 0) {
      // 设备音量是离散档位（本机 160 档）：先把值落到真实档位，HUD 与
      // 下发值才和系统音量面板一致，不会出现「37% 其实是第 59 档」。
      value = (value * _volumeSteps).round() / _volumeSteps;
    }
    _gestureHud.value = _GestureHudState(_gestureKind, value);
    if (_gestureKind == _GestureKind.brightness) {
      _brightnessLevel = value;
    } else {
      _volumeLevel = value;
    }
    // 通道按步进节流：拖动一帧一次 MethodChannel 会把掉帧带进画面。音量
    // 用「一个真实档位」做阈值——阈值比档位大时，HUD 已经跳到下一档而系统
    // 还没收到，仍会差 1 档；亮度保持 1% 步进。
    final threshold = _gestureKind == _GestureKind.volume && _volumeSteps > 0
        ? .9 / _volumeSteps
        : .01;
    if (_gestureSent != null && (value - _gestureSent!).abs() < threshold) {
      return;
    }
    _gestureSent = value;
    if (_gestureKind == _GestureKind.brightness) {
      _brightnessOverridden = true;
      unawaited(PlaybackGestureLevels.setBrightness(value));
    } else {
      unawaited(PlaybackGestureLevels.setVolume(value));
    }
  }

  void _endGesture() {
    if (!_gestureActive) return;
    _gestureActive = false;
    final value = _gestureHud.value?.value;
    // 收尾补齐最后一档：拖动中的 1% 节流可能吞掉终点值。
    if (value != null &&
        (_gestureSent == null || (value - _gestureSent!).abs() > .0001)) {
      if (_gestureKind == _GestureKind.brightness) {
        _brightnessOverridden = true;
        unawaited(PlaybackGestureLevels.setBrightness(value));
      } else {
        unawaited(PlaybackGestureLevels.setVolume(value));
      }
    }
    _gestureSent = null;
    _gestureBase = null;
    _gestureDelta = 0;
    _gestureHudTimer?.cancel();
    _gestureHudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) _gestureHud.value = null;
    });
  }

  /// 原生读不到档位时的反馈：HUD 显示一次「亮度/音量暂不可用」。
  void _showGestureUnavailable(_GestureKind kind) {
    _gestureHudTimer?.cancel();
    _gestureHud.value = _GestureHudState(kind, 0, unavailable: true);
    _gestureHudTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) _gestureHud.value = null;
    });
  }

  /// 读一次设备档位并缓存。起手时缓存还没读到的话，读完按已积累的位移
  /// 补算一次，不让第一下滑动白费。
  Future<void> _readGestureLevels() async {
    if (_readingGestureLevels) return;
    _readingGestureLevels = true;
    final levels = await PlaybackGestureLevels.read();
    _readingGestureLevels = false;
    if (!mounted) return;
    _gestureReadFailed = levels == null;
    if (levels == null) {
      // 手势进行中读失败：立刻反馈，不要停在「滑了没反应」的状态。
      if (_gestureActive && _gestureBase == null) {
        _gestureActive = false;
        _showGestureUnavailable(_gestureKind);
      }
      return;
    }
    _volumeSteps = levels.volumeSteps;
    _brightnessLevel = levels.brightness;
    _volumeLevel = levels.volume;
    if (!_gestureActive || _gestureBase != null) return;
    _gestureBase = _gestureKind == _GestureKind.brightness
        ? _brightnessLevel
        : _volumeLevel;
    if (_gestureBase == null) return;
    _applyGestureLevel();
  }

  void _endBoost() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    unawaited(_control((player) => player.setRate(_rate)));
    _scheduleHide();
  }

  /// 横屏右侧浮层：与选集抽屉同宽同高（右侧约 1/3 屏），200ms 从右滑入。
  ///
  /// 宽屏上的底部弹层会被拉成一条通栏、按钮稀疏排开，视频设置、弹幕设置
  /// 都改成这套右侧面板形态；竖屏仍走官方底部 sheet。几何与安全区规则
  /// 统一在 [PlayerSidePanel] 里——贴右缘铺满、内容自己让开挖孔。
  Future<T?> _showSidePanel<T>({
    required Color background,
    required WidgetBuilder builder,
  }) => PlayerSidePanel.show<T>(
    context: context,
    background: background,
    builder: builder,
  );

  /// 落地一次倍速选择：面板里选档与横屏二级面板共用这一条链路。
  Future<void> _applyRate(double rate) async {
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
        PlayerToast.show(context, '倍速已生效，但未能保存设置');
      }
    }
  }

  /// 横屏视频设置：右侧面板里的整串设置。
  ///
  /// 一进视频设置、二进弹幕设置/字号，三块面板共用同一条路由
  /// （[PlayletSideSettingsFlow] 内部换层），所以「弹幕设置」「字体大小」按
  /// ✕ 是退回视频设置，而不是一路掉回画面。倍速与清晰度不在这里——底条右
  /// 下角已经显示当前档，点它直接开档位面板。底色与选集抽屉同为 #141414，
  /// 三块右侧浮层并排切换不跳色。
  Future<void> _showSideSettings() async {
    setState(() => _modalOpen = true);
    try {
      await _showSidePanel<void>(
        background: const Color(0xFF141414),
        builder: (_) => PlayletSideSettingsFlow(
          clearScreen: _clearScreen,
          onToggleClearScreen: _clearScreenPanelAvailable
              ? () => _setClearScreen(!_clearScreen)
              : null,
          danmakuEnabled: widget.danmakuEnabled,
          onToggleDanmaku: widget.onToggleDanmaku,
          danmakuSettings: widget.onDanmakuSettingsChanged == null
              ? null
              : widget.danmakuSettings,
          onDanmakuSettingsChanged: (settings) {
            widget.onDanmakuSettingsChanged!.call(settings);
            unawaited(DanmakuSettings.save(settings));
          },
          onDanmakuReset: () => PlayerToast.show(context, '设置成功'),
          fontScaleLabel: ShortSeriesFontScale.label,
          fontScale: widget.shortSeries,
          onFontScaleSelected: () {
            if (mounted) setState(() {});
          },
          fillScreen: widget.fillScreen,
          onFillScreenChanged: widget.onFillScreenChanged,
          defaultMute: widget.defaultMute,
          onDefaultMuteChanged: widget.onDefaultMuteChanged,
          onOpenListenMode: widget.onOpenListenMode,
          onOpenOfflineCache: widget.onOpenOfflineCache,
        ),
      );
    } finally {
      if (mounted) setState(() => _modalOpen = false);
      if (mounted) _scheduleHide();
    }
  }

  /// 横屏底条右下角的倍速：点当前档就开档位面板（官方 jj3.q 同形，
  /// 选中即生效并收起）。
  ///
  /// 视频设置里不再重复放倍速行——底条上已经写着当前档，用户点它要的是
  /// 换档，不是再进一层设置列表。
  Future<void> _showLandscapeRateSheet() async {
    if (_overlayOpen || _panelOpen || _locked) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    setState(() => _modalOpen = true);
    double? picked;
    try {
      picked = await _showSidePanel<double>(
        background: const Color(0xFF141414),
        builder: (panelContext) => PlayerSidePanelOptionList<double>(
          key: const ValueKey('player-side-rates'),
          title: '倍速',
          panelKey: 'player-side-rates',
          isSelected: (rate) => rate == _rate,
          onBack: () => Navigator.pop(panelContext),
          options: [
            // 档位文案用 chip 形（1x 而不是底条上的「倍速」）：
            // `_rateText` 是给底条显示当前档用的，1 倍时写的是「倍速」。
            for (final rate in PlayerPreferences.playbackRates)
              PlayerSidePanelOption(label: _rateChipLabel(rate), value: rate),
          ],
        ),
      );
    } finally {
      // 先收计账再落地：等原生回执期间不该一直挡着手势。
      if (mounted) setState(() => _modalOpen = false);
    }
    if (picked != null && mounted) await _applyRate(picked);
    if (mounted) _scheduleHide();
  }

  /// 横屏底条右下角的清晰度：与倍速同形，选中即回传宿主切流。
  Future<void> _showLandscapeQualitySheet() async {
    if (_overlayOpen || _panelOpen || _locked) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    setState(() => _modalOpen = true);
    try {
      final picked = await _showSidePanel<EpisodeVariant>(
        background: const Color(0xFF141414),
        builder: (panelContext) => PlayerSidePanelOptionList<EpisodeVariant>(
          key: const ValueKey('player-side-quality'),
          title: '清晰度',
          panelKey: 'player-side-quality',
          isSelected: (variant) => variant.url == widget.currentQualityUrl,
          onBack: () => Navigator.pop(panelContext),
          options: [
            for (final variant in widget.qualityVariants)
              PlayerSidePanelOption(label: variant.name, value: variant),
          ],
        ),
      );
      if (picked != null) widget.onQualitySelected?.call(picked);
    } finally {
      if (mounted) setState(() => _modalOpen = false);
      if (mounted) _scheduleHide();
    }
  }

  /// 视频设置/弹层共用的深色判定：官方风格配置下发深色，或系统处于夜间。
  bool get _panelDarkStyle =>
      PlayerStyleConfig.instance.morePanelDarkStyle ||
      Theme.of(context).brightness == Brightness.dark;

  /// 底栏右下角「倍速」：直接开档位面板（竖屏底部弹层 / 横屏右侧面板）。
  ///
  /// 视频设置里不再放倍速——底栏上已经写着当前档，点它要的是换档，不该再
  /// 绕进设置列表。清晰度同理走 [_showQualityPicker]。
  Future<void> _showRatePicker() async {
    if (_overlayOpen || _panelOpen || _locked) return;
    if (_windowLandscape) {
      await _showLandscapeRateSheet();
      return;
    }
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    setState(() => _modalOpen = true);
    double? picked;
    try {
      picked = await showPlayletRateSheet(
        context,
        rate: _rate,
        dark: _panelDarkStyle,
      );
    } finally {
      // 先收弹层计账再落地：原生回执慢的时候（`setRate` 未返回）不能把
      // 整页一直算成「有弹层挡着手势」。
      if (mounted) setState(() => _modalOpen = false);
    }
    if (picked != null && mounted) await _applyRate(picked);
    if (mounted) _scheduleHide();
  }

  /// 底栏右下角「清晰度」：与倍速同形，选中即回传宿主切流。
  Future<void> _showQualityPicker() async {
    if (widget.onQualitySelected == null || widget.qualityVariants.length < 2) {
      return;
    }
    if (_overlayOpen || _panelOpen || _locked) return;
    if (_windowLandscape) {
      await _showLandscapeQualitySheet();
      return;
    }
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    setState(() => _modalOpen = true);
    try {
      final picked = await showPlayletQualitySheet(
        context,
        variants: widget.qualityVariants,
        currentUrl: widget.currentQualityUrl,
        dark: _panelDarkStyle,
      );
      if (picked != null) widget.onQualitySelected?.call(picked);
    } finally {
      if (mounted) setState(() => _modalOpen = false);
      if (mounted) _scheduleHide();
    }
  }

  /// 弹幕设置面板（官方 `ay1/v.java`）：竖屏整宽底部 sheet，横屏与选集
  /// 抽屉同宽的右侧面板。滑杆变化实时回调宿主并落盘（官方
  /// UpdateDanmakuConfigEvent）。
  Future<void> _showDanmakuSettings() async {
    final onSettings = widget.onDanmakuSettingsChanged;
    if (onSettings == null) return;
    // 与倍速/清晰度/字号三条弹层同门：面板或弹层在场、锁定时不再叠一层。
    if (_overlayOpen || _panelOpen || _locked) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    setState(() => _modalOpen = true);
    final landscape = _windowLandscape;
    Widget build(BuildContext _) => PlayletDanmakuSettingsPanel(
      settings: widget.danmakuSettings,
      landscape: landscape,
      onChanged: (settings) {
        onSettings(settings);
        unawaited(DanmakuSettings.save(settings));
      },
      onReset: () => PlayerToast.show(context, '设置成功'),
    );
    try {
      if (landscape) {
        await _showSidePanel<void>(
          background: const Color(0xFF1C1C1C),
          builder: build,
        );
      } else {
        await showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          backgroundColor: const Color(0xFF1C1C1C),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          builder: build,
        );
      }
    } finally {
      if (mounted) setState(() => _modalOpen = false);
      // 关闭后重排自动收起：否则控制条会一直留在画面上。
      if (mounted) _scheduleHide();
    }
  }

  /// 字号弹层（官方 `nm3.e`）。弹层本体与 feed 更多面板共用
  /// [showPlayletFontScaleSheet]；这里只管 chrome 侧的时机：守门、
  /// `_modalOpen` 计账与关闭后的隐藏计时。
  /// Note: 字号档作用域/弹幕豁免/弹层不自动关的取舍 — 见
  /// .agents/notes/implemented/feature/2026-09-29-listen-mode-and-font-scale.md
  Future<void> _showFontScaleSheet() async {
    if (_overlayOpen || _panelOpen || _locked) return;
    setState(() => _modalOpen = true);
    // 选档即时刷新 chrome 树的文字缩放（弹层盖不住整页）。
    await showPlayletFontScaleSheet(
      context,
      onSelected: () {
        if (mounted) setState(() {});
      },
    );
    if (mounted) setState(() => _modalOpen = false);
    if (mounted) _scheduleHide();
  }

  /// 「视频设置」面板：只放开关与入口，倍速/清晰度不在这里（底栏右下角
  /// 已经写着当前档，点它走 [_showRatePicker] / [_showQualityPicker]）。
  ///
  /// 更多面板样式分支：官方 `play_control_panel_style_v681.style` 未下发
  /// 或为 0 时是浅色面板（`#FAFAFA`、无取消行），下发 1/2 才是深色 V2
  /// （`Q0()` 染 `#FF1C1C1C`）。
  /// Note: 深/浅两支并存的配置门与死行取舍 — 见
  /// .agents/notes/implemented/feature/2026-09-29-more-panel-light-branch.md
  Future<void> _showSettingsPanel() async {
    if (_overlayOpen || _panelOpen || _locked) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    // 横屏走右侧面板里的一整串设置（宫格 → 弹幕设置/字号），与选集抽屉
    // 同宽同高、共用 64dp 标题行。
    if (_windowLandscape) {
      await _showSideSettings();
      return;
    }
    final dark = PlayerStyleConfig.instance.morePanelDarkStyle;
    // 底栏不显示当前档（catalog 形态竖屏）时，面板里留倍速/清晰度入口行。
    // 注意这里的 `!_splitActive` 不能省：getter 在分屏时也为 false（紧凑条
    // 接管了当前档），单靠 `!getter` 会误判成「底栏没有档」，反而在面板里
    // 补出一行，变成两个入口。
    final panelRateEntry = !_bottomRateTextVisible && !_splitActive;
    final panelQualityEntry =
        panelRateEntry &&
        widget.onQualitySelected != null &&
        widget.qualityVariants.length > 1;
    setState(() => _modalOpen = true);
    var sheetDanmaku = widget.danmakuEnabled;
    var sheetMute = widget.defaultMute;
    var sheetFill = widget.fillScreen;
    // 浅色支也跟随夜间皮肤（官方 SkinDelegate 翻白），否则夜间主题下
    // FAFAFA 底配白字不可见。
    final sheetBackground =
        dark || Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1C1C1C)
        : const Color(0xFFFAFAFA);
    Widget buildPanel(BuildContext sheetContext) {
      if (widget.shortSeries && !dark) {
        return PlayletMorePanelLight(
          rateLabel: panelRateEntry ? _rateChipLabel(_rate) : null,
          onOpenRate: panelRateEntry ? () => _pendingRatePicker = true : null,
          qualityLabel: panelQualityEntry ? _qualityLabel() : null,
          onOpenQuality: panelQualityEntry
              ? () => _pendingQualityPicker = true
              : null,
          clearScreen: _clearScreen,
          onToggleClearScreen: _clearScreenPanelAvailable
              ? () => _setClearScreen(!_clearScreen)
              : null,
          danmakuEnabled: widget.danmakuEnabled,
          onToggleDanmaku: widget.onToggleDanmaku,
          // 浅色支此前漏了这条：官方两支的「弹幕设置」入口同门（jm3.e），
          // 面板自己会先收起，这里只记一个级联标记。
          onOpenDanmakuSettings: widget.onDanmakuSettingsChanged != null
              ? () => _pendingDanmakuSettings = true
              : null,
          // 官方 `jm3.t0`：行尾当前档 + 点击级联打开字号弹层。
          fontScaleLabel: ShortSeriesFontScale.label,
          onOpenFontSettings: () => _pendingFontScale = true,
          onOpenListenMode: widget.onOpenListenMode,
          onOpenOfflineCache: widget.onOpenOfflineCache,
        );
      }
      return widget.shortSeries
          ? PlayletMorePanel(
              rateLabel: panelRateEntry ? _rateChipLabel(_rate) : null,
              onOpenRate: panelRateEntry
                  ? () => _pendingRatePicker = true
                  : null,
              qualityLabel: panelQualityEntry ? _qualityLabel() : null,
              onOpenQuality: panelQualityEntry
                  ? () => _pendingQualityPicker = true
                  : null,
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
                      Navigator.pop(sheetContext);
                    }
                  : null,
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
                      // 通用播放器没有底栏当前档：留一行倍速入口，档位本身
                      // 不铺开在设置面板里（点开 [_showRatePicker]）。
                      InkWell(
                        key: const ValueKey('player-more-rate-row'),
                        onTap: () {
                          _pendingRatePicker = true;
                          Navigator.pop(sheetContext);
                        },
                        child: SizedBox(
                          height: 44,
                          child: Row(
                            children: [
                              const Text(
                                '倍速',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF1B1B1B),
                                ),
                              ),
                              const Spacer(),
                              // 行尾当前档（面板里不铺开档位，只看得到现在几倍）。
                              Text(
                                _rateChipLabel(_rate),
                                key: const ValueKey('player-more-rate-value'),
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF1B1B1B),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                '›',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Color(0xFF1B1B1B),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 短剧支的倍速/清晰度不进设置面板：底栏右下角显示当前档，
                      // 点它直接开档位弹层（[_showRatePicker] /
                      // [_showQualityPicker]）。
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

    await showModalBottomSheet<void>(
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
      backgroundColor: sheetBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          // aae.xml 的 ak1：浅色支 16dp 顶圆角；深色支沿用已核对的 12dp。
          top: Radius.circular(widget.shortSeries ? (dark ? 12 : 16) : 16),
        ),
      ),
      builder: buildPanel,
    );
    if (!mounted) return;
    setState(() => _modalOpen = false);
    // 更多面板里的「弹幕设置」：等面板收起后再级联打开设置面板，
    // 避免 _modalOpen 的置位被 _showSettingsPanel 的收尾覆盖。
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
    // 「倍速」行（通用播放器没有底栏当前档）：面板收起后再开档位弹层。
    if (_pendingRatePicker) {
      _pendingRatePicker = false;
      unawaited(_showRatePicker());
      return;
    }
    // 「清晰度」行同款级联。
    if (_pendingQualityPicker) {
      _pendingQualityPicker = false;
      unawaited(_showQualityPicker());
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

  Future<void> _openRelatedSeries() async {
    await _closePanel();
    if (mounted) widget.onOpenRelatedSeries?.call();
  }

  void _openPanel() {
    // 分屏态选集常驻在下半区/右侧栏，不再弹 sheet。
    if (_splitActive || _locked || _overlayOpen || _panelOpen) return;
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    _hideTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      // 抽屉形态看窗口宽高，不看全屏：设备横置时 bottom sheet 在宽屏上
      // 会缩成一条，和「横屏 UI 混乱」同源。
      _panelDrawer =
          widget.shortSeries && _viewportSize.width > _viewportSize.height;
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

  /// 让 pager 停在 [currentIndex]。
  ///
  /// 分屏与整屏各有一棵 PageView：切换布局时旧树销毁、新树重建，共用的
  /// `PageController` 会让新位置从 `initialPage`（进入播放页时的集数）
  /// 起算，画面于是停在旧集封面上，而音频已经播到当前集。宿主改集数时
  /// 的对账也走这里，两处不再各写一份。
  void _ensurePagerOnCurrent() {
    if (_pagerSyncScheduled) return;
    _pagerSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pagerSyncScheduled = false;
      if (!mounted || !_pages.hasClients || _paging) return;
      final count = widget.episodes.length;
      if (count == 0) return;
      final target = widget.currentIndex.clamp(0, count - 1);
      if ((_pages.page ?? 0).round() != target) {
        _pages.jumpToPage(target);
      }
    });
  }

  Future<void> _back() async {
    if (_panelOpen) {
      await _closePanel();
    } else if (_fullScreen) {
      // 返回键的语义是「退出横屏、回到原来的竖屏页」，不是「留在横屏」。
      await _toggleFullScreen(backToPortrait: true);
    } else {
      await Navigator.maybePop(context);
    }
  }

  Future<void> _toggleFullScreen({bool backToPortrait = false}) async {
    _endBoost();
    _cancelSeek();
    _doubleTapGuard?.cancel();
    // 用户手动切形态后，入场时的「强制横屏」不再生效。
    _entryLandscape = false;
    // 官方在 Activity 退出横屏时无条件解锁（`EXIST_LAND_ACTIVITY`）。
    if (_fullScreen) _releaseLock();
    final leavingFullScreen = _fullScreen;
    setState(() {
      _fullScreen = !_fullScreen;
      // 全屏里控件会 3 秒收起；退出后回到竖屏浏览态，`_scheduleHide` 的
      // 常驻分支不再排计时，`_visible` 停在 false 就是「半套 UI」：顶栏、
      // 右栏与「全屏观看」入口全都不见了。退出时把控件带回来。
      if (leavingFullScreen) _visible = true;
    });
    // 收起计时必须排在系统 UI / 转向请求之前：`setPreferredOrientations`
    // 在设备拒绝转向或平台通道没响应时可能长期不返回，排在后面就等于永不
    // 收起——issue #59 的症状正是「点了全屏观看，控件一直钉在画面上」。
    _scheduleHide();
    // 只有返回键会钉竖屏：它的语义是「回到原来的竖屏页」。点「退出全屏」
    // 则回到浏览态，设备仍横握时就该留在横屏（横屏浏览 UI），不抢方向。
    await _applySystemUi(pinPortrait: leavingFullScreen && backToPortrait);
    if (mounted) setState(() {});
  }

  Future<void> _applySystemUi({bool pinPortrait = false}) async {
    _systemUiTouched = true;
    final fullScreen = _fullScreen;
    final operation = _systemUiUpdates.then((_) async {
      if (!mounted || _fullScreen != fullScreen) return;
      if (fullScreen) {
        _portraitPinned = false;
        _portraitPinSuspended = false;
        // Android 15+ ignores Flutter's legacy immersiveSticky under
        // edge-to-edge (target SDK 36); the Android host hides the bars with
        // WindowInsetsController instead (#176).
        await PlayerSystemUi.hide();
        // 全屏方向跟片源走：竖版片源铺满竖屏（点「全屏」不该把 9:16 的画面
        // 转成横屏、留一圈黑边），横版片源沿用官方 `ShortSeriesLandActivity`
        // 的 `userLandscape`。尺寸未知（连播切集的新播放器）时不发请求，
        // 免得把正在看的方向翻一下（issue #59）。
        final orientations = _fullScreenOrientationsForSource;
        if (orientations != null) {
          await SystemChrome.setPreferredOrientations(orientations);
        }
      } else if (pinPortrait) {
        _portraitPinned = true;
        await _restoreSystemUi();
      } else {
        await _restoreSystemUi();
      }
    });
    _systemUiUpdates = operation.catchError((Object _) {});
    await _systemUiUpdates;
  }

  /// 画面是否处于横屏全屏态。锁只在横屏有效，退出横屏即解锁。
  bool get _isLandscape {
    return _fullScreen && _viewportSize.width > _viewportSize.height;
  }

  /// 窗口本身是否宽大于高（不看是否全屏）。与 `_buildStage` 的 `landscape`
  /// 同源：设备横置就算横屏，不要求用户点过「全屏观看」。
  bool get _windowLandscape => _viewportSize.width > _viewportSize.height;

  /// 「竖屏浏览态」：竖窗口 + 未进全屏 + 未分屏。
  ///
  /// 竖屏目录件（右栏评论、信息层、选集条、全屏观看）与底栏文字操作行都
  /// 只属于这个形态；竖屏全屏是沉浸态，设备没转向也不例外（issue #59 的
  /// 「全屏后按钮还在」）。只能在这里派生一次：各处自己拼 `!landscape &&
  /// !_fullScreen`，漏拼一处就是一层目录 UI 钉在画面上。
  bool get _portraitBrowse =>
      !_splitActive && !_windowLandscape && !_fullScreen;

  /// 右缘锁定按钮此刻是否占位（与 [_lockButton] 同门，但不看淡出动画与
  /// 锁定态）：「下一集」卡叠在画面上时要按它让出命中区，否则点卡片会
  /// 点到锁上。
  bool get _landscapeLockShown =>
      widget.shortSeries &&
      widget.landscapeLockEnabled &&
      _isLandscape &&
      !_clearScreen &&
      !_panelOpen &&
      !_overlayOpen &&
      _ready;

  /// 竖屏顶栏行高：返回键与集数那一行。顶栏容器与弹幕层顶部让位共用
  /// 这一份，写两份就会滞。
  static const _portraitTopBarHeight = 44.0;

  /// 横屏顶栏行高：两行标题随系统字号长高时顶栏一起长高。右缘「下一集」卡
  /// 挂在顶栏下沿，必须用同一份高度——写死 56 时，大字号 + 极扁窗口下卡片
  /// 会压进顶栏渐变里。
  double get _landscapeTopBarHeight {
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight = scaler.scale(15) * 1.2 + 2 + scaler.scale(11.5) * 1.2;
    return math.max(56.0, titleHeight + 8);
  }

  Future<void> _restoreSystemUi({bool releasePin = false}) async {
    if (releasePin) _portraitPinned = false;
    try {
      await SystemChrome.setPreferredOrientations(
        _portraitPinned
            ? const [DeviceOrientation.portraitUp]
            : const <DeviceOrientation>[],
      );
      await PlayerSystemUi.show();
    } catch (_) {}
  }

  /// 本页被别的路由盖住 / 回到本页时暂停或恢复竖屏钉。
  ///
  /// `SystemChrome.setPreferredOrientations` 是引擎级的，不随路由释放的话，
  /// 从分屏面板 push 的详情、听剧页会一直被锁在竖屏，直到播放页被 pop。
  void _handleCoverChanged() {
    final animation = _coverAnimation;
    if (animation == null) return;
    final covered = animation.value > 0;
    if (covered == _routeCovered) return;
    _routeCovered = covered;
    if (covered) {
      // 新路由盖住播放页：把系统栏还给上层页面。全屏时不走
      // `_restoreSystemUi`，否则被 push 的详情页会跟着转屏。
      if (_portraitPinned) {
        _portraitPinned = false;
        _portraitPinSuspended = true;
        _queueSystemUi(() => _restoreSystemUi());
      } else if (_fullScreen) {
        _queueSystemUi(() => PlayerSystemUi.show());
      }
      return;
    }
    if (_portraitPinSuspended) {
      _portraitPinSuspended = false;
      _portraitPinned = true;
      _queueSystemUi(() => _restoreSystemUi());
    } else if (_fullScreen) {
      // 回到全屏播放页：重新沉浸（#176）。
      _queueSystemUi(() => PlayerSystemUi.hide());
    }
  }

  /// 串行执行系统 UI 变更，后一次不会抢在前一次前面落地。
  void _queueSystemUi(Future<void> Function() operation) {
    final queued = _systemUiUpdates.then((_) => operation());
    _systemUiUpdates = queued.catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) => isWindowsDesktop
      ? DesktopVideoChrome(
          configuration: widget,
          onRateSelected: (rate) async {
            ++_rateGeneration;
            setState(() => _rate = rate);
            await PlayerPreferences.savePlaybackRate(rate);
            if (widget.onPlaybackRateChanged case final changed?) {
              await changed(rate);
            } else {
              await _control((player) => player.setRate(rate));
            }
          },
          onVolumeSelected: widget.onPlaybackVolumeChanged,
        )
      : AnnotatedRegion<SystemUiOverlayStyle>(
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
        data: MediaQuery.of(context).copyWith(textScaler: scaledScaler),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final insets = MediaQuery.paddingOf(context);
              final window = constraints.biggest;
              final resized = _viewportSize != window;
              _viewportSize = window;
              if (resized) {
                // 首帧与每次旋转：`_scheduleHide` 的常驻判据要读窗口宽高，
                // initState 里 `_viewportSize` 还是 0，只能等布局落地后按
                // 新朝向重排一次收起计时（横屏底条不能一直压在画面上）。
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _scheduleHide();
                });
              }
              // 分屏（短剧）：视频盒与下半区 / 右侧栏共用同一份 chrome 状态。
              // 全屏时永远回到沉浸式整屏（官方「全屏观看」是独立横屏 Activity）。
              final split = _shouldUseSplit(window);
              _syncSplitState(split);
              if (split) {
                return _buildSplit(
                  context,
                  window: window,
                  insets: insets,
                  outerScaler: outerScaler,
                );
              }
              return _buildStage(
                context,
                window: window,
                insets: insets,
                compact: false,
                outerScaler: outerScaler,
              );
            },
          ),
        ),
      ),
    );
  }

  /// 视频区（整屏或分屏上半区/左半区）。`compact` = 分屏里的独立视频盒：
  /// 只保留画面手势与紧凑控制条，不渲染竖屏信息层、选集条、右栏与旧进度层。
  Widget _buildStage(
    BuildContext context, {
    required Size window,
    required EdgeInsets insets,
    required bool compact,
    required TextScaler outerScaler,
  }) {
    _stageSize = window;
    // 分屏 ↔ 整屏会重建 PageView；每次进入视频区都确认 pager 在当前集。
    _ensurePagerOnCurrent();
    // 分屏视频盒没有全屏/面板语义：`compact` 下所有朝向判定都按竖屏形态走，
    // 面板展开比例固定 0（盒子里不缩画面）。
    //
    // 横屏形态只看窗口宽高，不跟 `_fullScreen` 绑定：设备横置（包括没点
    // 「全屏观看」、只是把手机横过来）时，竖屏信息层/右栏铺在宽屏上会互相
    // 压住，就是「横屏 UI 混乱不对齐」。全屏只是额外加了沉浸式与转向请求。
    final landscape = !compact && window.width > window.height;
    // 横屏整屏的上下滑要先拿到设备档位：进横屏时预读一次（分屏在
    // `_syncSplitState` 里同样预读），第一下滑动就能接着当前亮度/音量走。
    if (landscape && !_gesturePrimed && !_gestureReadFailed) {
      _gesturePrimed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_readGestureLevels());
      });
    }
    final layout = PlayerVideoLayout.calculate(
      window: window,
      insets: insets,
      videoSize: _videoSize,
      fit: VideoFit.contain,
      panelFraction: compact ? 0 : _panelFraction,
      restingPanelFraction: compact ? 0 : _panelRestFraction,
      fullScreen: _fullScreen,
      compact: compact,
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
    // 旋出横屏时识别器被摘掉，拖拽可能收不到 onEnd：把手势态与 HUD 清掉，
    // 免得下次进横屏看到上一轮的残留档位。
    if (!landscape &&
        !compact &&
        (_gestureActive || _gestureHud.value != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _splitActive || _windowLandscape) return;
        _gestureActive = false;
        _gestureBase = null;
        _gestureHud.value = null;
      });
    }
    // 锁定时官方整条控件/清屏链路被吞（fullscreen/d.H6() 与
    // jq3/x.q 的 B4()/G6() 早退），只留锁按钮本身。
    final showChrome = unobstructed && !_clearScreen && !_locked;
    final controls = _visible && showChrome && !_seeking;
    // 短剧竖屏双击点赞按用户要求移除；单击仍控制播放。
    // 横屏单击切换控件，双击播放继续由横屏配置控制。
    final portraitSeries = widget.shortSeries && !compact && !landscape;
    // 「竖屏浏览态」= 竖窗口 + 未进全屏（见 [_portraitBrowse]）。所有竖屏
    // 常驻件统一读这一个判据，不再各自拼 `!landscape && !_fullScreen`。
    final portraitBrowse = _portraitBrowse;
    final catalogStyle = portraitBrowse && _catalogStyle;
    // 竖屏「常驻」形态下单击切播放（官方行为）；但竖屏里进了全屏后控件
    // 会收起，单击必须能把控件叫回来——否则是一个没有出口的隐藏态。
    // 分屏视频盒单击只切控件，播放/暂停交给命中更准的紧凑条。
    final tapTogglesPlayback =
        !compact && widget.shortSeries && (portraitBrowse || _clearScreen);
    final canPage =
        !compact &&
        unobstructed &&
        !_seeking &&
        !_boosting &&
        !_locked &&
        !landscape;
    // 短剧横屏底条（批次四）：官方 `c0i.xml` + `cw7.xml` 的形态，
    // 替换通用运输条在此朝向的全部残留（prev/±10/全屏钮）。
    final landscapeBar = !compact && widget.shortSeries && landscape;
    // 自动收起保留信息区，清屏则统一隐藏；计时器不是清屏状态来源。
    // 竖屏全屏例外：用户点「全屏观看」要的是整块画面，收起后连信息带
    // 一起隐藏（否则剧名/选集/全屏按钮会一直钉在画面上，issue #59）。
    final bandVisible =
        portraitBrowse &&
        widget.shortSeries &&
        _ready &&
        !_visible &&
        !_seeking &&
        showChrome;
    // 热评只在信息区可见时出现；新栏采用截图中的无底色信息行。
    final hotBar =
        portraitBrowse &&
        widget.shortSeries &&
        !_locked &&
        !_clearScreen &&
        !_seeking &&
        widget.hotComments.isNotEmpty &&
        (controls || bandVisible);
    // 底栏当前档（「倍速」文字）是否在场：判据与视频设置的入口行共用
    // [_bottomRateTextVisible]，不再各自维护一份、也不跨帧缓存。
    // 竖屏全屏是沉浸态：文字操作行随控件一起收起，否则 3 秒后仍钉在
    // 画面上（issue #59 的另一半症状）。横屏全屏不能挡——那里没有
    // `_portraitControls`，清屏后「恢复」只剩这一处出口；清屏态本身也
    // 必须留出口（见 [_toggleControls] 的同一条不变量）。
    final showTextActions =
        _bottomRateTextVisible &&
        (!_fullScreen || landscape || _clearScreen || controls);
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
              if (_ready && !_clearScreen) {
                _guardDoubleTap();
              }
            } else if (!widget.shortSeries) {
              _togglePlayback();
            } else {
              // 短剧横屏双击：中间三分之一切播放，左/右三分之一 ±10s。
              // 官方 jq3/x$q.onDoubleTap 只在中带隐藏控制条、从不切
              // 播放；实测反馈要求双击能暂停/快进快退，这里按通用
              // 播放器手势处理（竖屏分支保持原样：吞单击窗口）。
              _guardDoubleTap();
              final position = _doubleTapDownPosition;
              final width = window.width;
              if (_clearScreen || position == null || width <= 0) return;
              final third = width / 3;
              if (position.dx < third) {
                if (!_ready) return;
                if (widget.duration > Duration.zero) _seekBy(-10);
              } else if (position.dx > width - third) {
                if (!_ready) return;
                if (widget.duration > Duration.zero) _seekBy(10);
              } else {
                _togglePlayback();
              }
            }
          },
          onHorizontalDragStart: _startDragSeek,
          onHorizontalDragUpdate: _updateDragSeek,
          onHorizontalDragEnd: _endDragSeek,
          // 分屏视频盒与横屏整屏的竖直翻页都已关闭（canPage == false），
          // 上下滑改为左半区调亮度、右半区调音量；竖屏整屏不注册这两个
          // 识别器，竖直翻页照旧。
          onVerticalDragStart: compact || landscape
              ? (details) => _startGesture(details, window)
              : null,
          onVerticalDragUpdate: compact || landscape ? _updateGesture : null,
          onVerticalDragEnd: compact || landscape ? (_) => _endGesture() : null,
          onVerticalDragCancel: compact || landscape ? _endGesture : null,
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
              if (!_seeking && !_paging) _showSettingsPanel();
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
                _ensurePagerOnCurrent();
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
                      compact: compact,
                      child: SizedBox(
                        key: const ValueKey('video-frame'),
                        child: widget.child,
                      ),
                    )
                  else
                    _positionVideo(
                      window: window,
                      insets: insets,
                      compact: compact,
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
        // 缓冲转圈由宿主（PlayerPage 的 `PlayerLoadingFeedback`）统一渲染，再加会叠两个。
        // 弹幕层：官方在竖屏画面内滚动，锁屏/清屏时隐藏
        // （container/l.java 的渲染参数未取证，这里只放已证时间轴语义）。
        if (widget.shortSeries &&
            widget.danmakuEnabled &&
            !_locked &&
            !_clearScreen &&
            widget.danmaku.isNotEmpty)
          Positioned(
            // 竖屏顶栏（返回键 / 集数那一行）压在画面上：整层从它下沿
            // 开始，第一轨才不会盖住返回键（SafeArea 会再叠状态栏）。
            // 横屏弹幕铺满整窗、轨道按屏高排密度，不让位；分屏的视频
            // 盒不是竖屏浏览态，同样保持原样。
            left: 0,
            right: 0,
            top: landscape || compact ? 0 : _portraitTopBarHeight,
            bottom: 0,
            child: SafeArea(
              // 横屏画面按整窗居中，弹幕轨道也铺满整窗：让开左挖孔会把整条
              // 轨道（包括居中的弹幕）右移一截，和画面中线错开。
              left: !landscape,
              right: !landscape,
              bottom: false,
              child: KeyedSubtree(
                key: ObjectKey(widget.player),
                // 弹幕不受官方字号档影响（弹幕有自己的字号配置）：
                // 还原外层 textScaler。
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: outerScaler),
                  child: PlayletDanmakuLayer(
                    key: const ValueKey('player-danmaku-layer'),
                    entries: widget.danmaku,
                    position: _position,
                    rate: _boosting ? 2 : _rate,
                    // 官方横屏飞行 12000ms、竖屏 10000ms。分屏视频盒即使宽
                    // 扁（竖屏片源按 4:3 切盒）也不是横屏播放：判据必须是
                    // 设备朝向，否则竖屏分屏会误用横屏飞行时长与轨道密度。
                    landscape:
                        landscape ||
                        MediaQuery.orientationOf(context) ==
                            Orientation.landscape,
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
        // `o.java K6` 的引导层）。分屏视频盒太矮，不叠加引导层。
        if (!compact && widget.showSeekHint && showChrome && widget.enabled)
          Positioned(
            left: 0,
            right: 0,
            bottom: insets.bottom + 138,
            child: IgnorePointer(
              child: Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xCC222222)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.swap_horiz, size: 16, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          '左右滑动可调整进度',
                          style: TextStyle(fontSize: 14, color: Colors.white),
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
          if (portraitBrowse && !catalogStyle) _rightBar(insets),
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
        if (!compact &&
            ((!catalogStyle && !landscape && (controls || bandVisible)) ||
                showTextActions))
          Positioned(
            left: insets.left,
            right: insets.right,
            bottom:
                insets.bottom +
                (widget.shortSeries ? (landscape ? 16 : 56) : 96),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (portraitBrowse && (controls || bandVisible))
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
                      active: _appActive && !_overlayOpen && !_panelOpen,
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
        if (portraitBrowse && (controls || bandVisible))
          _catalogBar(insets, compact: catalogStyle),
        // 短剧竖屏全屏没有横屏底条，出口只剩顶栏返回（3 秒后随控件收起）；
        // 补一个控件可见时的显式「退出全屏」，位置沿用进度条下方那条贴底的
        // 窄带（`insets.bottom + 8`）。通用播放器的运输条自带同名按钮，排除。
        if (widget.shortSeries &&
            !landscape &&
            _fullScreen &&
            controls &&
            _ready)
          Positioned(
            right: insets.right + 16,
            bottom: insets.bottom + 8,
            child: _fullscreenPill(),
          ),
        // 官方播放页（`apf.xml`）竖屏没有运输条；运输条只剩通用
        // 播放器（详情页影视）在用，短剧两个朝向都不走它。
        if (!compact && controls && _ready && !widget.shortSeries)
          _transport(insets, landscape),
        if (landscapeBar && _ready && showChrome && (_visible || _seeking))
          _landscapeBar(insets),
        // 右侧黑边里的「下一集」卡：只在画面居中完整显示、黑边够宽时出现
        // （B站横屏同款；番茄官方横屏没有这一项）。
        if (landscapeBar && _ready && showChrome && (_visible || _seeking))
          _nextEpisodeCard(window: window, insets: insets),
        if (!compact &&
            (_visible || _seeking || bandVisible) &&
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
            // 顶栏行高随字号长高（与 `_topBar` 同源），芯片挂在它下面。
            top: insets.top + _landscapeTopBarHeight + 8,
            left: 0,
            right: 0,
            child: const Center(
              child: IgnorePointer(child: Chip(label: Text('2× 加速中'))),
            ),
          ),
        // 分屏盒没有面板语义（见 `_buildStage` 开头）：不拦会随 stage 换父级重建、双 attach。
        if (_panelOpen && _panelDrawer && !compact) ...[
          // 横屏右侧抽屉（官方截图第二十三轮）：200ms 滑入滑出 + 0.5 遮罩，点遮罩/✕/返回键关闭。
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
            width: PlayerSidePanel.widthFor(window.width),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _panelDrawerClosing ? 0.0 : 1.0),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) => FractionalTranslation(
                translation: Offset(1 - t, 0),
                child: Opacity(opacity: t, child: child!),
              ),
              child: StoryEpisodeDrawer(
                onOpenRelatedSeries: widget.onOpenRelatedSeries == null
                    ? null
                    : _openRelatedSeries,
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
        if (_panelOpen && !_panelDrawer && !compact) ...[
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
            // 兄弟层增删会让无 key 的面板层同帧重建，controller 被 attach 两次。
            key: const ValueKey('story-panel-layer'),
            top: insets.top,
            left: insets.left,
            right: insets.right,
            bottom: 0,
            // 官方进出场 200ms 位移+淡入（`:268-337`）：位移由 sheet extent 承担，
            // 透明度跟随进度；child 提升避免每个 extent tick 重建面板子树（0-rebuild 断言）。
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
                    onOpenRelatedSeries: widget.onOpenRelatedSeries == null
                        ? null
                        : _openRelatedSeries,
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
        _lockButton(window, insets),
        // 分屏视频盒的底部紧凑条：时间/进度 + 播放/下一集/倍速/全屏。
        if (compact && _ready && showChrome && (_visible || _seeking))
          _compactBar(),
        // 上下滑亮度/音量的档位 HUD：用独立 notifier 刷新，拖动期间不重建
        // 画面与控件。
        if (compact || landscape)
          ValueListenableBuilder<_GestureHudState?>(
            valueListenable: _gestureHud,
            builder: (context, state, _) => state == null
                ? const SizedBox.shrink()
                : _gestureHudOverlay(state),
          ),
        // 首次进分屏的手势提示：Tab 下划线不是唯一线索，横滑与上下滑都
        // 需要一次明确说明；3.5 秒后自动淡出，不挡控件。
        if (compact) _splitHintOverlay(),
      ],
    );
  }

  /// 分屏手势提示只在每次进播放页后的第一次进分屏出现一次。
  void _showSplitHintIfNeeded() {
    if (_splitHintShown) return;
    _splitHintShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_splitActive) return;
      setState(() => _splitHintVisible = true);
      _splitHintTimer?.cancel();
      _splitHintTimer = Timer(const Duration(milliseconds: 3500), () {
        if (mounted) setState(() => _splitHintVisible = false);
      });
    });
  }

  Widget _splitHintOverlay() {
    // 横屏分屏的下半区在右侧：提示文案跟着布局走，不写死「下方」。
    final sideBySide = _viewportSize.width > _viewportSize.height;
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: const Alignment(0, .62),
          child: AnimatedOpacity(
            key: const ValueKey('player-split-hint'),
            opacity: _splitHintVisible ? 1 : 0,
            duration: const Duration(milliseconds: 240),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xB3000000),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SplitHintLine(
                    icon: Icons.swap_vert_rounded,
                    text: '左半屏上下滑调亮度 · 右半屏上下滑调音量',
                  ),
                  const SizedBox(height: 4),
                  // 面板 Tab 叫「简介 / 评论」，提示沿用同一套称呼。
                  _SplitHintLine(
                    icon: Icons.swipe_rounded,
                    text: sideBySide
                        ? '右侧栏左右滑切换简介 / 评论 · 点分隔条收起'
                        : '下方左右滑切换简介 / 评论 · 拖分隔条调比例',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 是否把画面收进分屏视频盒。
  ///
  /// 只有宿主传了 [VideoPlayerChrome.splitPanel]（短剧播放页）才可能分屏；
  /// 全屏态永远回到整屏——官方「全屏观看」是独立的横屏 Activity，没有下半区。
  /// `auto` 只处理「竖屏设备 + 横屏片源」：设备本身横置时屏幕已经是宽的，
  /// 再拆左右只会让画面更小，因此保持整屏。
  bool _shouldUseSplit(Size window) {
    if (widget.splitPanel == null || !widget.shortSeries || _fullScreen) {
      return false;
    }
    if (_sourceKnown) _lastSourceWide = _videoSize.width > _videoSize.height;
    switch (widget.layoutMode) {
      case PlayerLayoutMode.immersive:
        return false;
      case PlayerLayoutMode.split:
        return true;
      case PlayerLayoutMode.auto:
        if (window.width >= window.height) return false;
        // 尺寸未知沿用上次判定：按固定方向猜会让竖版剧每集先闪一次分屏。
        return _lastSourceWide ?? false;
    }
  }

  /// 分屏开关只改布局、不动播放器；但切换进分屏时必须摘掉可能开着的
  /// sheet/drawer，否则 PopScope 会一直拦返回键，而面板已经不再渲染。
  void _syncSplitState(bool split) {
    final wasSplit = _splitActive;
    _splitActive = split;
    if (split && !wasSplit) {
      // 分屏没有「竖屏底栏常驻」形态：控件照常 3 秒收起。
      // 起手档位先读一次并缓存，第一下滑动就能从当前亮度/音量接着走。
      unawaited(_readGestureLevels());
      _showSplitHintIfNeeded();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _splitActive) _scheduleHide();
      });
    } else if (!split && wasSplit) {
      // 退出分屏：手势 HUD 与手势提示都不该留在整屏形态上；亮度覆盖保留
      // 到页面退出。
      _splitHintTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _splitActive) return;
        _gestureActive = false;
        _gestureBase = null;
        _gestureHud.value = null;
        if (_splitHintVisible) setState(() => _splitHintVisible = false);
        if (_splitCollapsed) setState(() => _splitCollapsed = false);
      });
    }
    if (!split || !_panelOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_splitActive || !_panelOpen) return;
      ++_panelAnimation;
      _panelAnimating = false;
      _panelDrawerTimer?.cancel();
      _panelDrawerClosing = false;
      setState(() {
        _panelOpen = false;
        _panelDrawer = false;
        _panelExtent.value = 0;
        _panelWasVisible = false;
        _panelHeaderDragging = false;
      });
    });
  }

  /// 分屏：竖屏上下（视频盒 + 下半区），横屏左右（左视频 + 右侧栏）。
  ///
  /// 外层 SafeArea 一次性吃掉状态栏/导航栏/刘海，视频盒与面板都不再各自
  /// 叠加 inset；背景取主题 canvas，与面板同色，圆角切口不露出黑色。
  Widget _buildSplit(
    BuildContext context, {
    required Size window,
    required EdgeInsets insets,
    required TextScaler outerScaler,
  }) {
    final palette = HomePalette.of(context);
    final sideBySide = window.width > window.height;
    final availableWidth = math.max(0.0, window.width - insets.horizontal);
    final availableHeight = math.max(
      0.0,
      window.height - insets.top - insets.bottom,
    );
    // 分隔条厚度：竖屏占高度、横屏占宽度。ratio 把分隔条也算在视频区里，
    // 拖动时只和整段可用长度相除，不会因为分隔条厚度反复漂移。
    const dividerExtent = 18.0;
    final defaultRatio = sideBySide
        ? (PlayerVideoLayout.splitLeftWidth(window: window, insets: insets) +
                  dividerExtent) /
              math.max(availableWidth, 1)
        : (PlayerVideoLayout.splitTopHeight(
                    window: window,
                    insets: insets,
                    videoSize: _videoSize,
                  ) +
                  dividerExtent) /
              math.max(availableHeight, 1);
    final panel = widget.splitPanel;
    if (panel == null) return const SizedBox.shrink();
    // 面板的「上下 / 左右」形制由这里决定：它只是窗口里裁出的一条窄边，
    // 拿它自己的宽高比反推会判反（横屏右侧栏 324×420，比高还窄）。
    final axisPanel = SplitPanelAxis(sideBySide: sideBySide, child: panel);
    // 分隔条不随比例重建：拖拽长度只跟可用尺寸有关。
    final divider = _splitDivider(
      vertical: !sideBySide,
      extent: sideBySide ? availableWidth : availableHeight,
      fallback: defaultRatio,
      palette: palette,
    );
    return ColoredBox(
      color: palette.canvas,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          // 顶部那条已铺成深色（见下方 [splitStatusBarColor]），图标
          // 必须转白；墨水屏仍走白底黑图标。
          statusBarIconBrightness: palette.eink
              ? Brightness.dark
              : Brightness.light,
          statusBarBrightness: palette.eink
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarColor: palette.canvas,
          systemNavigationBarIconBrightness: palette.dark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarDividerColor: palette.canvas,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 只铺状态栏这一条：面板仍是浅色画布，只有压在黑视频上
            // 的那条要跟视频同色（判据见 [splitStatusBarColor]）。
            if (insets.top > 0)
              Positioned(
                key: const ValueKey('player-split-status-bar'),
                left: 0,
                right: 0,
                top: 0,
                height: insets.top,
                child: ColoredBox(color: splitStatusBarColor(palette)),
              ),
            SafeArea(
              child: MediaQuery(
                // 面板是普通页面文字：还原外层字号档，不跟短剧 UI 一起放大。
                data: MediaQuery.of(context).copyWith(textScaler: outerScaler),
                // 拖动分隔条只重排这一层：视频盒按新尺寸重建，面板与分隔条
                // 复用同一个实例，不会重跑内部 build。
                child: ValueListenableBuilder<double?>(
                  valueListenable: _splitRatio,
                  builder: (context, dragged, _) {
                    // 换轴后旧比例作废：竖屏 0.28 当成横屏宽度比例会把画面
                    // 缩成一条，回落到该轴自己的默认值。
                    final draggedRatio = _splitRatioSideBySide == sideBySide
                        ? dragged
                        : null;
                    final ratio = _splitCollapsed
                        ? 1.0
                        : (draggedRatio ?? defaultRatio).clamp(.25, .85);
                    final videoWidth = sideBySide
                        ? (_splitCollapsed
                              ? availableWidth
                              : math.max(
                                  120.0,
                                  availableWidth * ratio - dividerExtent,
                                ))
                        : availableWidth;
                    final videoHeight = sideBySide
                        ? availableHeight
                        : (_splitCollapsed
                              ? availableHeight
                              : math.max(
                                  96.0,
                                  availableHeight * ratio - dividerExtent,
                                ));
                    // 视频盒单独成层：弹幕 / 控件动画只重绘上半区，不带着
                    // 下半区选集列表一起重绘。
                    final stage = RepaintBoundary(
                      child: SizedBox(
                        key: const ValueKey('player-split-stage'),
                        width: videoWidth,
                        height: videoHeight,
                        child: _buildStage(
                          context,
                          window: Size(videoWidth, videoHeight),
                          insets: EdgeInsets.zero,
                          compact: true,
                          outerScaler: outerScaler,
                        ),
                      ),
                    );
                    // 折叠后视频盒占满可用区域，右下角留一个「选集」按钮恢复
                    // 面板；竖屏抬高一点避开底部紧凑控制条。
                    final stageLayer = Stack(
                      children: [
                        stage,
                        if (_splitCollapsed)
                          Positioned(
                            right: 12,
                            bottom: sideBySide ? 12 : 64,
                            child: _splitExpandButton(),
                          ),
                      ],
                    );
                    // stretch：左右分栏时右侧面板要撑满高度，上下分栏时下半区
                    // 要撑满宽度；否则面板若没有内在尺寸会缩成 0。
                    return sideBySide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              stageLayer,
                              // 分隔条可拖比例、点击收起；收起后隐藏面板。
                              if (!_splitCollapsed) divider,
                              if (!_splitCollapsed) Expanded(child: axisPanel),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              stageLayer,
                              if (!_splitCollapsed) divider,
                              if (!_splitCollapsed) Expanded(child: axisPanel),
                            ],
                          );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 拖动分隔条：delta 是本次拖拽位移，extent 是该轴可用长度。
  void _dragSplit(
    double delta,
    double extent,
    double fallback, {
    required bool sideBySide,
  }) {
    if (extent <= 0) return;
    // 换轴后旧比例作废，从该轴自己的默认值起算。
    final current =
        (_splitRatioSideBySide == sideBySide ? _splitRatio.value : null) ??
        fallback;
    final next = (current + delta / extent).clamp(.25, .85);
    if ((next - current).abs() < .001) return;
    _splitRatioSideBySide = sideBySide;
    _splitRatio.value = next;
  }

  /// 分屏分隔条：竖屏上下拖改视频盒高度，横屏左右拖改视频宽度；点一下
  /// 收起整个下半区/右侧栏，把画面留成整屏。
  Widget _splitDivider({
    required bool vertical,
    required double extent,
    required double fallback,
    required HomePalette palette,
  }) {
    final handle = Container(
      width: vertical ? 42 : 4,
      height: vertical ? 4 : 42,
      decoration: BoxDecoration(
        color: palette.muted.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return GestureDetector(
      key: const ValueKey('player-split-divider'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _splitCollapsed = true),
      onVerticalDragUpdate: vertical
          ? (details) => _dragSplit(
              details.delta.dy,
              extent,
              fallback,
              sideBySide: !vertical,
            )
          : null,
      onHorizontalDragUpdate: vertical
          ? null
          : (details) => _dragSplit(
              details.delta.dx,
              extent,
              fallback,
              sideBySide: !vertical,
            ),
      child: Semantics(
        label: vertical ? '上下拖动调整分屏比例，点击收起' : '左右拖动调整分屏比例，点击收起',
        child: MouseRegion(
          cursor: vertical
              ? SystemMouseCursors.resizeRow
              : SystemMouseCursors.resizeColumn,
          child: SizedBox(
            height: vertical ? 18 : double.infinity,
            width: vertical ? double.infinity : 18,
            child: Center(child: handle),
          ),
        ),
      ),
    );
  }

  /// 折叠状态下的恢复入口：视频盒右下角的「选集」小胶囊。
  Widget _splitExpandButton() => Material(
    color: const Color(0x99000000),
    shape: const StadiumBorder(),
    child: InkWell(
      key: const ValueKey('player-split-expand'),
      customBorder: const StadiumBorder(),
      onTap: () => setState(() => _splitCollapsed = false),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.unfold_more_rounded, size: 15, color: Colors.white),
            SizedBox(width: 4),
            Text('选集', style: TextStyle(fontSize: 11, color: Colors.white)),
          ],
        ),
      ),
    ),
  );

  /// 分屏视频盒的上下滑档位 HUD：图标 + 「亮度/音量」+ 百分比 + 细进度条。
  /// 只做反馈，真正的档位由原生窗口/音频通道生效。原生读不到档位时改成
  /// 「暂不可用」，避免用户以为手势没生效。
  Widget _gestureHudOverlay(_GestureHudState state) {
    final brightness = state.kind == _GestureKind.brightness;
    final unavailable = state.unavailable;
    return IgnorePointer(
      child: Align(
        alignment: Alignment.center,
        child: Container(
          key: const ValueKey('player-gesture-hud'),
          width: 168,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    unavailable
                        ? Icons.error_outline_rounded
                        : brightness
                        ? Icons.brightness_6_rounded
                        : Icons.volume_up_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    unavailable
                        ? (brightness ? '亮度不可用' : '音量不可用')
                        : (brightness ? '亮度' : '音量'),
                    key: ValueKey(
                      unavailable
                          ? 'player-gesture-unavailable'
                          : 'player-gesture-label',
                    ),
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                  const Spacer(),
                  Text(
                    unavailable ? '--' : '${(state.value * 100).round()}%',
                    key: const ValueKey('player-gesture-percent'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: unavailable ? 0 : state.value,
                  minHeight: 3,
                  backgroundColor: const Color(0x4DFFFFFF),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    unavailable
                        ? const Color(0x66FFFFFF)
                        : const Color(0xFFFA6725),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分屏视频盒的紧凑控制条：第一行「时间 + 进度 + 总时长」，第二行
  /// 「播放/暂停、下一集、倍速、全屏」。显隐跟随控件（3 秒自动收起）。
  Widget _compactBar() => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: IgnorePointer(
      ignoring: _seeking,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xB3000000)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                return Row(
                  children: [
                    Text(
                      _hms(shown),
                      key: const ValueKey('compact-time'),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [_landShadow],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: StorySeekBar(
                        key: const ValueKey('compact-seek'),
                        value: _progressValue,
                        enabled: duration > Duration.zero,
                        seeking: _seeking,
                        onStart: _startSeek,
                        onChanged: (value) => _seekValue.value = value,
                        onEnd: (value) => unawaited(_finishSeek(value)),
                        onCancel: _cancelSeek,
                        trackWidth: 2,
                        thumbRadius: 6,
                        progressColor: const Color(0xFFFA6725),
                        trackColor: const Color(0x4DFFFFFF),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _hms(duration),
                      key: const ValueKey('compact-total-time'),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [_landShadow],
                      ),
                    ),
                  ],
                );
              },
            ),
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  _landIconButton(
                    'compact-play',
                    _playbackRequested
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    _playbackRequested ? '暂停' : '播放',
                    _togglePlayback,
                  ),
                  if (widget.episodes.length > 1)
                    _landIconButton(
                      'compact-next',
                      Icons.skip_next_rounded,
                      '下一集',
                      _nextEpisodeOrToast,
                    ),
                  const Spacer(),
                  _landText(
                    'compact-rate',
                    _rateText(_rate),
                    _showRatePicker,
                    minSize: 32,
                  ),
                  const SizedBox(width: 16),
                  _landIconButton(
                    'compact-fullscreen',
                    Icons.fullscreen_rounded,
                    '全屏',
                    _toggleFullScreen,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _positionVideo({
    required Size window,
    required EdgeInsets insets,
    required Widget child,
    bool fitVideo = false,
    bool compact = false,
  }) => ValueListenableBuilder<double>(
    valueListenable: _panelExtent,
    child: child,
    builder: (context, fraction, child) {
      final layout = PlayerVideoLayout.calculate(
        window: window,
        insets: insets,
        videoSize: _videoSize,
        // 官方「画面撑满」只换铺排方式，不动解码与进度；但宽屏全屏时
        // `cq3/o.d()` 强制 ASPECT_FIT，撑满不再生效——竖版片源在横屏里居中、
        // 两侧留黑边（`PlayerVideoLayout.fitFor`）。
        // 分屏视频盒同理：盒子里只求完整显示，撑满会裁掉字幕。
        fit: compact
            ? VideoFit.contain
            : PlayerVideoLayout.fitFor(
                fillScreen: widget.fillScreen,
                fullScreen: _fullScreen,
              ),
        panelFraction: compact ? 0 : fraction,
        restingPanelFraction: compact ? 0 : _panelRestFraction,
        fullScreen: _fullScreen,
        compact: compact,
      );
      // Retain the video/cover subtree while only its rectangle follows the
      // panel. DraggableScrollableSheet already retains its own content.
      return Positioned.fromRect(
        rect: fitVideo ? layout.video : layout.viewport,
        child: child!,
      );
    },
  );

  /// 顶栏。竖屏只有「第N集」一行；横屏按 B站 排成两行——剧名｜集数 +
  /// 「全N集 · 状态」，右侧只留更多（⋮ 打开右侧面板）。横屏评论入口已按
  /// 用户要求移除（竖屏右栏的评论按钮保留）；选集入口在底条，弹幕开关与
  /// 设置都在更多面板里。
  Widget _topBar(EdgeInsets insets, {required bool landscape}) {
    // 两行标题在系统大字号下会超过 56dp：按当前字号先量一遍，宁可把顶栏
    // 连同渐变一起长高，也不让 Column 溢出。高度与右缘元素同源。
    final rowHeight = landscape
        ? _landscapeTopBarHeight
        : _portraitTopBarHeight;
    return Positioned(
      // 渐变底色铺满整宽（只让控件本身避开挖孔），否则横握带摄像头的
      // 一侧会出现一条没有压暗的亮缝，跟底条的通栏渐变成两截。
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        // 顶栏实际占位（含随字号长高的行高）：右缘「下一集」卡等元素要按
        // 它让位，测试也靠这个 key 量真实高度。
        key: const ValueKey('player-top-bar'),
        height: insets.top + rowHeight,
        padding: EdgeInsets.only(
          top: insets.top,
          left: insets.left,
          right: insets.right,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // 两行标题需要更实的底色才压得住画面；竖屏全屏同理——弹幕会
            // 铺到顶栏那块，原有的浅压暗看不清标题。
            stops: landscape || _fullScreen ? const [0, .55, 1] : null,
            colors: landscape || _fullScreen
                ? const [
                    Color(0xB3000000),
                    Color(0x80000000),
                    Color(0x00000000),
                  ]
                : const [Colors.black54, Colors.transparent],
          ),
        ),
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
              child: landscape
                  ? _landscapeTitle()
                  : Text(
                      // 官方播放页顶栏标题就是「第1集」这样的集数（截图），
                      // 剧名在底部信息层。
                      '第${widget.currentIndex + 1}集',
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
              onPressed: _showSettingsPanel,
              icon: const Icon(Icons.more_vert, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  /// 横屏顶栏的两行标题：剧名与集数同行（剧名加粗），第二行给集数与
  /// 连载状态——都是已有数据，不新拉接口。
  Widget _landscapeTitle() {
    final total = widget.episodes.length;
    final status = widget.seriesStatus;
    final meta = [
      if (total > 1) '全$total集',
      if (status != null && status.isNotEmpty) status,
    ].join(' · ');
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$_seriesTitle｜第${widget.currentIndex + 1}集',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0x99FFFFFF),
              fontSize: 11.5,
              height: 1.2,
            ),
          ),
        ],
      ],
    );
  }

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
        if (controls && !_hideFullscreenPill)
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
            _screenTextButton(
              'player-rate-text',
              _rateText(_rate),
              _showRatePicker,
            ),
            if (_clearScreenAvailable)
              _screenTextButton(
                'player-clear-screen',
                _clearScreen ? '恢复' : '清屏',
                () => _setClearScreen(!_clearScreen),
              ),
            // 清屏态压掉了顶栏 ⋮，「倍速」文字又只管换档：底栏补一个
            // 「设置」出口，视频设置（弹幕设置/字号/退出清屏）不至于点不到。
            if (_clearScreen)
              _screenTextButton(
                'player-settings-text',
                '设置',
                _showSettingsPanel,
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
            _showQualityPicker,
          ),
        _legacyAction(
          'player-rate-text',
          _rateText(_rate),
          const SizedBox(
            width: 28,
            height: 28,
            child: CustomPaint(painter: _LegacyRatePainter()),
          ),
          _showRatePicker,
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
        // 清屏态压掉了顶栏 ⋮：旧底栏同样补一个「设置」出口（与新栏同形）。
        if (_clearScreen)
          _legacyAction(
            'player-settings-text',
            '设置',
            const Icon(Icons.more_vert, size: 20, color: Colors.white),
            _showSettingsPanel,
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

  /// 胶囊本体见 [PlayletFullscreenPill]：竖屏目录态、竖屏全屏的贴底出口
  /// 与通用播放器共用同一份文案与内边距。
  Widget _fullscreenPill() => PlayletFullscreenPill(
    fullScreen: _fullScreen,
    shortSeries: widget.shortSeries,
    onTap: _toggleFullScreen,
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
          if (showPill && !_hideFullscreenPill)
            Center(child: _fullscreenPill()),
          if (showPill && !_hideFullscreenPill) const SizedBox(height: 12),
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

  Widget _clearScreenIcon() =>
      PlayletClearScreenButton(onTap: () => _setClearScreen(true));

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
              onPressed: _showRatePicker,
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

  /// 横屏底条（按 B站横屏播放器重排，落位取真机实测 dp）：
  /// - 时间行：`当前 / 总` 13sp 粗体（恒 `HH:MM:SS`，官方 `d7.o(sec, true)`），
  ///   从控制行里提出来、压到进度条上方；
  /// - 进度条：通栏橙色细轨（轨道 3 / 滑块 6），拖动中自动加粗；
  /// - 控制行：左「播放 / 下一集」，右「选集 / 倍速 / 清晰度」（清晰度在最右，
  ///   多档流在场才出现）；弹幕开关与设置收进右上角 ⋮ 面板。
  ///
  /// 与番茄官方横屏（时间在控制行内、130dp 两行）的差异：按用户选定的
  /// B站 形态重排，入口与语义一一对应，不新增数据源；官方那一行的评论
  /// 计数、弹幕输入框仍不显示（无发送接口，见诚实清单）。
  Widget _landscapeBar(EdgeInsets insets) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: Container(
      height: insets.bottom + 132,
      padding: EdgeInsets.only(
        bottom: insets.bottom + 4,
        left: insets.left + 16,
        right: insets.right + 16,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, .5, 1],
          colors: [Color(0x00000000), Color(0x66000000), Color(0xB3000000)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        // 通栏：进度条本身没有固有宽度，不 stretch 会被 Column 居中成 0 宽。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 20,
            child: Row(
              children: [
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
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        shadows: [_landShadow],
                      ),
                    );
                  },
                ),
                const Text(
                  ' / ',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    color: Color(0x8CFFFFFF),
                    shadows: [_landShadow],
                  ),
                ),
                Text(
                  key: const ValueKey('landscape-total-time'),
                  _hms(widget.duration),
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    color: Color(0xB3FFFFFF),
                    shadows: [_landShadow],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          // StorySeekBar 自带 30dp 命中高度：进度线本身压在中间。
          StorySeekBar(
            key: const ValueKey('landscape-seek'),
            value: _progressValue,
            enabled: widget.duration > Duration.zero,
            seeking: _seeking,
            onStart: _startSeek,
            onChanged: (value) => _seekValue.value = value,
            onEnd: (value) => unawaited(_finishSeek(value)),
            onCancel: _cancelSeek,
            trackWidth: 3,
            thumbRadius: 6,
            progressColor: const Color(0xFFFA6725),
            trackColor: const Color(0x47FFFFFF),
          ),
          const SizedBox(height: 4),
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
                  minSize: 40,
                ),
                const SizedBox(width: 8),
                if (widget.episodes.length > 1)
                  _landIconButton(
                    'landscape-next',
                    Icons.skip_next_rounded,
                    '下一集',
                    _nextEpisodeOrToast,
                    minSize: 40,
                  ),
                // 弹幕开关与弹幕设置都收进右上角 ⋮ 更多面板（横屏底条只留
                // 播放控制与选集/倍速/清晰度），避免底条挤成一排图标。
                const Spacer(),
                // B站 功能行序：字幕（无数据源，不做）→ 选集 → 倍速 →
                // 清晰度。倍速/清晰度各自开自己的档位面板：这两项已经写在
                // 底条上显示当前档，点它就是要换档，不该再绕进视频设置。
                if (widget.episodes.length > 1) ...[
                  _landText('landscape-episodes', '选集', _openPanel),
                  const SizedBox(width: 20),
                ],
                _landText(
                  'landscape-rate',
                  _rateText(_rate),
                  _showLandscapeRateSheet,
                ),
                if (widget.qualityVariants.length > 1) ...[
                  const SizedBox(width: 20),
                  _landText(
                    'landscape-quality',
                    _qualityLabel(),
                    _showLandscapeQualitySheet,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );

  /// 横屏右缘的「下一集」卡（B站横屏同款，只放右侧）。
  ///
  /// 卡片是 16:9 的横框（理想比例）：封面（竖版剧照）按 `cover` 铺进去后
  /// 纵向只露出约 1/3 的内容，底部压「下一集 / 第X集」两行字。
  ///
  /// 宽度另有 96dp 下限（右半出屏后可见半宽 ≥48dp 触控下限），所以高度在
  /// 48–53dp 的极端矮带里卡片会比 16:9 略方；这种带子再矮就直接不画。
  ///
  /// 位置：锁定按钮在场时排在它**正下方**（锁仍钉在右缘中点，不动），高度
  /// 由「锁底到计时间行」的剩余空间决定、不足就等比缩小；没接锁功能时仍在
  /// 顶栏与底条之间居中。竖版片源贴右黑边，横版/满宽片源叠在画面右缘内侧。
  /// 最后一集不摆。
  Widget _nextEpisodeCard({required Size window, required EdgeInsets insets}) {
    final next = widget.currentIndex + 1;
    if (next >= widget.episodes.length) return const SizedBox.shrink();
    final video = PlayerVideoLayout.calculate(
      window: window,
      insets: insets,
      videoSize: _videoSize,
      fit: PlayerVideoLayout.fitFor(
        fillScreen: widget.fillScreen,
        fullScreen: _fullScreen,
      ),
      fullScreen: _fullScreen,
    ).video;
    // 顶栏（`insets.top + 行高`）与底条（`insets.bottom + 150`）占掉上下两截。
    // 行高与 `_topBar` 同源：大字号下顶栏会变高，卡片不能让进它的渐变里。
    final top = insets.top + _landscapeTopBarHeight;
    final bottom = insets.bottom + 150;
    final bandHeight = window.height - top - bottom;
    // 「放不下就不画」的唯一门在下面两条分支里（无锁分支 48dp，锁分支按锁底
    // 余量判），这里不再另设一道更松的阈值。
    // 底条里「计时间」那一行只在左侧有字，右侧整段是空的：卡片可以压到
    // 进度条上沿（`height - 84`）为止，只留 6dp 呼吸，不去碰进度条本身。
    // 这样锁下方 42dp 的空间能用满到 66dp，16:9 卡高才不至于太短。
    final cardBottomLimit = window.height - insets.bottom - 84;
    // 锁按钮钉在右缘垂直中点（48dp），**位置不动**；卡片排在它正下方。
    final lockTop = math.max(insets.top, (window.height - 48) / 2);
    final double cardTop;
    final double height;
    if (_landscapeLockShown) {
      cardTop = lockTop + 48 + 6;
      final available = cardBottomLimit - cardTop;
      // 锁下方塞不下「图 + 两行字」时宁可不摆，也不挤成一条缝。
      if (available < 48) return const SizedBox.shrink();
      // 空间不足就等比缩小（48–72dp），两行字始终完整。
      height = available.clamp(48.0, 72.0);
    } else {
      // 中间带连一张 48dp 的卡都放不下（大字号 + 极扁窗口）：宁可不画，
      // 也不给一张低于最小触控尺寸、比例被压扁的卡。
      if (bandHeight < 48) return const SizedBox.shrink();
      height = (bandHeight - 16).clamp(48.0, 72.0);
      cardTop = top + (bandHeight - height) / 2;
    }
    // 卡片是 16:9 的横框：封面是竖版剧照，`cover` 按宽度铺满后纵向只能露出
    // 约 1/3（9:16 的图放进 16:9 的框，可见高度 = 卡高的 1/3 左右），高度
    // 决定宽度，不再拉成横跨画面的长条。
    //
    // 右黑边宽度只用来给卡片限宽：黑边够宽（竖版片源）时不超过它；太窄
    // （16:9/更宽的片源）时按 200dp 封顶，卡片叠在画面右缘内侧。位置本身
    // 与黑边无关——见下面的 `right`（恒定推出半宽）。
    final bandWidth = window.width - insets.right - video.right;
    final maxWidth = bandWidth >= 96 ? bandWidth : 200.0;
    // 右半出屏后可见/可点的只有左半：宽度下限按「可见 ≥48dp」反推（≥96dp），
    // 空间极端时宁可略扁一点，也不做 44dp 的迷你热区。
    final width = math.max(96.0, math.min(height * 16 / 9, maxWidth));
    // 只留左半在屏内：`right` 是「距右缘的内缩量」，取负值才会把卡片推出
    // 右边缘半个宽度——右半溢出屏幕，露出的左半截仍带「下一集/第X集」。
    // 再让开右侧挖孔（`insets.right`）：挖孔区不承载可见内容，露出的半截
    // 要落在它左边，否则挖孔机型上会有 24–32dp 内容被切在孔里。
    // 纵向与锁定按钮的相对位置不变（仍排在它正下方）。
    final right = insets.right - width / 2;
    return Positioned(
      top: cardTop,
      right: right,
      width: width,
      height: height,
      child: Semantics(
        button: true,
        // 读屏要把「第N集」念出来：卡片上真正的信息是集数，不是「下一集」。
        label: '下一集，第${next + 1}集',
        // `excludeSemantics` 会丢掉子树的全部语义（含 GestureDetector 的
        // tap action），所以激活动作必须挂在 Semantics 自己身上，否则读屏
        // 能聚焦却点不动。
        onTap: () => unawaited(_selectEpisode(next)),
        excludeSemantics: true,
        child: GestureDetector(
          key: const ValueKey('landscape-next-card'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_selectEpisode(next)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 只露出封面 1/3：把图按「三倍卡高」铺进去、整体上移一个
                // 卡高，窗口正好切在中间那 1/3 上。竖版海报、横版横图都成立
                // （`cover` 先按三倍高度装填，再被卡片窗口裁掉上下两截）。
                Positioned(
                  left: 0,
                  right: 0,
                  top: -height,
                  height: height * 3,
                  child: PlayerCover(url: widget.coverUrl),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [.45, 1],
                      colors: [Colors.transparent, Color(0xE6000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 6,
                  // 只排进屏的可见左半（另一半在屏外）：elision 才会落在
                  // 屏内。大字号下「第100集」会被省略号规整截断，而不是被
                  // 屏幕边缘硬切掉半个字。
                  right: width / 2 + 6,
                  bottom: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '下一集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          color: Color(0xCCFFFFFF),
                        ),
                      ),
                      const SizedBox(height: 1),
                      // 极矮带里可见文字列只剩约 36dp：让集数等比缩到放得下，
                      // 而不是把「第100集」省略成「第…」。
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '第${next + 1}集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 官方横屏防误触锁（`fullscreen/d.J6()`，配置门 `landscape_func_config_v705
  /// .enable_lock`，默认关闭）：贴右缘垂直居中（B站横屏同位置，不再吊在
  /// 顶栏下面），36dp 的 `unlock_speed.json`（帧 0 解锁 / 帧 20 锁定）。
  /// 未锁定时随控件条出现，锁定后 5 秒自动隐藏，任意触摸把它重新唤出
  /// （`d.G6()`）。
  Widget _lockButton(Size window, EdgeInsets insets) {
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
      top: math.max(insets.top, (window.height - 48) / 2),
      right: insets.right + 4,
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
                        _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
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
    VoidCallback onPressed, {
    double minSize = 32,
  }) => IconButton(
    key: ValueKey(key),
    tooltip: tooltip,
    onPressed: onPressed,
    padding: EdgeInsets.zero,
    constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
    color: Colors.white,
    iconSize: 32,
    icon: Icon(icon, shadows: const [_landShadow]),
  );

  /// 横屏横排里的文字按钮。[minSize] 是命中区下限：横屏底条给 40，
  /// 分屏紧凑条只有 32 高，必须传 32 才不会撑破那一行。
  Widget _landText(
    String key,
    String label,
    VoidCallback onPressed, {
    double minSize = 40,
  }) => GestureDetector(
    key: ValueKey(key),
    behavior: HitTestBehavior.opaque,
    onTap: onPressed,
    child: ConstrainedBox(
      constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
      child: Align(
        widthFactor: 1,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [_landShadow],
          ),
        ),
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
    PlayerToast.show(context, '当前已在最后一集');
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

    // 竖版剧集不渲染全屏胶囊（`_hideFullscreenPill`），但评论钮可能仍在：
    // 两个 slot 各自独立判断，缺一个不能把另一个也丢掉。
    final hasPill = hasChild(_PortraitSlot.fullscreen);
    final hasComments = hasChild(_PortraitSlot.comments);
    if (!hasPill && !hasComments) return;
    final pill = hasPill
        ? layoutChild(
            _PortraitSlot.fullscreen,
            BoxConstraints(maxWidth: math.max(0.0, width - 144)),
          )
        : Size.zero;
    final comments = hasComments
        ? layoutChild(
            _PortraitSlot.comments,
            const BoxConstraints(maxWidth: 64),
          )
        : Size.zero;
    final actionHeight = math.max(pill.height, comments.height - 4);
    final maximumTop = math.max(minimumTop, informationTop - actionHeight - 16);
    final top = math.min(math.max(videoBottom + 20, minimumTop), maximumTop);
    if (hasPill) {
      positionChild(
        _PortraitSlot.fullscreen,
        Offset(insets.left + (width - pill.width) / 2, top),
      );
    }
    if (hasComments) {
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

/// 官方倍速文案（`SingleVideoHolder.java:1155-1171`）：1.0 显示「倍速」，
/// 其余 `数值x`（如 `1.5x`）。
String _rateText(double rate) => rate == 1 ? '倍速' : '${_rateLabel(rate)}x';

/// 官方档位 chip 文案（`ShortSeriesMorePanelDialogV2.java:873-892`）：
/// `0.75x / 1x / 1.25x / 1.5x / 1.75x / 2x`。
String _rateChipLabel(double rate) => '${_rateLabel(rate)}x';

String _time(Duration value) => formatPlaybackTime(value);
