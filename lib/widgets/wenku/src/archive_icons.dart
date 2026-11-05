import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'archive_motion.dart';
import 'performance_preferences.dart';
import 'app_haptics.dart';

part 'archive_icon_art.dart';
part 'archive_icon_motion.dart';
part 'archive_icon_fold_art.dart';

/// Paper & Archive: original, optical 24-unit vectors. The launcher artwork is
/// independent of this functional icon family.
enum ArchiveSymbol {
  discover('发现', '导航'),
  shelf('书架', '导航'),
  book('阅读', '导航'),
  folder('本地书库', '导航'),
  folderOpen('打开文件夹', '导航'),
  profile('我的', '导航'),
  back('返回', '导航'),
  forward('前进', '导航'),
  up('收起', '导航'),
  down('展开', '导航'),
  arrowLeft('上一项', '导航'),
  arrowRight('下一项', '导航'),
  arrowUp('向上', '导航'),
  arrowDown('向下', '导航'),
  external('打开链接', '导航'),
  close('关闭', '导航'),
  more('更多', '导航'),
  contents('目录', '阅读'),
  bookmark('书签', '阅读'),
  bookmarked('已收藏', '阅读'),
  location('定位章节', '阅读'),
  locationFilled('跟随朗读', '阅读'),
  typography('字体', '阅读'),
  sliders('阅读设置', '阅读'),
  image('插图', '阅读'),
  brightness('亮度', '阅读'),
  moon('夜间阅读', '阅读'),
  layers('合并卷', '阅读'),
  quotes('摘录', '阅读'),
  language('双语', '阅读'),
  portrait('强制竖屏', '阅读'),
  headphones('听书', '听书'),
  play('播放', '听书'),
  pause('暂停', '听书'),
  stop('停止', '听书'),
  previous('上一段', '听书'),
  next('下一段', '听书'),
  waveform('声音', '听书'),
  voice('音色', '听书'),
  volume('音量', '听书'),
  speed('速度', '听书'),
  timer('历史与定时', '听书'),
  search('搜索', '操作'),
  filter('筛选排序', '操作'),
  layout('视图布局', '操作'),
  grid('网格视图', '操作'),
  dotsGrid('布局', '操作'),
  add('添加', '操作'),
  addCircle('添加项目', '操作'),
  removeCircle('移出', '操作'),
  check('完成', '操作'),
  checkCircle('勾选', '操作'),
  selected('已选择', '操作'),
  circle('未选择', '操作'),
  edit('编辑', '操作'),
  delete('删除', '操作'),
  copy('复制', '操作'),
  share('分享', '操作'),
  link('关联原文件', '操作'),
  refresh('刷新重试', '操作'),
  sync('同步', '文件'),
  download('下载', '文件'),
  cloudDownload('离线缓存', '文件'),
  upload('更新', '文件'),
  importFile('导入', '文件'),
  document('文档', '文件'),
  folderAdd('添加目录', '文件'),
  wand('整理修复', '文件'),
  settings('设置', '系统'),
  info('关于', '系统'),
  warning('异常', '系统'),
  wifi('无线连接', '系统'),
  wifiOff('离线', '系统'),
  wifiWarning('连接异常', '系统'),
  cloud('云书库', '系统'),
  globe('官网', '系统'),
  phone('手机', '系统'),
  laptop('电脑', '系统'),
  branch('同步冲突', '系统'),
  personAdd('注册账号', '系统'),
  eye('显示', '系统'),
  eyeOff('隐藏', '系统'),
  closeCircle('清空', '系统'),
  battery('电量', '系统'),
  charging('充电', '系统'),
  tools('故障排查', '系统'),
  shield('安全', '系统'),
  help('帮助', '系统'),
  touch('触摸', '阅读');

  const ArchiveSymbol(this.label, this.group);
  final String label, group;
}

/// Compatibility is deliberate: existing action APIs still take IconData, and
/// existing callers retain their identity, semantics, and directional contract.
abstract final class ArchiveIconSymbols {
  static final legacy = Map<IconData, ArchiveSymbol>.unmodifiable({
    CupertinoIcons.house: ArchiveSymbol.discover,
    CupertinoIcons.book: ArchiveSymbol.book,
    CupertinoIcons.book_fill: ArchiveSymbol.book,
    CupertinoIcons.folder: ArchiveSymbol.folder,
    CupertinoIcons.folder_open: ArchiveSymbol.folderOpen,
    CupertinoIcons.person_crop_circle: ArchiveSymbol.profile,
    CupertinoIcons.back: ArchiveSymbol.back,
    CupertinoIcons.chevron_left: ArchiveSymbol.back,
    CupertinoIcons.chevron_right: ArchiveSymbol.forward,
    CupertinoIcons.chevron_forward: ArchiveSymbol.forward,
    CupertinoIcons.chevron_up: ArchiveSymbol.up,
    CupertinoIcons.chevron_down: ArchiveSymbol.down,
    CupertinoIcons.arrow_left: ArchiveSymbol.arrowLeft,
    CupertinoIcons.arrow_right: ArchiveSymbol.arrowRight,
    CupertinoIcons.arrow_up_right: ArchiveSymbol.external,
    CupertinoIcons.xmark: ArchiveSymbol.close,
    CupertinoIcons.ellipsis: ArchiveSymbol.more,
    CupertinoIcons.list_bullet: ArchiveSymbol.contents,
    CupertinoIcons.line_horizontal_3: ArchiveSymbol.contents,
    CupertinoIcons.bookmark: ArchiveSymbol.bookmark,
    CupertinoIcons.bookmark_fill: ArchiveSymbol.bookmarked,
    CupertinoIcons.location: ArchiveSymbol.location,
    CupertinoIcons.location_fill: ArchiveSymbol.locationFilled,
    CupertinoIcons.hand_draw: ArchiveSymbol.touch,
    CupertinoIcons.textformat: ArchiveSymbol.typography,
    CupertinoIcons.slider_horizontal_3: ArchiveSymbol.sliders,
    CupertinoIcons.photo: ArchiveSymbol.image,
    Icons.image_outlined: ArchiveSymbol.image,
    CupertinoIcons.sun_max: ArchiveSymbol.brightness,
    CupertinoIcons.moon_stars: ArchiveSymbol.moon,
    CupertinoIcons.moon: ArchiveSymbol.moon,
    CupertinoIcons.square_stack: ArchiveSymbol.layers,
    CupertinoIcons.lock_rotation: ArchiveSymbol.portrait,
    CupertinoIcons.headphones: ArchiveSymbol.headphones,
    CupertinoIcons.play_fill: ArchiveSymbol.play,
    CupertinoIcons.pause_fill: ArchiveSymbol.pause,
    CupertinoIcons.stop_fill: ArchiveSymbol.stop,
    CupertinoIcons.backward_end: ArchiveSymbol.previous,
    CupertinoIcons.forward_end: ArchiveSymbol.next,
    CupertinoIcons.waveform: ArchiveSymbol.waveform,
    CupertinoIcons.speedometer: ArchiveSymbol.speed,
    CupertinoIcons.clock: ArchiveSymbol.timer,
    CupertinoIcons.search: ArchiveSymbol.search,
    CupertinoIcons.line_horizontal_3_decrease: ArchiveSymbol.filter,
    CupertinoIcons.rectangle_grid_1x2: ArchiveSymbol.layout,
    CupertinoIcons.rectangle_grid_2x2: ArchiveSymbol.grid,
    CupertinoIcons.square_grid_2x2: ArchiveSymbol.grid,
    CupertinoIcons.circle_grid_3x3: ArchiveSymbol.dotsGrid,
    CupertinoIcons.plus: ArchiveSymbol.add,
    CupertinoIcons.plus_circle: ArchiveSymbol.addCircle,
    CupertinoIcons.minus_circle: ArchiveSymbol.removeCircle,
    CupertinoIcons.check_mark: ArchiveSymbol.check,
    CupertinoIcons.checkmark_circle: ArchiveSymbol.checkCircle,
    CupertinoIcons.checkmark_circle_fill: ArchiveSymbol.selected,
    CupertinoIcons.circle: ArchiveSymbol.circle,
    CupertinoIcons.pencil: ArchiveSymbol.edit,
    CupertinoIcons.trash: ArchiveSymbol.delete,
    CupertinoIcons.doc_on_doc: ArchiveSymbol.copy,
    CupertinoIcons.link: ArchiveSymbol.link,
    CupertinoIcons.refresh: ArchiveSymbol.refresh,
    // arrow_clockwise is the same IconData as refresh.
    CupertinoIcons.arrow_2_circlepath: ArchiveSymbol.sync,
    CupertinoIcons.arrow_down_to_line: ArchiveSymbol.download,
    CupertinoIcons.cloud_download: ArchiveSymbol.cloudDownload,
    CupertinoIcons.arrow_up_circle: ArchiveSymbol.upload,
    CupertinoIcons.arrow_down_doc: ArchiveSymbol.importFile,
    CupertinoIcons.square_arrow_down: ArchiveSymbol.importFile,
    CupertinoIcons.doc_text: ArchiveSymbol.document,
    CupertinoIcons.folder_badge_plus: ArchiveSymbol.folderAdd,
    CupertinoIcons.wand_stars: ArchiveSymbol.wand,
    CupertinoIcons.settings: ArchiveSymbol.settings,
    CupertinoIcons.gear_alt: ArchiveSymbol.settings,
    CupertinoIcons.info_circle: ArchiveSymbol.info,
    CupertinoIcons.exclamationmark_triangle: ArchiveSymbol.warning,
    CupertinoIcons.wifi: ArchiveSymbol.wifi,
    CupertinoIcons.wifi_slash: ArchiveSymbol.wifiOff,
    CupertinoIcons.wifi_exclamationmark: ArchiveSymbol.wifiWarning,
    CupertinoIcons.cloud: ArchiveSymbol.cloud,
    CupertinoIcons.globe: ArchiveSymbol.globe,
    CupertinoIcons.device_phone_portrait: ArchiveSymbol.phone,
    CupertinoIcons.device_laptop: ArchiveSymbol.laptop,
    CupertinoIcons.arrow_branch: ArchiveSymbol.branch,
    CupertinoIcons.person_badge_plus: ArchiveSymbol.personAdd,
    CupertinoIcons.eye: ArchiveSymbol.eye,
    CupertinoIcons.eye_slash: ArchiveSymbol.eyeOff,
    CupertinoIcons.xmark_circle_fill: ArchiveSymbol.closeCircle,
    CupertinoIcons.battery_100: ArchiveSymbol.battery,
    CupertinoIcons.bolt_fill: ArchiveSymbol.charging,
    CupertinoIcons.wrench: ArchiveSymbol.tools,
    CupertinoIcons.paintbrush: ArchiveSymbol.edit,
  });

  static ArchiveSymbol? resolve(IconData? icon) => legacy[icon];
}

/// A button lends its contact state to its icons. It doesn't add a gesture
/// recognizer or handle an action, so scrolling/cancellation still belongs to
/// the original control. No route-entry or idle animation is started here.
class ArchiveIconContact extends InheritedWidget {
  const ArchiveIconContact({
    super.key,
    required this.pressed,
    this.activation = 0,
    required super.child,
  });
  final bool pressed;
  final int activation;
  static int activationOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ArchiveIconContact>()
          ?.activation ??
      0;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ArchiveIconContact>()
          ?.pressed ??
      false;
  @override
  bool updateShouldNotify(ArchiveIconContact oldWidget) =>
      pressed != oldWidget.pressed || activation != oldWidget.activation;
}

class ArchiveIconResponse extends StatefulWidget {
  const ArchiveIconResponse({
    super.key,
    required this.child,
    this.enabled = true,
    this.haptic = HapticCue.action,
  }) : builder = null;
  const ArchiveIconResponse.builder({
    super.key,
    required this.builder,
    this.enabled = true,
    this.haptic = HapticCue.action,
  }) : child = null;
  final Widget? child;
  final Widget Function(BuildContext, VoidCallback)? builder;
  final bool enabled;
  final HapticCue? haptic;
  @override
  State<ArchiveIconResponse> createState() => _ArchiveIconResponseState();
}

class _ArchiveIconResponseState extends State<ArchiveIconResponse> {
  bool _pressed = false;
  int _activation = 0;
  int? _pointer;
  void _activate() {
    AppHaptics.play(context, widget.haptic);
    setState(() => _activation++);
  }

  void _release(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: !widget.enabled
        ? null
        : (event) {
            if (_pointer != null) return;
            _pointer = event.pointer;
            setState(() => _pressed = true);
          },
    onPointerUp: _release,
    onPointerCancel: _release,
    child: ArchiveIconContact(
      pressed: widget.enabled && _pressed,
      activation: _activation,
      child: widget.builder?.call(context, _activate) ?? widget.child!,
    ),
  );
}

/// Drop-in Material control with the same hit area, focus, tooltip and disabled
/// semantics. Only the foreground glyph gains the shared contact response.
class ArchiveIconButton extends IconButton {
  const ArchiveIconButton({
    super.key,
    required super.icon,
    required super.onPressed,
    super.tooltip,
    super.iconSize,
    super.padding,
    super.constraints,
    super.color,
    super.disabledColor,
    super.style,
    super.alignment,
    super.visualDensity,
    this.haptic = HapticCue.action,
  });
  final HapticCue? haptic;

  @override
  Widget build(BuildContext context) => ArchiveIconResponse.builder(
    enabled: onPressed != null,
    haptic: haptic,
    builder: (context, activate) => IconButton(
      icon: icon,
      onPressed: onPressed == null
          ? null
          : () {
              activate();
              onPressed!();
            },
      tooltip: tooltip,
      iconSize: iconSize,
      padding: padding,
      constraints: constraints,
      color: color,
      disabledColor: disabledColor,
      style: style,
      alignment: alignment,
      visualDensity: visualDensity,
    ).build(context),
  );
}

/// A real vector icon rather than a transformed font glyph. Extending Icon
/// keeps IconData-based callers and tooling working while painting our artwork.
/// State changes morph; pressing moves the relevant part of the drawing. Visible
/// icons greet a page entry once without fading or changing their layout.
class ArchiveIcon extends Icon {
  const ArchiveIcon(
    super.icon, {
    super.key,
    super.size,
    super.color,
    super.semanticLabel,
    super.textDirection,
    super.applyTextScaling,
    super.fill,
    super.weight,
    super.grade,
    super.opticalSize,
    super.shadows,
    super.blendMode,
    super.fontWeight,
    this.symbol,
    this.active = false,
    this.animate = true,
    this.ambient = false,
    this.trigger,
  });

  const ArchiveIcon.symbol(
    this.symbol, {
    super.key,
    super.size,
    super.color,
    super.semanticLabel,
    super.textDirection,
    super.applyTextScaling,
    this.active = false,
    this.animate = true,
    this.ambient = false,
    this.trigger,
  }) : super(null);

  final ArchiveSymbol? symbol;
  final bool active, animate;

  /// Presentation icons (empty shelves, notices) also move occasionally at rest.
  /// Other icons play only on page entry and accepted interaction.
  final bool ambient;

  /// Replay one complete gesture without changing the represented action.
  final Object? trigger;

  @override
  Widget build(BuildContext context) {
    final glyph = symbol ?? ArchiveIconSymbols.resolve(icon);
    if (glyph == null) return super.build(context);
    final theme = IconTheme.of(context);
    final rawSize = size ?? theme.size ?? 24;
    final extent = (applyTextScaling ?? theme.applyTextScaling ?? false)
        ? MediaQuery.textScalerOf(context).scale(rawSize)
        : rawSize;
    final tint = color ?? theme.color ?? const Color(0xFF181818);
    final opacity = theme.opacity ?? 1;
    final rtl =
        (textDirection ?? Directionality.of(context)) == TextDirection.rtl;
    final directional = icon?.matchTextDirection ?? _directional(glyph);
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: extent,
          child: Center(
            child: _ArchiveGlyph(
              symbol: glyph,
              color: tint.withValues(alpha: tint.a * opacity),
              active: active || icon == CupertinoIcons.book_fill,
              pressed: ArchiveIconContact.of(context),
              ambient: ambient,
              trigger: (trigger, ArchiveIconContact.activationOf(context)),
              pageAnimation:
                  ArchiveMotionScope.maybeOf(context)?.animation ??
                  ModalRoute.of(context)?.animation,
              visible:
                  TickerMode.valuesOf(context).enabled &&
                  ModalRoute.isCurrentOf(context) != false,
              still:
                  !animate ||
                  PerformanceScope.reduceMotionOf(context) ||
                  !PerformanceScope.of(context).animatedIcons ||
                  !TickerMode.valuesOf(context).enabled,
              contrast: MediaQuery.highContrastOf(context),
              mirrored: rtl && directional,
              blendMode: blendMode ?? BlendMode.srcOver,
              size: extent,
            ),
          ),
        ),
      ),
    );
  }

  static bool _directional(ArchiveSymbol symbol) => switch (symbol) {
    ArchiveSymbol.back || ArchiveSymbol.forward => true,
    _ => false,
  };
}

class _ArchiveGlyph extends StatefulWidget {
  const _ArchiveGlyph({
    required this.symbol,
    required this.color,
    required this.active,
    required this.pressed,
    required this.ambient,
    required this.trigger,
    required this.pageAnimation,
    required this.visible,
    required this.still,
    required this.contrast,
    required this.mirrored,
    required this.blendMode,
    required this.size,
  });
  final ArchiveSymbol symbol;
  final Color color;
  final bool active, pressed, ambient, visible, still, contrast, mirrored;
  final Object? trigger;
  final Animation<double>? pageAnimation;
  final BlendMode blendMode;
  final double size;
  @override
  State<_ArchiveGlyph> createState() => _ArchiveGlyphState();
}

/// One layout pass knows the visible rows, so equal rows start together and
/// the full top-to-bottom cascade remains legible on both short and tall pages.
/// Pending entries live only until this frame's microtasks have completed.
abstract final class _ArchiveIconEntranceBatch {
  static final _pending =
      <Object, List<({_ArchiveGlyphState glyph, Rect bounds, int ticket})>>{};
  static bool _scheduled = false;

  static void add(_ArchiveGlyphState glyph, Rect bounds, int ticket) {
    final context = glyph.context;
    final group = (View.of(context), ModalRoute.of(context));
    (_pending[group] ??= []).add((
      glyph: glyph,
      bounds: bounds,
      ticket: ticket,
    ));
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_flush);
  }

  static void _flush() {
    _scheduled = false;
    final batches = _pending.values.toList();
    _pending.clear();
    for (final entries in batches) {
      entries.removeWhere((entry) => !entry.glyph._entryCurrent(entry.ticket));
      entries.sort((a, b) => a.bounds.center.dy.compareTo(b.bounds.center.dy));
      final rows =
          <List<({_ArchiveGlyphState glyph, Rect bounds, int ticket})>>[];
      for (final entry in entries) {
        if (rows.isEmpty ||
            entry.bounds.center.dy - rows.last.first.bounds.center.dy > 16) {
          rows.add([]);
        }
        rows.last.add(entry);
      }
      for (var i = 0; i < rows.length; i++) {
        final delay = rows.length == 1
            ? 0
            : (i * 360 / (rows.length - 1)).round();
        for (final entry in rows[i]) {
          entry.glyph._setEntranceDelay(delay, entry.ticket);
        }
      }
    }
  }
}

class _ArchiveGlyphState extends State<_ArchiveGlyph>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _ambientRest = Duration(milliseconds: 2600);
  static final _scrolledPositions = Expando<bool>();
  Timer? _ambientTimer;
  bool _foreground = true;
  bool _finishVisibleGesture = false;
  int _entryTicket = 0;
  double _gestureStart = 0;
  double _gestureSpan = 1;
  AnimationStatus? _pageStatus;
  bool _entryAfterTransition = false;
  late final _change = AnimationController(
    vsync: this,
    duration: ArchiveIconMotion.morphDuration,
    value: 1,
  );
  late final _contact = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
    reverseDuration: const Duration(milliseconds: 240),
    value: widget.still ? 0 : (widget.pressed ? 1 : 0),
  );
  late final _gesture = AnimationController(
    vsync: this,
    duration: ArchiveIconMotion.duration,
    value: 1,
  );
  late final _paint = Listenable.merge([_change, _contact, _gesture]);
  ArchiveIconGesture _origin = ArchiveIconGesture.rest;
  late _IconPose _from = _IconPose.of(widget.symbol, widget.active);
  late _IconPose _to = _from;

  bool get _still =>
      widget.still ||
      !_foreground ||
      (!widget.visible && !_finishVisibleGesture);
  bool get _ambientAllowed => widget.ambient && widget.visible && !_still;

  bool _entryCurrent(int ticket) =>
      mounted && ticket == _entryTicket && !_still && widget.visible;

  void _setEntranceDelay(int milliseconds, int ticket) {
    if (!_entryCurrent(ticket)) return;
    setState(() => _gestureStart = milliseconds / 880);
  }

  @override
  void initState() {
    super.initState();
    _gesture.addStatusListener(_gestureStatus);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _listenToPage(widget.pageAnimation);
    _queueEntrance(fromMount: true);
  }

  void _listenToPage(Animation<double>? animation) {
    _pageStatus = animation?.status;
    animation?.addStatusListener(_pageChanged);
  }

  void _pageChanged(AnimationStatus status) {
    final previous = _pageStatus;
    _pageStatus = status;
    // The shared header survives tab switches. Only a new page entry resets
    // this clock; ordinary rebuilds and animation frames do not replay icons.
    if ((previous == AnimationStatus.completed &&
            (status == AnimationStatus.forward ||
                status == AnimationStatus.dismissed)) ||
        (status == AnimationStatus.completed && _entryAfterTransition)) {
      _queueEntrance();
    }
  }

  Rect? _visibleBounds() {
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    var bounds = MatrixUtils.transformRect(
      render.getTransformTo(null),
      render.paintBounds,
    );
    final view = View.of(context);
    final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    bounds = bounds.intersect(screen);
    RenderObject child = render;
    while (!bounds.isEmpty && child.parent != null) {
      final parent = child.parent!;
      if (parent is RenderOffstage && parent.offstage) return null;
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        bounds = bounds.intersect(
          MatrixUtils.transformRect(parent.getTransformTo(null), clip),
        );
      }
      child = parent;
    }
    return bounds.isEmpty || !bounds.isFinite ? null : bounds;
  }

  void _queueEntrance({bool fromMount = false}) {
    _entryAfterTransition = false;
    if (_still || !widget.visible) return;
    // Start at the rest pose in this frame. Layout verifies visibility before
    // any moving frame is painted, while the clock stays aligned with the
    // route/tab animation rather than starting one frame behind it.
    _replay(entranceDelay: 0);
    final ticket = _entryTicket;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_entryCurrent(ticket)) return;
      final position = Scrollable.maybeOf(context)?.position;
      if (position != null &&
          (position.isScrollingNotifier.value ||
              position.pixels > position.minScrollExtent + .5)) {
        _scrolledPositions[position] = true;
      }
      if (fromMount &&
          position != null &&
          (position.isScrollingNotifier.value ||
              (_scrolledPositions[position] == true &&
                  widget.pageAnimation?.status != AnimationStatus.forward))) {
        // Lazy rows created by dragging, a wheel or jumpTo are not a page
        // entrance. Existing visible rows still greet when their tab returns.
        setState(_settle);
        return;
      }
      final bounds = _visibleBounds();
      if (bounds == null) {
        setState(() {
          _settle();
          _entryAfterTransition =
              widget.pageAnimation?.status == AnimationStatus.forward;
        });
        return;
      }
      _ArchiveIconEntranceBatch.add(this, bounds, ticket);
    });
  }

  void _gestureStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _finishVisibleGesture = false;
    if (status != AnimationStatus.completed || !_ambientAllowed) return;
    _ambientTimer?.cancel();
    // No frame is scheduled during the pause. Hidden tabs, covered routes and
    // background apps cancel this timer rather than keeping an idle ticker.
    _ambientTimer = Timer(_ambientRest, () {
      _ambientTimer = null;
      if (mounted && _ambientAllowed && _visibleBounds() != null) {
        setState(_replay);
      }
    });
  }

  void _replay({int? entranceDelay}) {
    ++_entryTicket;
    _ambientTimer?.cancel();
    _ambientTimer = null;
    _origin = _sampleGesture(
      _gesturePhase(_gesture.value, _gestureStart, _gestureSpan),
      _origin,
    );
    _gestureStart = entranceDelay == null ? 0 : entranceDelay / 880;
    _gestureSpan = entranceDelay == null ? 1 : 520 / 880;
    _gesture.duration = entranceDelay == null
        ? ArchiveIconMotion.duration
        : const Duration(milliseconds: 880);
    _gesture.forward(from: 0);
  }

  void _settle() {
    ++_entryTicket;
    _finishVisibleGesture = false;
    _entryAfterTransition = false;
    _change.value = 1;
    _contact.value = 0;
    _gesture.value = 1;
    _gestureStart = 0;
    _gestureSpan = 1;
    _origin = ArchiveIconGesture.rest;
    _ambientTimer?.cancel();
    _ambientTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (!mounted || _foreground == foreground) return;
    setState(() {
      _foreground = foreground;
      if (_still) {
        _settle();
      } else {
        _queueEntrance();
      }
    });
  }

  @override
  void didUpdateWidget(_ArchiveGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    final accepted = oldWidget.trigger != widget.trigger;
    final coveredNow = oldWidget.visible && !widget.visible;
    // A transparent menu can cover the route in the same frame as its accepted
    // tap. Finish that finite response instead of cancelling its first frame.
    // Opaque/offstage routes still disable TickerMode, and covered controls
    // never start idle, entry or unrelated state-change animations.
    _finishVisibleGesture =
        !widget.still &&
        !widget.visible &&
        (_finishVisibleGesture ||
            (coveredNow && (_gesture.isAnimating || accepted)));
    final wasStill = oldWidget.still || !_foreground;
    if (oldWidget.pageAnimation != widget.pageAnimation) {
      oldWidget.pageAnimation?.removeStatusListener(_pageChanged);
      _listenToPage(widget.pageAnimation);
    }
    final next = _IconPose.of(widget.symbol, widget.active);
    final changed =
        oldWidget.symbol != widget.symbol || oldWidget.active != widget.active;
    if (oldWidget.symbol != widget.symbol ||
        oldWidget.active != widget.active) {
      _from = _IconPose.lerp(
        _from,
        _to,
        ArchiveIconMotion.stateCurve.transform(_change.value),
      );
      _to = next;
      if (_still || !widget.visible) {
        _change.value = 1;
      } else {
        _change.forward(from: 0);
      }
    }
    if (_still) {
      _settle();
    } else if (oldWidget.pressed != widget.pressed) {
      widget.pressed ? _contact.forward() : _contact.reverse();
    }
    if (!_still &&
        ((widget.visible && (changed || accepted)) ||
            (coveredNow && accepted))) {
      _replay();
    } else if (!_still &&
        ((!oldWidget.visible && widget.visible) ||
            wasStill ||
            (_ambientAllowed && !oldWidget.ambient))) {
      _queueEntrance();
    }
    if (!widget.ambient || !widget.visible) {
      _ambientTimer?.cancel();
      _ambientTimer = null;
    }
  }

  @override
  void dispose() {
    _ambientTimer?.cancel();
    widget.pageAnimation?.removeStatusListener(_pageChanged);
    WidgetsBinding.instance.removeObserver(this);
    _gesture.removeStatusListener(_gestureStatus);
    _change.dispose();
    _contact.dispose();
    _gesture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final painting = CustomPaint(
      size: Size.square(widget.size),
      painter: _ArchiveGlyphPainter(
        from: _from,
        to: _to,
        change: _change,
        contact: _contact,
        gesture: _gesture,
        gestureStart: _gestureStart,
        gestureSpan: _gestureSpan,
        origin: _origin,
        repaint: _paint,
        color: widget.color,
        contrast: widget.contrast,
        mirrored: widget.mirrored,
        blendMode: widget.blendMode,
      ),
    );
    // Only the moving vector gets a layer, at its optical icon size. Without
    // this boundary each tick also repaints the unchanged label and surrounding
    // control surface. Static/reduced-motion icons do not need the extra layer.
    return widget.still ? painting : RepaintBoundary(child: painting);
  }
}

class _IconPose {
  const _IconPose(this.symbol, this.variant, this.active);
  final ArchiveSymbol symbol;
  final double variant, active;

  factory _IconPose.of(ArchiveSymbol symbol, bool active) {
    final (family, variant) = switch (symbol) {
      ArchiveSymbol.pause => (ArchiveSymbol.play, 1.0),
      ArchiveSymbol.back => (ArchiveSymbol.forward, math.pi),
      ArchiveSymbol.up => (ArchiveSymbol.forward, -math.pi / 2),
      ArchiveSymbol.down => (ArchiveSymbol.forward, math.pi / 2),
      ArchiveSymbol.arrowLeft => (ArchiveSymbol.arrowRight, math.pi),
      ArchiveSymbol.arrowUp => (ArchiveSymbol.arrowRight, -math.pi / 2),
      ArchiveSymbol.arrowDown => (ArchiveSymbol.arrowRight, math.pi / 2),
      ArchiveSymbol.external => (ArchiveSymbol.arrowRight, -math.pi / 4),
      ArchiveSymbol.bookmarked => (ArchiveSymbol.bookmark, 1.0),
      ArchiveSymbol.eyeOff => (ArchiveSymbol.eye, 1.0),
      ArchiveSymbol.checkCircle => (ArchiveSymbol.circle, 1.0),
      ArchiveSymbol.selected => (ArchiveSymbol.circle, 2.0),
      ArchiveSymbol.locationFilled => (ArchiveSymbol.location, 1.0),
      _ => (symbol, 0.0),
    };
    return _IconPose(family, variant, active ? 1 : 0);
  }

  static _IconPose lerp(_IconPose a, _IconPose b, double t) => _IconPose(
    t < .5 && a.symbol != b.symbol ? a.symbol : b.symbol,
    a.symbol == b.symbol ? a.variant + (b.variant - a.variant) * t : b.variant,
    a.active + (b.active - a.active) * t,
  );
}

class _ArchiveGlyphPainter extends CustomPainter {
  _ArchiveGlyphPainter({
    required this.from,
    required this.to,
    required this.change,
    required this.contact,
    required this.gesture,
    required this.gestureStart,
    required this.gestureSpan,
    required this.origin,
    required Listenable repaint,
    required this.color,
    required this.contrast,
    required this.mirrored,
    required this.blendMode,
  }) : super(repaint: repaint);
  final _IconPose from, to;
  final Animation<double> change, contact, gesture;
  final double gestureStart, gestureSpan;
  final ArchiveIconGesture origin;
  final Color color;
  final bool contrast, mirrored;
  final BlendMode blendMode;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    if (mirrored) {
      canvas.translate(24, 0);
      canvas.scale(-1, 1);
    }
    final t = ArchiveIconMotion.stateCurve.transform(change.value);
    final press = Curves.easeOutCubic.transform(contact.value) * .16;
    final motion = _sampleGesture(
      _gesturePhase(gesture.value, gestureStart, gestureSpan),
      origin,
    ).plus(ArchiveIconGesture(press, press, press), 1);
    final width = contrast
        ? 2.05
        : size.shortestSide < 18
        ? 1.9
        : 1.72;
    void draw(_IconPose pose, double opacity) {
      if (opacity <= 0) return;
      final drawing = ArchiveIconArt._build(pose, gesture: motion);
      for (final stroke in drawing.strokes) {
        final paint = Paint()
          ..isAntiAlias = true
          ..style = stroke.fill ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = width * stroke.width
          ..blendMode = blendMode
          ..color = color.withValues(
            alpha: color.a * opacity.clamp(0, 1) * stroke.opacity,
          );
        canvas.drawPath(stroke.path, paint);
      }
    }

    if (from.symbol == to.symbol || t == 1) {
      draw(_IconPose.lerp(from, to, t), 1);
    } else {
      draw(from, 1 - t);
      draw(to, t);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArchiveGlyphPainter oldDelegate) =>
      from != oldDelegate.from ||
      to != oldDelegate.to ||
      origin != oldDelegate.origin ||
      gestureStart != oldDelegate.gestureStart ||
      gestureSpan != oldDelegate.gestureSpan ||
      color != oldDelegate.color ||
      contrast != oldDelegate.contrast ||
      mirrored != oldDelegate.mirrored ||
      blendMode != oldDelegate.blendMode;
}

double _gesturePhase(double value, double start, double span) =>
    ((value - start) / span).clamp(0, 1);

ArchiveIconGesture _sampleGesture(double t, ArchiveIconGesture origin) {
  final carry = 1 - Curves.easeOutCubic.transform((t / .24).clamp(0, 1));
  return ArchiveIconMotion.frame(t).plus(origin, carry);
}
