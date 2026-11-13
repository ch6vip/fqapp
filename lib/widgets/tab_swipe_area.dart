import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'horizontal_drag_gesture_recognizer.dart';

/// 横向手势切顶栏标签的外壳：首页书城分类、短剧频道、书架一级 tab 共用。
///
/// [TabSwipeArea.pages] 使用真实 PageView，供首页、短剧、经典书架使用。
/// 以下说明仅针对尚未迁移的单内容构造器：
/// * 首页六个分类共用一个 feed，切分类要换 `tabIndex`、换 cells、重新请求，
///   分页游标和滚动位置都在 provider 里；
/// * 短剧的频道决定整页形态（竖滑播放流 / 瀑布格 / 本地列表），换频道还要
///   释放内联播放器、换壳层 dock 配色；
/// * 书架的三个 tab 共享编辑态与选中集合，切 tab 要一并复位。
/// 按 tab 把三页拆成 `PageView` 的 children 等于把三份数据流重写一遍。所以这里
/// 只做「手势 + 位移」：拖动时内容跟手横移。松手后，有邻页预览就把视口连续
/// 推到相邻页边界，预览铺满整屏时换页。首页、短剧与经典书架采用这条路径，
/// 没有「送出 → 迎入」两段之间的停顿和底色缺口；未提供预览时才退回三段式。
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
    this.onProgress,
  }) : pageBuilder = null,
       onScrollStateChanged = null;

  /// 稳定分页：每个标签只有一棵真实子树，首次出现时惰性挂载，离屏后保活。
  const TabSwipeArea.pages({
    super.key,
    required this.index,
    required this.count,
    required this.onSelect,
    required this.pageBuilder,
    this.enabled = true,
    this.onProgress,
    this.onScrollStateChanged,
  }) : child = const SizedBox.shrink(),
       previewBuilder = null;

  final IndexedWidgetBuilder? pageBuilder;
  final ValueChanged<bool>? onScrollStateChanged;

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
  /// 露出一块背景色。短剧和经典书架也提供目标频道内容；未接入的页面可传 null。
  ///
  /// 只会为「当前这次拖动」调用一次，不要在这里做重活。
  final Widget Function(int targetIndex)? previewBuilder;

  /// 横向进度的回调，让顶栏那条指示条跟着手指走。
  ///
  /// 值的语义是「页进度」：`0` 是当前页，`-1` 是上一页，`1` 是下一页，取值
  /// 连续。拖动时它是手指位置换算出来的实时值；松手后若是切过去了，它会继续
  /// 补间到 `-1`/`1` 再归零（换页完成），若是弹回，它会回到 `0`。
  ///
  /// 顶栏在滑动区**外面**（它自己不跟着内容横移），所以它拿不到这里内部的
  /// 位移；这个回调就是把位移递出去的唯一通道。没有它，标签栏只能在换页
  /// 之后才动一下——点按有动画、拖动没有。
  final ValueChanged<double>? onProgress;

  /// 位移超过屏宽的这个比例就认这次切换（不甩也能滑过去）。
  static const double commitFraction = 0.18;

  /// 位移不到阈值时，速度超过这个值（逻辑像素/秒）也算切换。
  static const double commitVelocity = 220;

  /// 跟手上限（屏宽比例）：1:1 跟随手指直到相邻页边界（一屏宽），与 PiliPlus
  /// 的 TabBarView 真页面滚动一致。旧版阻尼到 42% 会「不跟手」，已移除。
  static const double maxFollowFraction = 1.0;

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

  /// 有邻页预览时，松手后把视口连续推到相邻页边界的时长（毫秒）。这一段是真
  /// 页面滚动：预览全程可见，到边界铺满整屏再无缝换页，没有两段式之间的停顿。
  static const int commitMs = 220;

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

  /// The page-progress tween. It rides the same controller as [_tween],
  /// so the header indicator and the content can never drift apart.
  Animation<double>? _progressTween;

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

  /// 当前页进度（`-1` 上一页 / `0` 当前页 / `1` 下一页），递给顶栏的指示条。
  ///
  /// 拖动时按位移实时算；点标签的下划线由顶栏自身补间，进度保持 0。
  double _progress = 0;

  /// 丢弃已经被后续进度取代的帧后通知。
  int _progressRevision = 0;

  @override
  void initState() {
    super.initState();
    _anim.addListener(_applyTween);
  }

  @override
  void didUpdateWidget(TabSwipeArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 稳定分页由 [_TabPager] 自己跟着 PageController 走；这里若再补入场位移，
    // 会每帧把顶栏进度写回 0，下划线和页面位置就对不上了。
    if (widget.pageBuilder != null) return;
    if (widget.index != oldWidget.index) {
      // 邻页已经变成当前页：预览和真正的内容不能同屏，入场动画也不需要它。
      _preview = null;
      _previewTarget = null;
      // 手势提交已在切换帧之前归零；外部切换也终止旧进度补间。
      _progressTween = null;
      _progress = 0;
      _publishProgress(0);
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
    // 点按的目标索引已经更新，顶栏自行从旧标签补间到新标签。
    // 入场位移只作用于内容，不能再加到新索引上，否则下划线会越过目标。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _to(0, TabSwipeArea.enterMs, Curves.easeOutCubic, progressTarget: 0),
      );
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
    final progressTween = _progressTween;
    if (progressTween != null) {
      _progress = progressTween.value;
    }
    _publishProgress(_progress);
  }

  /// 把当前手势/动画的进度递给顶栏：`-1` 是上一页，`0` 是当前页，`1` 是下一页。
  ///
  /// 进度仅描述手势及其收尾动画；点按后的内容入场位移不参与顶栏定位。
  void _publishProgress(double progress) {
    final revision = ++_progressRevision;
    final callback = widget.onProgress;
    if (callback == null) return;
    final value = progress.clamp(-1.0, 1.0);
    // 只有 build/layout/paint 阶段不能通知顶栏。动画 Future 完成后的
    // midFrameMicrotasks 仍在 build 之前，必须立即发布：否则本帧会把
    // 新 index 与旧 progress 叠加，下划线先越位一格、下一帧再回弹。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != _progressRevision) return;
        widget.onProgress?.call(value);
      });
      return;
    }
    callback(value);
  }

  /// 拖动中的进度：位移一屏宽 = 走完一整页。
  double _dragProgress() {
    final width = _width;
    if (width <= 0 || !width.isFinite) return 0;
    // `_offset < 0` 是往下一个标签（内容左移），所以取反。
    return (-_offset.value / width).clamp(-1.0, 1.0);
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
    // The header indicator follows the finger: progress is the offset as a
    // fraction of one page.
    _progress = _dragProgress();
    _publishProgress(_progress);
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
      // Spring back to the current page; the indicator returns with it.
      unawaited(
        _to(0, TabSwipeArea.settleMs, Curves.easeOutCubic, progressTarget: 0),
      );
      return;
    }
    unawaited(_commit(step));
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    unawaited(
      _to(0, TabSwipeArea.settleMs, Curves.easeOutCubic, progressTarget: 0),
    );
  }

  /// 原始位移 → 实际位移：1:1 跟手 + 越界回弹（PiliPlus TabBarView 同款）。
  ///
  /// 内容跟手指 1:1 横移，到相邻页边界（一屏宽）封顶——真页面滚动的观感，
  /// 不再有旧版「拖到一定宽度就拖不动」的阻尼。首尾越界仍给一段阻尼位移。
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
    final limit = _width * TabSwipeArea.maxFollowFraction;
    return dx.clamp(-limit, limit).toDouble();
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

  /// 松手后的换页。有邻页预览时走「真页面滚动」：把视口连续推到相邻页边界，
  /// 预览铺满整屏的那一刻再换标签、位移同帧归零——无缝接管，没有停顿。没有
  /// 预览时退回「送出 → 换标签 → 迎入」三段式，系统关了动画则直接换页。
  Future<void> _commit(int step) async {
    final seq = ++_commitSeq;
    _busy = true;
    final width = _width;
    // 系统开了「移除动画」：整条链都不该有位移。`_to` 会直接落位，但下面两处
    // 手工赋值不受它管，屏幕上就是一次 136px 的闪现（实测一帧 dx=136）。
    final motionless = _ms(TabSwipeArea.enterMs) <= 0;
    // 预览必须正好是这次要切去的邻页，连续滚动才接得上；否则退回三段式。
    final continuous =
        !motionless &&
        _preview != null &&
        _previewTarget == widget.index + step;
    try {
      if (continuous) {
        // 连续推到边界（一屏宽）：当前内容滑出、预览滑入，全程 1:1 接续，
        // 不再有「先送出 110ms、再换页、再迎入 190ms」之间的停顿和底色缺口。
        final boundary = -step * width;
        final startIndex = widget.index;
        // 滚动期间不锁：再抓一次手能从当前位移接管，快速连滑不丢手势。
        _busy = false;
        // `step` is 1 for the next tab, -1 for the previous one; the
        // indicator slides the same way the content does.
        await _to(
          boundary,
          TabSwipeArea.commitMs,
          Curves.easeOutCubic,
          progressTarget: step.toDouble(),
        );
        // 被新一次抓手 / 新一次 commit / 外部点标签（index 已变）接管了就让位。
        if (!mounted ||
            _dragging ||
            seq != _commitSeq ||
            widget.index != startIndex) {
          return;
        }
        // 到边界：预览此刻正好铺满整屏，换标签后真内容同帧接管位移 0，
        // 视觉上就是同一张页面继续停在那里，没有横跳、没有露底色。
        _busy = true;
        final previous = widget.index;
        widget.onSelect(previous + step);
        _offset.value = 0;
        // 立刻把 progress 归零并同步发布，**不能等 didUpdateWidget**。
        // 一旦顶栏的 selected 也换成了新 tab，如果 progress 还停在
        // step（比如 1.0），`_floatingPosition = newIndex + step` 会把
        // 指示条瞬间跳到 newIndex + 1（弹一下），等 post-frame 回调
        // 归零才跳回来。这里同步发 0 让顶栏同一帧 build 就拿到正确值。
        _progress = 0;
        _publishProgress(0);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        // 父级不认账（越界/数据未就绪，三个调用方都同步认单，走不到）：
        // 内容没换，位移已在 0，旧页照常满屏，无需再补动画。
        return;
      }
      // 1) 起势：把当前内容按方向送出去，切换才「看得见」。
      //
      // 已经拖过出场距离时不再往回缩：从 -42% 拉回 -34% 再切走，屏幕上就是
      // 「松手先顿一下、画面反向退一点」——用户反馈的卡顿。
      final exitTarget = -step * width * TabSwipeArea.exitFraction;
      final alreadyOut = step > 0
          ? _offset.value <= exitTarget
          : _offset.value >= exitTarget;
      if (!motionless && !alreadyOut) {
        await _to(
          exitTarget,
          TabSwipeArea.exitMs,
          Curves.easeOutCubic,
          progressTarget: step.toDouble(),
        );
        if (!mounted) return;
      }
      // 2) 立刻换标签：父级的请求/落盘从这一刻开始，动画不占它的时间。
      final previous = widget.index;
      widget.onSelect(previous + step);
      // 进度必须和 index 同帧归零，理由与「已到边界」那条路相同：上面把
      // progress 补到了 ±1，父级的 index 一换，`index + progress` 就变成
      // 再下一个标签，下划线先窜过去一格、再被动画拉回来——用户看到的就是
      // 「到位置后又弹一下」。
      _progress = 0;
      _publishProgress(0);
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
  Future<void> _to(
    double target,
    int milliseconds,
    Curve curve, {
    double? progressTarget,
  }) async {
    if (!mounted) return;
    final from = _offset.value;
    final duration = _ms(milliseconds);
    if (duration <= 0 || from == target) {
      _offset.value = target;
      if (progressTarget != null) {
        _progress = progressTarget;
        _publishProgress(_progress);
      }
      return;
    }
    _anim.duration = Duration(milliseconds: duration);
    _curve.curve = curve;
    _tween = Tween<double>(begin: from, end: target).animate(_curve);
    // The progress tween rides the same controller as the offset tween: the
    // page progress is a ratio of the offset, so one curve drives both and the
    // header indicator cannot drift away from the content.
    _progressTween = progressTarget == null
        ? null
        : Tween<double>(begin: _progress, end: progressTarget).animate(_curve);
    try {
      await _anim.forward(from: 0);
    } catch (_) {
      // TickerFuture 只有两种收场：跑完，或者被下一个补间 / 页面销毁打断
      // （TickerCanceled）。第二种没有要收尾的东西，接着让调用方判断。
    }
  }

  @override
  Widget build(BuildContext context) {
    // 稳定分页模式拥有独立的手势与生命周期，整块交给 [_TabPager]。
    final pages = widget.pageBuilder;
    if (pages != null) {
      return _TabPager(
        index: widget.index,
        count: widget.count,
        enabled: widget.enabled,
        onSelect: widget.onSelect,
        onProgress: widget.onProgress,
        onScrollStateChanged: widget.onScrollStateChanged,
        pageBuilder: pages,
      );
    }
    final enabled = widget.enabled && widget.count > 1;
    // 用 LayoutBuilder 记宽度，而不是每次切换时读 context.size：这里的
    // constraints 在 layout 阶段就确定了，didUpdateWidget（build 阶段）也能
    // 沿用上一次的值。只写字段不 setState，不会多出一次重建。
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width.isFinite && width > 0) _width = width;
        // Clip after translation so outgoing content stays in the swipe area.
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
                        CustomHorizontalDragGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                              CustomHorizontalDragGestureRecognizer
                            >(
                              CustomHorizontalDragGestureRecognizer.new,
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
                  // Keep painting and rebuilds independent of translation.
                  child: RepaintBoundary(child: widget.child),
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

/// 稳定分页：`PageView` 持有每个标签的真实子树，滚动物理自带手势接续。
///
/// 与旧的三段式相比，这里没有「先送出、再换标签、再迎入」的提交时机：页面
/// 位置本身就是唯一事实来源，手指松开后由 [ScrollPosition] 吸附，动画中途
/// 再次抓手会直接从当前位置接管，可以连续推进多个标签。
class _TabPager extends StatefulWidget {
  const _TabPager({
    required this.index,
    required this.count,
    required this.enabled,
    required this.onSelect,
    required this.pageBuilder,
    this.onProgress,
    this.onScrollStateChanged,
  });

  final int index;
  final int count;
  final bool enabled;
  final ValueChanged<int> onSelect;
  final IndexedWidgetBuilder pageBuilder;
  final ValueChanged<double>? onProgress;
  final ValueChanged<bool>? onScrollStateChanged;

  @override
  State<_TabPager> createState() => _TabPagerState();
}

class _TabPagerState extends State<_TabPager> {
  /// 在 initState 里建好：控制器拿到的 `initialPage` 必须是挂载时的真实下标，
  /// 懒初始化会拖到 widget 已经换过下标之后才创建，首屏就停在第 0 页。
  late final PageController _controller;
  int _reportedIndex = 0;
  int? _externalTarget;

  /// 外部排程的代际：只有最后一次排程的动画有权收尾。
  int _animRevision = 0;
  int _revision = 0;
  bool _scrolling = false;
  double _motionlessDrag = 0;

  @override
  void initState() {
    super.initState();
    _reportedIndex = widget.index;
    _controller = PageController(initialPage: widget.index, keepPage: false)
      ..addListener(_positionChanged);
  }

  double get _page =>
      _controller.hasClients && _controller.position.hasContentDimensions
      ? _controller.page ?? _reportedIndex.toDouble()
      : _reportedIndex.toDouble();

  @override
  void didUpdateWidget(_TabPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 目标又回到当前页（快速连点同一个 tab、或 A→B→A）：把进行中的
    // 外部位移动画收回来，否则它会一路跑到上一次的目标页。
    //
    // 已经指向同一目标时**不再重排**：父级在回程的 260ms 里再 build 一次
    // 就会重复 arm，第二个 `animateToPage` 挤掉第一个，被挤掉的 future 立刻
    // 完成并提前清闩，此时页面还在半路 → `round()` 会报出错误下标、回调
    // `onSelect` 把页面闪回上一个 tab。
    if (widget.index == _reportedIndex) {
      if (_externalTarget != null && _externalTarget != widget.index) {
        _externalTarget = widget.index;
        _scheduleExternal(widget.index);
      }
      return;
    }
    // `_reportedIndex` 只跟随真实页面位置：外部点选期间它不动，由滚动的
    // 收尾把它落到新下标。这样即使控制器还没 attach，进度也不会与页错位。
    if (widget.index != _reportedIndex && widget.index != _externalTarget) {
      _externalTarget = widget.index;
      _publishProgress(0);
      _scheduleExternal(widget.index);
    }
  }

  /// 把视口滚到外部点选的目标页。
  ///
  /// 首帧里 PageView 可能还没 attach（`hasClients` 为假），此时不能把
  /// [_externalTarget] 永远挂着：那会挡住后续所有进度上报。重试几次等布局。
  ///
  /// 每次排程都领一个 [_animRevision]：被新一次排程挤掉的动画**无权收尾**
  /// （只比较目标值不够——两次目标相同时旧动画会提前清闩）。
  void _scheduleExternal(int target, [int attempt = 0]) {
    final revision = ++_animRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _animRevision || _externalTarget != target) {
        return;
      }
      if (!_controller.hasClients) {
        if (attempt < 3) {
          _scheduleExternal(target, attempt + 1);
        } else {
          _externalTarget = null;
          _positionChanged();
          // 放弃滚动了就不会有 ScrollEnd：补发一次「横滑结束」，否则外面
          // 预置的「横滑中」闩永远等不到复位，播放器再也不起播。
          widget.onScrollStateChanged?.call(false);
        }
        return;
      }
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.jumpToPage(target);
        _externalTarget = null;
        _positionChanged();
      } else {
        unawaited(_animateTo(target, revision));
      }
    });
  }

  Future<void> _animateTo(int target, int revision) async {
    await _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || revision != _animRevision || _externalTarget != target) {
      return;
    }
    _externalTarget = null;
    _positionChanged();
  }

  void _positionChanged() {
    if (_externalTarget != null || widget.count < 1) return;
    final page = _page.clamp(0.0, (widget.count - 1).toDouble());
    final next = page.round();
    if (next != _reportedIndex) {
      _reportedIndex = next;
      widget.onSelect(next);
    }
    // 索引越过半页时立即换基准，不能把新 index 与旧 progress 叠加。
    _publishProgress(page - _reportedIndex);
  }

  void _publishProgress(double value) {
    final revision = ++_revision;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == _revision) widget.onProgress?.call(value);
      });
    } else {
      widget.onProgress?.call(value);
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null && _externalTarget != null) {
        _externalTarget = null;
        _positionChanged();
      }
      if (!_scrolling) {
        _scrolling = true;
        widget.onScrollStateChanged?.call(true);
      }
    } else if (notification is ScrollEndNotification) {
      if (_scrolling) {
        _scrolling = false;
        widget.onScrollStateChanged?.call(false);
      }
    }
    return false;
  }

  @override
  void dispose() {
    // 频道表回包会换 key、整个 pager 重建：滚动中的状态拿不到 ScrollEnd，
    // 帧后补发一次「横滑结束」，避免外面的闩永久挂住（真机表现为推荐流
    // 不再起播、旧解码器不释放）。
    //
    // 契约：回调可能在 pager 已经销毁之后的帧里到达，接的人必须自己检查
    // `mounted`（现有唯一消费者 `DramaPage._onChannelScroll` 首行就查）。
    if (_scrolling) {
      _scrolling = false;
      final notify = widget.onScrollStateChanged;
      if (notify != null) {
        SchedulerBinding.instance.addPostFrameCallback((_) => notify(false));
      }
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final motionless = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.enabled && widget.count > 1;
    final pager = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: PageView.builder(
        controller: _controller,
        // 从按下点起算：默认的 `start` 会把越过 slop 的那一段位移吃掉，
        // 起手先顿一下再跟手，快速轻扫还会整段丢失。
        dragStartBehavior: DragStartBehavior.down,
        // 不复制参考仓库的 SDK 补丁，使用框架原生分页与手势接续。
        physics: enabled && !motionless
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        itemCount: widget.count,
        itemBuilder: (context, index) => _KeptAliveTab(
          key: ValueKey(index),
          active: index == widget.index,
          child: widget.pageBuilder(context, index),
        ),
      ),
    );
    if (!motionless || !enabled) return pager;
    // 减少动态效果时仍支持手势切换，但不显示跟手位移或收尾动画。
    return LayoutBuilder(
      builder: (context, constraints) => RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          CustomHorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                CustomHorizontalDragGestureRecognizer
              >(
                CustomHorizontalDragGestureRecognizer.new,
                (recognizer) => recognizer
                  ..dragStartBehavior = DragStartBehavior.down
                  ..onStart = (_) {
                    _motionlessDrag = 0;
                  }
                  ..onUpdate = (details) {
                    _motionlessDrag += details.delta.dx;
                  }
                  ..onEnd = (details) {
                    final velocity = details.velocity.pixelsPerSecond.dx;
                    if (_motionlessDrag.abs() <
                            constraints.maxWidth *
                                TabSwipeArea.commitFraction &&
                        velocity.abs() < TabSwipeArea.commitVelocity) {
                      return;
                    }
                    final direction = _motionlessDrag == 0
                        ? velocity
                        : _motionlessDrag;
                    final next = (widget.index + (direction < 0 ? 1 : -1))
                        .clamp(0, widget.count - 1);
                    if (next != widget.index) widget.onSelect(next);
                  }
                  ..onCancel = () {
                    _motionlessDrag = 0;
                  },
              ),
        },
        child: pager,
      ),
    );
  }
}

class _KeptAliveTab extends StatefulWidget {
  const _KeptAliveTab({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_KeptAliveTab> createState() => _KeptAliveTabState();
}

class _KeptAliveTabState extends State<_KeptAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: ExcludeSemantics(
        excluding: !widget.active,
        child: ExcludeFocus(
          excluding: !widget.active,
          child: IgnorePointer(
            ignoring: !widget.active,
            child: PrimaryScrollController.none(child: widget.child),
          ),
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
