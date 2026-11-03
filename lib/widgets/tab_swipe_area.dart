import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
    this.previewBuilder,
    this.isolateChild = true,
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

  /// 拖动时铺在「正在进来」那一侧的邻页；null 时那一侧露页面底色。
  ///
  /// 首页有六个分类，每个分类的内容都已经在 provider 里有一份（进过的分类
  /// 还能拿到上次渲染的 sliver 树），所以拖动时可以把邻页真正画出来，而不是
  /// 露出一块背景色。短剧/书架没有可预渲染的邻页，传 null 退回底色即可。
  ///
  /// 只会为「当前这次拖动」调用一次，不要在这里做重活。
  final Widget Function(int targetIndex)? previewBuilder;

  /// 是否给页面内容套一层重绘边界。
  ///
  /// 默认开：位移只是把录好的图挪个位置，跟手和迎入时整页绘制指令不必每帧
  /// 重放（短剧页是视频纹理 + 弹幕 + 一圈渐变）。
  ///
  /// 页面里有 [SwipeStationary]（首页把搜索行/分类条放在滚动视口里）时必须
  /// 关：边界的栅格只认自己的 bounds，反向位移会把顶栏推到边界之外，超出
  /// 部分直接不画，真机上就是一块黑面板压在顶栏上。
  final bool isolateChild;

  /// 位移超过屏宽的这个比例就认这次切换（不甩也能滑过去）。
  static const double commitFraction = 0.18;

  /// 位移不到阈值时，速度超过这个值（逻辑像素/秒）也算切换。
  static const double commitVelocity = 220;

  /// 跟手阶段：屏宽的 [followFraction] 之内 1:1 跟随手指。
  static const double followFraction = 0.28;

  /// 越往后拖越贴近、但永远到不了的位移上限（屏宽比例）。
  /// 留得住画面，也不会在某个宽度上「突然拖不动」。
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

  /// 本次手势是否处在「系统移除动画」下：那一整条链都不该有位移，包括跟手。
  /// 起手时读一次，避免每次 `DragUpdateDetails` 都去查 MediaQuery。
  bool _motionless = false;

  /// 切换链（送出 → 换标签 → 迎入）进行中。
  ///
  /// 锁只覆盖「标签还没换过来」的那段（起势 + 换标签）：标签一换就放开，迎入
  /// 期间允许下一次抓手（见 [_commit]）。否则一次切换要锁住约 300ms，快速连滑
  /// 会整次手势被丢掉。
  bool _busy = false;

  /// 第几次切换链。用于让被接管的那一次不要误放开后来者的 [_busy]。
  int _commitSeq = 0;

  /// 本次拖动建好的邻页预览，以及它属于哪个分类。
  ///
  /// 只在拖动/切换起势期间可见；一帧都不重建，松开后沿用同一张直到归位。
  Widget? _preview;
  int? _previewTarget;

  @override
  void initState() {
    super.initState();
    _anim.addListener(_applyTween);
  }

  @override
  void didUpdateWidget(TabSwipeArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      // 邻页已经变成当前页：预览和真正的内容不能同屏，入场动画也不需要它。
      _preview = null;
      _previewTarget = null;
    }
    if (widget.index == oldWidget.index) return;
    // 手势发起的切换由 [_commit] 自己接管动画，这里不插手。
    if (_busy || _dragging) return;
    // 系统关了动画：点标签就原地换内容。下面那次手工赋值会让新内容先画在
    // ±34% 屏宽处、帧后再落回 0，屏幕上是一次闪现——与 [_commit] 里已经堵掉
    // 的那一帧同源，必须同样加门。
    if (_ms(TabSwipeArea.enterMs) <= 0) return;
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
    // 新一次手势：上一张预览可能是旧数据/另一个方向，重建一次。
    _preview = null;
    _previewTarget = null;
    // 关了动画就没有跟手位移，但原始拖距照样要记：松手时用它判方向。
    _motionless = _ms(TabSwipeArea.enterMs) <= 0;
    // 从当前位置接管：入场动画还没走完时抓手，不该先跳回 0。
    _anim.stop();
    _drag = _offset.value;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _drag += details.delta.dx;
    _offset.value = _motionless ? 0 : _follow(_drag);
    // 预览在指针回调里构建：它会读渲染树的尺寸（邻页要对齐当前内容第一行），
    // 放到 build 里会踩 "Cannot get size during build"。
    _ensurePreview();
  }

  /// 方向确认（或反向）时构建一次邻页预览；同一方向内不重复构建。
  void _ensurePreview() {
    final builder = widget.previewBuilder;
    // `_motionless`（系统「移除动画」）下预览根本不会被画出来（dx 恒为 0，
    // `_incomingPreview` 直接早退），构建一棵邻页树纯属浪费。
    if (builder == null || widget.count < 2 || _drag == 0 || _motionless) {
      return;
    }
    final forward = _drag < 0; // 内容左移：下一个标签从右侧进来
    final target = widget.index + (forward ? 1 : -1);
    if (target == _previewTarget) return;
    _previewTarget = target;
    _preview = target < 0 || target >= widget.count ? null : builder(target);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    // 没位移可看时判方向只能听原始拖距（`_offset` 一直是 0）。
    final step = _stepFor(
      _motionless ? _drag : _offset.value,
      details.velocity.pixelsPerSecond.dx,
    );
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

  /// 原始位移 → 实际位移：跟手、阻尼、越界回弹。
  ///
  /// 越过 [TabSwipeArea.followFraction] 后按指数衰减：交界处的斜率仍是 1，
  /// 之后一路平滑逼近 [TabSwipeArea.maxFollowFraction]，但永远到不了。以前
  /// 这里是「两段直线 + 硬封顶」，手指匀速拖动时画面会在 28% 处突然变慢、
  /// 42% 处彻底不动，真机上就是「拖到一定宽度卡一下」。
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
    final limit = _width * TabSwipeArea.maxFollowFraction;
    final magnitude = dx.abs();
    if (magnitude <= direct) return dx;
    final span = limit - direct;
    if (span <= 0) return dx.clamp(-limit, limit).toDouble();
    final total = direct + span * (1 - math.exp(-(magnitude - direct) / span));
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
    final seq = ++_commitSeq;
    _busy = true;
    final width = _width;
    // 系统开了「移除动画」：整条链都不该有位移。`_to` 会直接落位，但下面两处
    // 手工赋值不受它管，屏幕上就是一次 136px 的闪现（实测一帧 dx=136）。
    final motionless = _ms(TabSwipeArea.enterMs) <= 0;
    try {
      // 1) 起势：把当前内容按方向送出去，切换才「看得见」。
      //
      // 已经拖过出场距离时不再往回缩：从 -42% 拉回 -34% 再切走，屏幕上就是
      // 「松手先顿一下、画面反向退一点」——用户反馈的卡顿。
      final exitTarget = -step * width * TabSwipeArea.exitFraction;
      final alreadyOut = step > 0
          ? _offset.value <= exitTarget
          : _offset.value >= exitTarget;
      if (!motionless && !alreadyOut) {
        await _to(exitTarget, TabSwipeArea.exitMs, Curves.easeOutCubic);
        if (!mounted) return;
      }
      // 2) 立刻换标签：父级的请求/落盘从这一刻开始，动画不占它的时间。
      final previous = widget.index;
      widget.onSelect(previous + step);
      // 3) 先把位移摆到「迎入」那一侧，再去等新内容挂上。
      //
      // 顺序不能反：位移只是个 ValueNotifier，改它只把 Transform 标脏，
      // 真正绘制在下一帧——父级 setState 的重建也在同一帧。先 `await
      // endOfFrame` 再改的话，父级那一帧拿到的还是**出场**位移（-34% 屏宽），
      // 屏幕上就是「新内容先在左边露出来、下一帧又跳到右边」的一次 68% 屏宽
      // 横跳（用户反馈的「短剧切得对但不流畅」）。
      if (!motionless) {
        _offset.value = step * width * TabSwipeArea.enterFraction;
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      // 标签换过来了就先放开锁：迎入这 190ms 里再抓一次手是快速连滑的正常
      // 操作，`_onDragStart` 会从当前位移接管，不该把整次手势丢掉。
      if (widget.index != previous) _busy = false;
      // 只认「标签真的换了」：父级不认时（越界、数据未就绪）内容没换，画面
      // 会从迎入侧滑回原位——代价是那 68% 的一下，得等这一帧才知道父级收
      // 没收，而这时内容已经画在迎入侧了。三个调用方都是同步认单，走不到。
      await _to(
        0,
        widget.index == previous ? TabSwipeArea.settleMs : TabSwipeArea.enterMs,
        Curves.easeOutCubic,
      );
    } finally {
      // 只有还归本次负责时才解铃：被下一次 commit 接管后，这里清 `_busy`
      // 会把接管者的锁误放开，让它也变成可被打断的状态。
      if (seq == _commitSeq) _busy = false;
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
        // 裁剪放在 Transform 外面：位移会把内容送出滑动区，而滚动组件自己
        // 可能关掉裁剪（首页要让钉住的顶栏画到视口外，见 SwipeStationary 的
        // 注释），这里兜住滑动区边缘。
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (enabled)
                ValueListenableBuilder<double>(
                  valueListenable: _offset,
                  builder: (context, offset, _) =>
                      _incomingPreview(offset, width),
                ),
              RawGestureDetector(
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
                  //
                  // 重绘边界默认开着省重录；但页面里有反向位移（SwipeStationary）
                  // 时必须关掉，否则钉住的顶栏会被边界栅格裁掉，见 [isolateChild]。
                  child: TabSwipeOffset(
                    offset: _offset,
                    child: widget.isolateChild
                        ? RepaintBoundary(child: widget.child)
                        : widget.child,
                  ),
                  builder: (context, offset, child) => Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 拖动时铺在「正在进来」那一侧的邻页。
  ///
  /// 当前内容整体位移了 dx，右侧（dx < 0）或左侧（dx > 0）露出的那一条才是
  /// 邻页该出现的地方。预览放在 Stack 里、当前内容之下，再用 ClipRect 把可见
  /// 范围限制在缺口内——当前内容没移开的部分一点都不会透出预览。
  Widget _incomingPreview(double dx, double width) {
    if (dx == 0 || !widget.enabled || widget.count < 2) {
      return const SizedBox.shrink();
    }
    final forward = dx < 0; // 内容左移：下一个标签从右侧进来
    final target = widget.index + (forward ? 1 : -1);
    if (target != _previewTarget) return const SizedBox.shrink();
    final preview = _preview;
    if (preview == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: ClipRect(
        clipper: _IncomingGapClipper(dx),
        child: Transform.translate(
          offset: Offset(forward ? width + dx : dx - width, 0),
          child: preview,
        ),
      ),
    );
  }
}

/// 只显示「当前内容移开后」的那一条：左滑留右侧缺口，右滑留左侧缺口。
class _IncomingGapClipper extends CustomClipper<Rect> {
  const _IncomingGapClipper(this.dx);

  final double dx;

  @override
  Rect getClip(Size size) {
    if (dx < 0) {
      return Rect.fromLTRB(size.width + dx, 0, size.width, size.height);
    }
    return Rect.fromLTRB(0, 0, dx, size.height);
  }

  @override
  bool shouldReclip(_IncomingGapClipper oldClipper) => oldClipper.dx != dx;
}

/// 把 [TabSwipeArea] 当前的位移告诉子树。
///
/// 只传一个 `ValueListenable`，不在这里监听：真正要用的是 [SwipeStationary]，
/// 它自己只重建「一层 Transform」，不会让整棵子树跟着每帧重建。
class TabSwipeOffset extends InheritedWidget {
  const TabSwipeOffset({super.key, required this.offset, required super.child});

  final ValueListenable<double> offset;

  static ValueListenable<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabSwipeOffset>()?.offset;

  @override
  bool updateShouldNotify(TabSwipeOffset oldWidget) =>
      offset != oldWidget.offset;
}

/// 横滑切换时待在原地不跟着走的子树（首页的搜索行、分类条）。
///
/// 首页把搜索行和分类条都放在了滚动视图里（搜索行会随滚动收起，分类条吸顶），
/// 而滚动视图整体在 [TabSwipeArea] 里——切分类时它们会连内容一起横移 68% 屏
/// 宽再滑回来，看上去就是「整个页面被换掉了」。短剧页没有这个问题：它的顶栏
/// 在滑动区外面。这里给顶栏套一层反向位移，把它钉在屏幕上，只让内容跟手。
///
/// 不在 [TabSwipeArea] 里（比如短剧页自己的顶栏）时原样返回，不引入额外开销。
///
/// **宿主滚动视图必须把裁剪交给 [TabSwipeArea]**：反向位移会把顶栏画到滚动
/// 视口之外，而 `Viewport` 默认 `Clip.hardEdge` 只认自己的 bounds，超出的
/// 右半截搜索行和末位标签会被直接裁掉，露出背景色（深色主题下就是一块黑
/// 面板压在顶栏上）。首页因此用 `clipBehavior: Clip.none` 建 `CustomScrollView`，
/// 由 [TabSwipeArea] 外层那圈 `ClipRect` 统一裁到滑动区边缘。
class SwipeStationary extends StatelessWidget {
  const SwipeStationary({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final offset = TabSwipeOffset.maybeOf(context);
    if (offset == null) return child;
    return ValueListenableBuilder<double>(
      valueListenable: offset,
      // 位移为 0 时也留着这层 Transform：写成 `dx == 0 ? child : Transform...`
      // 会让这个位置的 widget 类型在每次起手/收尾时来回切换，RenderObject 被
      // 插入再删除。每帧只有这层 Transform 重建，子树不动。
      child: child,
      // 反向位移外面**不能**套重绘边界：边界的栅格只有它自己 size 那么大，
      // 反向位移把内容推出这块范围之外就直接不画。真机上的表现是搜索行右半截、
      // 「分类」按钮、末位标签一起消失，露出黑色画布，像一块黑面板压在顶栏上
      // （2026-11-02 一加 Ace 3 Pro 实拍）。滚动视口自己的裁剪同理，见类文档。
      // 代价是横滑期间整页那一层要重录——那才是该省的地方，但不能拿裁掉顶栏来换。
      builder: (context, dx, child) =>
          Transform.translate(offset: Offset(-dx, 0), child: child),
    );
  }
}
