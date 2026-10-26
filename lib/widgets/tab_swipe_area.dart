import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 横向手势切顶栏标签的外壳：首页书城分类、短剧频道、书架一级 tab 共用。
///
/// **为什么不是横向 `PageView`。** 三页的「标签」都不是独立页面：
/// * 首页六个分类共用一个 feed，切分类要换 `tabIndex`、换 cells、重新请求，
///   分页游标和滚动位置都在 provider 里；
/// * 短剧的频道决定整页形态（竖滑播放流 / 瀑布格 / 本地列表），换频道还要
///   释放内联播放器、换壳层 dock 配色；
/// * 书架的三个 tab 共享编辑态与选中集合，切 tab 要一并复位。
/// 按 tab 把三页拆成 `PageView` 的 children 等于把三份数据流重写一遍。所以这里
/// 只做「手势 + 位移」：拖动时内容跟手横移，松手后把当前内容按方向送出、
/// 调 [onSelect] 换标签、再把新内容从另一侧迎进来。
///
/// **与既有手势的关系。** 本组件是页面内容的祖先，横向拖动与内部 `Scrollable`
/// 在同一个手势竞技场里按方向裁决：竖直滑动归滚动组件（下拉刷新、短剧竖滑
/// 翻页、书架网格滚动都不受影响），只有横向分量先越过 `kTouchSlop` 才归这里。
/// 内容区本来就有横向滚动列表时（首页顶栏条、卡片横排、短剧频道条），那些
/// 列表会先赢——在它们身上左右滑是滚列表，这样才对。
///
/// **谁能抢走横滑：** 只有比本组件更内层、且自己注册了横向拖动的手势能赢
/// （竞技场里事件从内层往外发，内层先收到、先越过 slop 就先 accept）。短剧
/// 竖滑播放流就是靠这条规则，把「调进度」收在底部进度条那一条里：进度条
/// 自己带横向拖动，所以只有它那 24dp 归它，card 上的其余部分一概归这里切
/// 频道。不需要按坐标做互斥——两边的**作用范围本来就是靠命中测试分开的**。
///
/// **边界。** 首尾不环绕：越界方向只给一段阻尼位移（[edgeDamping] /
/// [edgeLimit]），松手弹回原位，且切换请求在 [_stepFor] 里就被挡掉，不会
/// 出现「从最后一个跳回第一个」。
class TabSwipeArea extends StatefulWidget {
  const TabSwipeArea({
    super.key,
    required this.index,
    required this.count,
    required this.onSelect,
    required this.child,
    this.enabled = true,
  });

  /// 当前标签下标，由页面自己的状态驱动（页面是唯一事实来源）。
  final int index;

  /// 标签总数，用来判定首尾边界。小于 2 时手势整体不启用。
  final int count;

  /// 换到相邻标签。父级在这个回调里做请求、落盘、复位编辑态等任何事。
  ///
  /// 允许不认账（越界、数据未就绪）：调用后 [index] 没变，组件会把内容滑回
  /// 原位，不会停在半屏空白上。
  final ValueChanged<int> onSelect;

  final Widget child;

  /// 门禁。编辑态、全屏播放器打开、弹窗等场景由页面关掉手势。
  final bool enabled;

  /// 位移超过屏宽的这个比例就认这次切换（不甩也能滑过去）。
  static const double commitFraction = 0.18;

  /// 位移不到阈值时，速度超过这个值（逻辑像素/秒）也算切换。
  static const double commitVelocity = 220;

  /// 跟手阶段：屏宽的 [followFraction] 之内 1:1 跟随手指。
  static const double followFraction = 0.28;

  /// 越过 [followFraction] 后按这个系数收缩，总量封顶在 [maxFollowFraction]：
  /// 再往后拖也留得住画面，不会把内容整块拖出画布只剩底色。
  static const double followDamping = 0.35;
  static const double maxFollowFraction = 0.42;

  /// 越界阻尼：位移按这个系数收缩，并封顶 [edgeLimit] 像素。
  static const double edgeDamping = 0.3;
  static const double edgeLimit = 48;

  /// 出场 / 入场的位移比例。两者同宽，视觉上就是一个屏宽的接续。
  static const double exitFraction = 0.34;
  static const double enterFraction = 0.34;

  /// 出场、弹回、入场的时长（毫秒）。入场比出场略长，收尾更软。
  static const int exitMs = 110;
  static const int settleMs = 170;
  static const int enterMs = 190;

  @override
  State<TabSwipeArea> createState() => _TabSwipeAreaState();
}

class _TabSwipeAreaState extends State<TabSwipeArea>
    with SingleTickerProviderStateMixin {
  /// 当前横向位移。只驱动一个 [Transform]，不碰页面状态：拖动期间整页子树
  /// 一次都不重建（首页那份 sliver 缓存尤其经不起每帧重建）。
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  late final AnimationController _anim = AnimationController(vsync: this);

  /// 曲线只建一次。
  ///
  /// `CurvedAnimation` 构造时给 parent 挂一个 status listener，只有 `dispose()`
  /// 会摘掉；每次补间都 new 一个会让 [_anim] 的监听器只增不减。首页是根 tab、
  /// 永不销毁，滑几十次就积成几千个，之后每次 forward/stop 都要走完一遍。
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
  );

  Animation<double>? _tween;

  /// 起手时量一次屏宽，动画期间不再读 `context.size`（那时可能已经不在树上）。
  ///
  /// 平时由 [build] 里的 `LayoutBuilder` 缓存到这里；`didUpdateWidget` 阶段
  /// render object 还没重新布局，读 `context.size` 会抛
  /// `Cannot get size during build`（release 下不抛，只是静默拿上一帧的值），
  /// 所以点标签那条路径只能用上一帧的宽度。窗口 resize 时相差一帧，入场位移
  /// 看不出来。
  double _width = 1;

  /// 跟手累计位移（未阻尼），与 [_offset] 分开：从 [_offset] 反推阻尼前的值
  /// 会在越界与封顶两处失真。
  double _drag = 0;

  bool _dragging = false;

  /// 切换链（送出 → 换标签 → 迎入）进行中。期间的新手势一律丢弃。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _anim.addListener(_applyTween);
  }

  @override
  void didUpdateWidget(TabSwipeArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index) return;
    // 手势发起的切换由 [_commit] 自己接管动画，这里不插手。
    if (_busy || _dragging) return;
    // 点标签切过来的：也让新内容从对应一侧迎进来，与手势切换同一种观感。
    // 位移同步设好（免得新内容先归位再跳出去），动画放到这一帧之后启动。
    final direction = widget.index > oldWidget.index ? 1 : -1;
    // 这里不能量宽：[didUpdateWidget] 跑在 build 阶段，这一帧的 layout 还没
    // 发生，`context.size` 会直接抛异常。沿用 [_width]（上一帧由 build 里的
    // LayoutBuilder 记下的内容宽度）。
    // 先停旧补间，否则它在下一帧还会继续写 _offset，把刚设好的入场位移抹掉。
    _anim.stop();
    _offset.value = direction * _width * TabSwipeArea.enterFraction;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_to(0, TabSwipeArea.enterMs, Curves.easeOutCubic));
    });
  }

  @override
  void dispose() {
    // 先摘监听器，再销毁它监听的 controller。
    _curve.dispose();
    _anim.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _applyTween() {
    final tween = _tween;
    if (tween != null) _offset.value = tween.value;
  }

  double _measureWidth() {
    final size = context.size;
    if (size != null && size.width > 0) return size.width;
    return MediaQuery.sizeOf(context).width;
  }

  int _ms(int milliseconds) =>
      MediaQuery.disableAnimationsOf(context) ? 0 : milliseconds;

  void _onDragStart(DragStartDetails details) {
    if (_busy || !widget.enabled || widget.count < 2) return;
    _dragging = true;
    _width = _measureWidth();
    // 从当前位置接管：入场动画还没走完时抓手，不该先跳回 0。
    _anim.stop();
    _drag = _offset.value;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _drag += details.delta.dx;
    _offset.value = _follow(_drag);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final step = _stepFor(_offset.value, details.velocity.pixelsPerSecond.dx);
    if (step == 0) {
      unawaited(_to(0, TabSwipeArea.settleMs, Curves.easeOutCubic));
      return;
    }
    unawaited(_commit(step));
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    unawaited(_to(0, TabSwipeArea.settleMs, Curves.easeOutCubic));
  }

  /// 原始位移 → 实际位移：跟手、封顶、越界阻尼。
  double _follow(double dx) {
    final blocked =
        (widget.index == 0 && dx > 0) ||
        (widget.index == widget.count - 1 && dx < 0);
    if (blocked) {
      final damped = dx * TabSwipeArea.edgeDamping;
      // clamp 返回 num，方法签名要 double。
      return damped
          .clamp(-TabSwipeArea.edgeLimit, TabSwipeArea.edgeLimit)
          .toDouble();
    }
    final direct = _width * TabSwipeArea.followFraction;
    final magnitude = dx.abs();
    if (magnitude <= direct) return dx;
    final total = math.min(
      direct + (magnitude - direct) * TabSwipeArea.followDamping,
      _width * TabSwipeArea.maxFollowFraction,
    );
    return dx.isNegative ? -total : total;
  }

  /// 松手后的方向判定。返回 `1` 表示去下一个标签、`-1` 表示上一个、`0` 表示
  /// 不换（没到阈值，或已经在首尾）。
  int _stepFor(double dx, double velocity) {
    if (widget.count < 2) return 0;
    final flung = velocity.abs() >= TabSwipeArea.commitVelocity;
    final dragged = dx.abs() >= _width * TabSwipeArea.commitFraction;
    if (!flung && !dragged) return 0;
    // 只靠速度时听速度的；其余情况听位移的（甩回来时位移才是真意图）。
    final rightward = flung && !dragged ? velocity > 0 : dx > 0;
    final target = widget.index + (rightward ? -1 : 1);
    if (target < 0 || target >= widget.count) return 0;
    return rightward ? -1 : 1;
  }

  /// 送出 → 换标签 → 迎入。三段之间只隔一个「换标签」的同步回调。
  Future<void> _commit(int step) async {
    _busy = true;
    final width = _width;
    try {
      // 1) 起势：把当前内容按方向送出去，切换才「看得见」。
      await _to(
        -step * width * TabSwipeArea.exitFraction,
        TabSwipeArea.exitMs,
        Curves.easeOutCubic,
      );
      if (!mounted) return;
      // 2) 立刻换标签：父级的请求/落盘从这一刻开始，动画不占它的时间。
      final previous = widget.index;
      widget.onSelect(previous + step);
      // 3) 等这一帧把新内容挂上，再把它从另一侧迎进来。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (widget.index == previous) {
        // 父级没认这次切换：滑回原位，不留半屏空白。
        await _to(0, TabSwipeArea.settleMs, Curves.easeOutCubic);
      } else {
        _offset.value = step * width * TabSwipeArea.enterFraction;
        await _to(0, TabSwipeArea.enterMs, Curves.easeOutCubic);
      }
    } finally {
      _busy = false;
    }
  }

  /// 把位移补间到 [target]。中途被新的补间打断时静默收场（接管方接着走）。
  ///
  /// [milliseconds] 走 [_ms]：系统关掉动画时直接落位，不排空补间。
  Future<void> _to(double target, int milliseconds, Curve curve) async {
    if (!mounted) return;
    final from = _offset.value;
    final duration = _ms(milliseconds);
    if (duration <= 0 || from == target) {
      _offset.value = target;
      return;
    }
    _anim.duration = Duration(milliseconds: duration);
    _curve.curve = curve;
    _tween = Tween<double>(begin: from, end: target).animate(_curve);
    try {
      await _anim.forward(from: 0);
    } catch (_) {
      // TickerFuture 只有两种收场：跑完，或者被下一个补间 / 页面销毁打断
      // （TickerCanceled）。第二种没有要收尾的东西，接着让调用方判断。
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && widget.count > 1;
    // 用 LayoutBuilder 记宽度，而不是每次切换时读 context.size：这里的
    // constraints 在 layout 阶段就确定了，didUpdateWidget（build 阶段）也能
    // 沿用上一次的值。只写字段不 setState，不会多出一次重建。
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width.isFinite && width > 0) _width = width;
        return RawGestureDetector(
          // translucent：内容没接住指针的地方（卡片间隙、留白）也要能起手。
          // 默认的 deferToChild 要求子节点命中，空白处整片滑不动。
          // 不加 opaque：内容自己的手势仍然先收到事件、先在竞技场里赢。
          behavior: HitTestBehavior.translucent,
          gestures: enabled
              ? <Type, GestureRecognizerFactory>{
                  HorizontalDragGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        HorizontalDragGestureRecognizer
                      >(
                        HorizontalDragGestureRecognizer.new,
                        (recognizer) => recognizer
                          // 从按下点算起。默认的 start 行为会吃掉前
                          // kTouchSlop 像素，跟手会晚半拍（阅读页竖滑踩过
                          // 同一个坑）。
                          ..dragStartBehavior = DragStartBehavior.down
                          ..onStart = _onDragStart
                          ..onUpdate = _onDragUpdate
                          ..onEnd = _onDragEnd
                          ..onCancel = _onDragCancel,
                      ),
                }
              : const <Type, GestureRecognizerFactory>{},
          child: ValueListenableBuilder<double>(
            valueListenable: _offset,
            // child 传进来就不再随位移重建，只有那层 Transform 会重建。
            child: widget.child,
            builder: (context, offset, child) => Transform.translate(
              offset: Offset(offset, 0),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
