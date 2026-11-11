// Restored from fqapp-backup@f329399 (issue #288), RootShell bottom navigation.
// Only presentation is copied; selection and the retained tabs stay in RootShell.
import 'dart:math' show cos, exp, sin, sqrt;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/app_theme.dart';
import 'home/home_design.dart';

class ClassicShellDock extends StatefulWidget {
  const ClassicShellDock({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.overVideo,
    this.animating = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 短剧 tab 背后是全屏视频流：dock 按深色外观绘制并跳过实时模糊。
  final bool overVideo;

  /// 页面切换动画进行中：跳过 BackdropFilter 实时模糊，避免每帧
  /// 对滑动中的页面做全屏高斯模糊（动画结束后自动恢复）。
  final bool animating;

  @override
  State<ClassicShellDock> createState() => _ClassicShellDockState();
}

class _ClassicShellDockState extends State<ClassicShellDock> {
  /// 同心圆角规则：dock 外轮廓是 [_dockHeight] 高的全胶囊（圆角 = 高/2），
  /// 选中背景从 dock 内壁四周内缩 [_innerInset]，圆角取 `外圆角 − 内缩间距`
  /// （内层背景高 64 − 8 = 56 = 2 × 28，同样是全胶囊），两层圆弧圆心同在
  /// dock 中线上、四周间距均匀，观感是外轮廓正好比高亮背景大一圈。
  static const _dockHeight = 64.0;
  static const _dockRadius = _dockHeight / 2;
  static const _innerInset = 4.0;
  static const _innerRadius = _dockRadius - _innerInset;

  /// 甩动判定阈值（px/s）：松手速度超过它时，即使位移没过项中心也
  /// 沿甩动方向至少前进一格（对齐 PageView 的 pageSnapping 语义）。
  static const _flingVelocity = 600.0;

  /// 欠阻尼弹簧（damped harmonic oscillator，闭式解驱动）：ζ < 1 时
  /// 高亮冲过目标再振荡归位，松手回弹有真实的“橡皮筋”手感，取代旧的
  /// 单调指数逼近（无过冲、观感过于简单）。每帧按实际帧间隔 dt 推进
  /// 解析解，任何刷新率下轨迹一致；dt 封顶使长阻塞（掉帧）时动画暂停
  /// 在当前位置、恢复后续滑，绝不按累计时间跳到终点。ω₀ = 22 rad/s →
  /// 振荡周期 ≈ 285ms，主收敛段与页面 260ms easeOutCubic 协调。
  static const _springOmega = 22.0; // 自然频率（rad/s）

  /// 拖动松手（回弹 / 甩动交接 / 指针取消）：低阻尼，过冲 ≈ 16%，
  /// 回弹明显、有弹性。
  static const _dragZeta = 0.5;

  /// 点击 / 页面侧切换：较高阻尼，过冲 ≈ 4%，灵动但不抢页面滑动的戏。
  static const _switchZeta = 0.72;

  /// 单步 dt 上限（秒）：帧间隔超过它时按它推进，长掉帧等效暂停。
  static const _maxSpringStep = 1 / 30;

  /// 单项理想宽度与 dock 总宽上限：手机上内容区自然宽度就是
  /// 4 × 90 + 8 = 368；平板 / 桌面封顶后居中，不再整行拉伸（对齐
  /// GlassDock 的固定宽度策略）。窄屏自适应收缩。
  static const _itemIdealWidth = 90.0;
  static const _dockMaxWidth = _itemIdealWidth * 4 + _innerInset * 2;

  static const _items = [
    (LucideIcons.house, '首页'),
    (LucideIcons.clapperboard, '短剧'),
    (LucideIcons.library_big, '书架'),
    (LucideIcons.circle_user_round, '我的'),
  ];

  /// 背景块的连续项序号（欠阻尼弹簧驱动，松手回弹带过冲）。
  final ValueNotifier<double> _selection = ValueNotifier(0);

  /// 弹簧 Ticker：每帧触发 [_onSpringTick]，用 delta-time 推进，
  /// 任何刷新率下收敛时间一致。直接创建（不经
  /// SingleTickerProviderStateMixin），不受 TickerMode 静音管控：
  /// dock 始终可见，动画不应被页面侧的 TickerMode 切换冻住。
  late final Ticker _springTicker;
  double _springTarget = 0;
  double _springVelocity = 0; // 项/秒
  double _springZeta = _switchZeta; // 当前阻尼比（拖动 / 切换两档）
  bool _springActive = false;

  /// 上一帧回调的累计时长。Ticker 传入的是自 start() 起的累计时间而非
  /// 帧间隔，须差分得到真实 dt；每次重启弹簧（[_settleTo]）时清零。
  Duration _lastElapsed = Duration.zero;

  /// 拖动松手后的归位速度（项/秒）。弹簧不在松手时启动：先定格在跟手
  /// 位置，等 selectedIndex 回流（didUpdateWidget）时与页面滑动同帧
  /// 启动并交接速度，避免页面首次挂载阻塞时高亮冻在中途。
  double? _pendingVelocity;

  /// 拖动中相对选中项中心的像素偏移；null = 未在拖动。用 ValueNotifier
  /// 驱动背景层重绘，拖动不触发整条 dock rebuild。
  final ValueNotifier<double?> _dragDx = ValueNotifier(null);
  double _contentWidth = 0;

  double get _itemWidth => _contentWidth / _items.length;

  /// 背景块当前应处的连续项序号：拖动中跟手；弹簧活跃 / 松手定格时取
  /// [_selection].value；已落位时取精确整数（避免像素级断言失败）。
  double _continuousSelection() {
    final drag = _dragDx.value;
    if (drag != null) {
      return widget.selectedIndex + drag / _itemWidth;
    }
    if (_springActive || _pendingVelocity != null) {
      return _selection.value;
    }
    return widget.selectedIndex.toDouble();
  }

  /// 弹簧每帧回调：欠阻尼谐振子闭式解按实际帧间隔 dt 推进。
  /// x(t) = e^(−ζω₀·t)·(A·cos ωd·t + B·sin ωd·t)，A = x₀，
  /// B = (v₀ + ζω₀·x₀)/ωd；对任意 dt 精确成立，刷新率无关，
  /// 掉帧（dt 封顶）时暂停在当前位置、恢复后平滑续滑。
  void _onSpringTick(Duration elapsed) {
    var dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    if (dt > _maxSpringStep) dt = _maxSpringStep;
    final x = _selection.value - _springTarget;
    final v = _springVelocity;
    if (x.abs() < 0.002 && v.abs() < 0.002) {
      _selection.value = _springTarget;
      _springActive = false;
      _springTicker.stop();
      return;
    }
    final sigma = _springZeta * _springOmega;
    final wd = _springOmega * sqrt(1 - _springZeta * _springZeta);
    final decay = exp(-sigma * dt);
    final cosD = cos(wd * dt);
    final sinD = sin(wd * dt);
    final b = (v + sigma * x) / wd;
    _selection.value = _springTarget + decay * (x * cosD + b * sinD);
    _springVelocity =
        decay * ((wd * b - sigma * x) * cosD - (wd * x + sigma * b) * sinD);
  }

  /// 从 [from]（可带初速 [velocity]，单位：项/秒）弹簧滑到 [to]；
  /// [zeta] 选阻尼比（拖动回弹用 [_dragZeta]，点击切换用 [_switchZeta]）。
  /// eink / 系统减弱动态效果不做动画，直接定位。
  void _settleTo(
    double from,
    double to,
    double velocity, {
    double zeta = _switchZeta,
  }) {
    // Ticker.start() 不能作用于活跃 Ticker（debug 下抛 "started twice"）：
    // 先 stop 复位内部 _startTime 再重启，同时清零 dt 差分基准。
    _springTicker.stop();
    _lastElapsed = Duration.zero;
    // eink 与系统「减弱动态效果」同走无动画分支：直接落位，与全库
    // 动画按 disableAnimations 降级的约定一致。
    if (einkModeNotifier.value || MediaQuery.disableAnimationsOf(context)) {
      _springActive = false;
      _selection.value = to;
      return;
    }
    _selection.value = from;
    _springTarget = to;
    _springVelocity = velocity; // 项/秒
    _springZeta = zeta;
    _springActive = true;
    _springTicker.start();
  }

  void _handleTap(int index) {
    // tap 只转发选择：背景保持在当前位置，弹簧由 selectedIndex 回流
    // （didUpdateWidget）驱动。RootShell 会先把首次访问的目标页挂载完，
    // 再让背景与 PageView 同帧启动滑动——页面构建不会冻住滑动中的
    // 高亮。重复点当前 tab 的回顶也由页面侧处理，这里原样转发。
    widget.onSelected(index);
  }

  void _handleDragStart(DragStartDetails details) {
    // 弹簧滑动中途被抓住：以当前连续位置为拖动种子，避免高亮瞬移回
    // 选中项中心再跟手。
    final continuous = _continuousSelection();
    final min = -widget.selectedIndex * _itemWidth;
    final max = (_items.length - 1 - widget.selectedIndex) * _itemWidth;
    _springTicker.stop();
    _springActive = false;
    _pendingVelocity = null;
    _dragDx.value = ((continuous - widget.selectedIndex) * _itemWidth).clamp(
      min,
      max,
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final current = _dragDx.value;
    if (current == null) return;
    // 背景块不滑出内容区：连续序号 clamp 在 [0, n−1]。
    final min = -widget.selectedIndex * _itemWidth;
    final max = (_items.length - 1 - widget.selectedIndex) * _itemWidth;
    _dragDx.value = (current + details.delta.dx).clamp(min, max);
  }

  void _handleDragEnd(DragEndDetails details) {
    final dx = _dragDx.value;
    if (dx == null) return;
    _dragDx.value = null;
    final velocity = details.velocity.pixelsPerSecond.dx;
    // 目标 = 拖动停下的连续位置就近取整：拖过几项就落几项（跨页拖动）。
    final continuous = widget.selectedIndex + dx / _itemWidth;
    var target = continuous.round();
    // 甩动：位移没过项中心时，沿甩动方向至少前进一格。
    if (target == widget.selectedIndex && velocity.abs() >= _flingVelocity) {
      target += velocity > 0 ? 1 : -1;
    }
    target = target.clamp(0, _items.length - 1);
    if (target != widget.selectedIndex) {
      // 切页：定格在松手的连续位置，速度留给 selectedIndex 回流时的
      // 弹簧（didUpdateWidget），与页面滑动过渡同帧启动。
      _selection.value = continuous;
      _pendingVelocity = velocity / _itemWidth;
      widget.onSelected(target);
    } else {
      // 回弹 / 原地：没有页面切换与挂载开销，立即自己收尾（带松手
      // 速度，低阻尼橡皮筋回弹）。
      _settleTo(
        continuous,
        target.toDouble(),
        velocity / _itemWidth,
        zeta: _dragZeta,
      );
    }
  }

  void _handleDragCancel() {
    final dx = _dragDx.value;
    if (dx == null) return;
    // 指针被系统取消（来电、系统手势打断等）：复位拖动并弹回当前选中项，
    // 避免高亮永久停在偏移位置、且后续 didUpdateWidget 被拖动守卫跳过。
    final continuous = widget.selectedIndex + dx / _itemWidth;
    _dragDx.value = null;
    _settleTo(continuous, widget.selectedIndex.toDouble(), 0, zeta: _dragZeta);
  }

  @override
  void initState() {
    super.initState();
    _selection.value = widget.selectedIndex.toDouble();
    _springTicker = Ticker(_onSpringTick);
  }

  @override
  void didUpdateWidget(ClassicShellDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex &&
        _dragDx.value == null) {
      // 页面侧回流：从当前显示位置弹簧滑向新选中项，与页面的
      // 滑动过渡同帧启动；拖动松手把速度交接给这次弹簧，并沿用
      // 拖动的低阻尼（交接后的落位同样带弹性），点击切换用高阻尼。
      final fromDrag = _pendingVelocity != null;
      final velocity = _pendingVelocity ?? 0;
      _pendingVelocity = null;
      _settleTo(
        _selection.value,
        widget.selectedIndex.toDouble(),
        velocity,
        zeta: fromDrag ? _dragZeta : _switchZeta,
      );
    }
  }

  @override
  void dispose() {
    _springTicker.dispose();
    _selection.dispose();
    _dragDx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final glassDark = palette.dark || widget.overVideo;
    final eink = einkModeNotifier.value;
    final oled = oledActive();
    final surfaceColor = eink
        ? Colors.white
        : oled
        ? const Color(0xFF0C0C0E)
        : glassDark
        ? const Color(0xFF161619).withValues(alpha: .72)
        : Colors.white.withValues(alpha: .82);
    final borderColor = eink
        ? Colors.black
        : glassDark
        ? Colors.white.withValues(alpha: .16)
        : Colors.white.withValues(alpha: .75);
    final indicatorColor = eink
        ? Colors.black
        : HomePalette.accent.withValues(alpha: glassDark ? .20 : .12);
    final borderRadius = BorderRadius.circular(_dockRadius);
    final navBar = SizedBox(
      key: const ValueKey('classic-navigation-bar'),
      height: _dockHeight,
      child: Padding(
        padding: const EdgeInsets.all(_innerInset),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _contentWidth = constraints.maxWidth;
            final itemWidth = _itemWidth;
            return Stack(
              children: [
                // 全局唯一的浮动高亮块：拖动时 ValueNotifier 逐帧驱动位移，
                // 松手 / 切换时走欠阻尼弹簧滑动归位或到位（带过冲回弹）。
                AnimatedBuilder(
                  animation: Listenable.merge([_selection, _dragDx]),
                  builder: (context, _) {
                    final continuous = _continuousSelection().clamp(
                      0.0,
                      (_items.length - 1).toDouble(),
                    );
                    final center = (continuous + 0.5) * itemWidth;
                    return Positioned(
                      left: center - itemWidth / 2,
                      width: itemWidth,
                      top: 0,
                      bottom: 0,
                      child: RepaintBoundary(
                        child: DecoratedBox(
                          key: const ValueKey('classic-dock-selection'),
                          decoration: BoxDecoration(
                            color: indicatorColor,
                            borderRadius: BorderRadius.circular(_innerRadius),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Row(
                  children: [
                    for (final (index, item) in _items.indexed)
                      Expanded(
                        child: _ClassicDockDestination(
                          icon: item.$1,
                          label: item.$2,
                          selected: index == widget.selectedIndex,
                          onTap: () => _handleTap(index),
                          onHorizontalDragStart: _handleDragStart,
                          onHorizontalDragUpdate: _handleDragUpdate,
                          onHorizontalDragEnd: _handleDragEnd,
                          onHorizontalDragCancel: _handleDragCancel,
                          palette: palette,
                          glassDark: glassDark,
                          eink: eink,
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
    // 描边画在 foregroundDecoration 而不是 border：border 会把内层内容挤压
    // 0.8px，破坏 [_innerInset] 的同心间距；foreground 层不参与布局。
    final bar = Container(
      key: const ValueKey('classic-dock-surface'),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: borderRadius,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(color: borderColor, width: .8),
      ),
      child: navBar,
    );
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Center(
          // 槽位高度约束有界（Scaffold 底栏给的是 0..屏幕高）：裸 Center 会
          // 撑满高度把 dock 顶到屏幕中央；heightFactor 限定只包住 dock 高度，
          // 水平仍撑满以便封顶后在宽屏上居中。
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _dockMaxWidth),
            child: RepaintBoundary(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  boxShadow: eink
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: glassDark ? .38 : .08,
                            ),
                            blurRadius: 22,
                            offset: const Offset(0, 8),
                          ),
                          BoxShadow(
                            color: HomePalette.accent.withValues(
                              alpha: glassDark ? .06 : .03,
                            ),
                            blurRadius: 14,
                            offset: const Offset(0, 2),
                          ),
                        ],
                ),
                child: ClipRRect(
                  borderRadius: borderRadius,
                  child:
                      eink ||
                          widget.selectedIndex == 1 ||
                          oled ||
                          widget.animating
                      ? bar
                      : BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: bar,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 经典 dock 的单个入口：透明内容（图标 + 文字）承载点击与水平拖动手势；
/// 选中高亮由 dock 级的浮动背景块统一绘制（拖动跟手 / 滑动归位），圆角
/// 走 [_innerRadius] 与 dock 外轮廓同心。
class _ClassicDockDestination extends StatelessWidget {
  const _ClassicDockDestination({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onHorizontalDragStart,
    required this.onHorizontalDragUpdate,
    required this.onHorizontalDragEnd,
    required this.onHorizontalDragCancel,
    required this.palette,
    required this.glassDark,
    required this.eink,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final GestureDragStartCallback onHorizontalDragStart;
  final GestureDragUpdateCallback onHorizontalDragUpdate;
  final GestureDragEndCallback onHorizontalDragEnd;
  final GestureDragCancelCallback onHorizontalDragCancel;
  final HomePalette palette;
  final bool glassDark;
  final bool eink;

  @override
  Widget build(BuildContext context) {
    final unselectedColor = eink
        ? Colors.black
        : glassDark
        ? Colors.white.withValues(alpha: .65)
        : palette.muted;
    final iconColor = selected
        ? (eink ? Colors.white : HomePalette.accent)
        : unselectedColor;
    // 高亮背景包住文字：eink 黑底上的选中文字随图标一起反白；亮色 /
    // 玻璃暗色沿用原选中文字色。
    final labelColor = selected
        ? (eink
              ? Colors.white
              : glassDark
              ? HomePalette.accent
              : palette.accentText)
        : unselectedColor;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      // 无障碍激活动作：手势在子级 GestureDetector 上，不注册语义动作时
      // TalkBack 能读出「按钮/已选择」但双击无法激活，须显式补 onTap。
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // down：位移从按下点起算，背景跟手不丢 slop 内的起始位移。
        dragStartBehavior: DragStartBehavior.down,
        onTap: onTap,
        onHorizontalDragStart: onHorizontalDragStart,
        onHorizontalDragUpdate: onHorizontalDragUpdate,
        onHorizontalDragEnd: onHorizontalDragEnd,
        onHorizontalDragCancel: onHorizontalDragCancel,
        child: Center(
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: iconColor),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: labelColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
