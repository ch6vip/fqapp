import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sliding_tab_indicator.dart';
import 'home_design.dart';

import 'home_tab_bar.dart' show HomeCategory, homeCategories;

/// Fixed above the swipeable feed; each label reserves its selected width.
/// Restored from f329399; the archive tab strip remains separate.
///
/// 滚动行为移植自 PiliPlus 首页（Material `TabBar(isScrollable: true,
/// tabAlignment: TabAlignment.center)`）：选中项变化时把对应标签平滑居中滚进
/// 视野（横滑切到屏外的分类也能看见），标签总宽不足一屏时整组居中。视觉
/// （预留选中宽、下划线、eink 描边）与点按契约保持不变。
class ClassicHomeTabBar extends StatefulWidget {
  static const double barHeight = 40;

  /// 标签条下缘到内容的留白。
  ///
  /// 这一层不能再加：下面第一段（排行榜标题 / 网格分区头）自带 8dp 上边距，
  /// 两段叠在一起才是「标签 → 内容」的间距。旧值 6 让标签到排行榜标题空了
  /// 将近 38dp，中间一片空白。
  static const double bottomPadding = 0;
  static const double selectedSize = 17;
  static const double unselectedSize = 15;
  static const double tabSpacing = 8;
  static const double labelPadding = 6;
  static const double sidePadding = 16;
  static const double maxExtraSpacing = 12;

  /// 滑动指示条：与 PiliPlus 首页标签条同款——选中项切换时，一条下划线在
  /// 标签中心之间连续滑动，而不是每标签各自淡入淡出。宽度/高度沿用原来的
  /// 16 × 2.5 圆角。
  static const double indicatorWidth = 16;
  static const double indicatorHeight = 2.5;
  static const double indicatorRadius = 2;

  /// 指示条相对内容区底部留白（与原来标签内 Column 的 5px 间隔接近）。
  static const double indicatorBottomGap = 6;

  /// 指示条滑动的时长，对齐 Material 的 kTabScrollDuration。
  ///
  /// 独立于文字动画（180ms）：下划线要在两个标签中心之间「走」一段距离，
  /// 用文字那么短的时长几乎是一帧跳过去，看起来像没动。
  static const Duration indicatorDuration = Duration(milliseconds: 300);

  /// 选中项居中滚动的时长，对齐 Material 的 kTabScrollDuration。
  static const Duration scrollDuration = Duration(milliseconds: 300);

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<HomeCategory> categories;

  /// The horizontal gesture progress: -1 is the previous tab, 0 the current
  /// one, 1 the next one, and the values in between are the live position
  /// while a finger is down.
  ///
  /// The header sits outside the swipe area, so it cannot read the drag
  /// offset itself; this is the channel that hands it over. When it is null
  /// the bar falls back to its own tap animation.
  final double? progress;

  const ClassicHomeTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    this.categories = homeCategories,
    this.progress,
  });

  @override
  State<ClassicHomeTabBar> createState() => _ClassicHomeTabBarState();
}

class _ClassicHomeTabBarState extends State<ClassicHomeTabBar> {
  final ScrollController _scroll = ScrollController();

  // 最近一次 build 量到的几何，供帧后居中用（build 先于 post-frame 跑）。
  // 宽度按选中样式预留，与选中下标无关，所以切换时几何稳定、不会抖。
  List<double> _widths = const [];
  double _gap = ClassicHomeTabBar.tabSpacing;
  double _viewport = 0;

  /// 横滑期间被推迟的居中请求；手指松开、进度归零后补一次。
  bool _centerPending = false;

  /// 上一次量标签宽度用的输入。横滑时顶栏每帧重建，靠它跳过 TextPainter。
  List<HomeCategory>? _measuredCategories;
  TextScaler? _measuredScaler;
  TextStyle? _measuredStyle;
  TextDirection? _measuredDirection;
  double _rowHeight = ClassicHomeTabBar.barHeight;

  /// 居中/下划线都要用的标签中心，几何不变时复用。
  List<double> _centres = const [];
  List<double>? _centresWidths;
  double _centresGap = double.nan;

  @override
  void initState() {
    super.initState();
    // 首帧可能带着非 0 的初始选中（深链直达某分类），布局后居中一次。
    _scheduleCenter();
  }

  @override
  void didUpdateWidget(covariant ClassicHomeTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.categories.length != widget.categories.length) {
      // 手指还没松开时不启动标签条的居中滚动：那会在横滑过程中再叠一段
      // 300ms 的横向动画，下划线会被这点位移推得反跳，白费一帧合成。
      if ((widget.progress ?? 0) != 0) {
        _centerPending = true;
      } else {
        _scheduleCenter();
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleCenter() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerSelected());
  }

  /// 选中标签未完整可见时居中滚进视野；已可见则保留滚动位置。
  /// 用户手动拖动标签条不触发此逻辑。
  void _centerSelected() {
    if (!mounted || !_scroll.hasClients || _widths.isEmpty) return;
    if (!_viewport.isFinite) return;
    final index = widget.selectedIndex;
    if (index < 0 || index >= _widths.length) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    // 标签 index 的中心在内容坐标（含前导 sidePadding）里的位置。
    var left = ClassicHomeTabBar.sidePadding;
    for (var k = 0; k < index; k++) {
      left += _widths[k] + _gap;
    }
    final center = left + _widths[index] / 2;
    // 已完整可见时不再额外滚动，避免标签本身移动与下划线动画叠加。
    final viewStart = position.pixels;
    final viewEnd = viewStart + _viewport;
    final tabLeft = left;
    final tabRight = left + _widths[index];
    if (tabLeft >= viewStart && tabRight <= viewEnd) return;
    final target = (center - _viewport / 2).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.5) return;
    // eink / 系统减弱动态效果：直接落位，不做滚动动画（与标签动画同门）。
    final motionless =
        HomePalette.of(context).eink || MediaQuery.disableAnimationsOf(context);
    if (motionless) {
      _scroll.jumpTo(target);
    } else {
      unawaited(
        _scroll.animateTo(
          target,
          duration: ClassicHomeTabBar.scrollDuration,
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final duration = palette.eink || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    // The underline travels between two centres, so it needs its own, longer
    // duration: at the text's 180ms it looks like it jumps. While a finger is
    // down it must not animate at all — an implicit animation would keep
    // chasing the gesture and then visibly catch up (a hop) on release.
    final following = (widget.progress ?? 0) != 0;
    if (_centerPending && !following) {
      _centerPending = false;
      _scheduleCenter();
    }
    final indicatorDuration =
        palette.eink || MediaQuery.disableAnimationsOf(context) || following
        ? Duration.zero
        : ClassicHomeTabBar.indicatorDuration;
    final scaler = MediaQuery.textScalerOf(context);
    final categories = widget.categories;
    // 标签宽度只在字号/字重/语言方向变化时才变；横滑期间顶栏每帧重建，
    // 不缓存的话就是每帧 6 次 TextPainter 排版。
    final labelStyle = _labelStyle(true, palette);
    final direction = Directionality.of(context);
    if (!identical(_measuredCategories, categories) ||
        _measuredScaler != scaler ||
        _measuredStyle != labelStyle ||
        _measuredDirection != direction) {
      _measuredCategories = categories;
      _measuredScaler = scaler;
      _measuredStyle = labelStyle;
      _measuredDirection = direction;
      final widths = <double>[];
      var rowHeight = ClassicHomeTabBar.barHeight;
      for (final category in categories) {
        final painter = TextPainter(
          text: TextSpan(text: category.label, style: labelStyle),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        widths.add(painter.width + ClassicHomeTabBar.labelPadding * 2);
        if (painter.height + 20 > rowHeight) rowHeight = painter.height + 20;
        painter.dispose();
      }
      _widths = widths;
      _rowHeight = rowHeight;
    }
    final rowHeight = _rowHeight;

    return DecoratedBox(
      decoration: BoxDecoration(color: palette.canvas),
      child: Padding(
        padding: const EdgeInsets.only(bottom: ClassicHomeTabBar.bottomPadding),
        child: SizedBox(
          height: rowHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewport = constraints.maxWidth;
              _viewport = viewport;
              final gap = _gapWidth(viewport, _widths);
              _gap = gap;
              if (_centresGap != gap ||
                  _centres.length != _widths.length ||
                  !identical(_centresWidths, _widths)) {
                _centresGap = gap;
                _centresWidths = _widths;
                _centres = SlidingTabStrip.centres(_widths, gap: gap);
              }
              // 不足一屏时整组居中（PiliPlus 的 TabAlignment.center）：把滚动
              // 子节点撑到至少「视口 − 两侧 padding」宽再居中；超出一屏时
              // minWidth 小于自然宽，ConstrainedBox 不生效，照常横向滚动。
              final minWidth = viewport.isFinite
                  ? math.max(0.0, viewport - 2 * ClassicHomeTabBar.sidePadding)
                  : 0.0;
              return SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: ClassicHomeTabBar.sidePadding,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: minWidth),
                  child: Center(
                    child: Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (
                              var index = 0;
                              index < categories.length;
                              index++
                            ) ...[
                              if (index > 0) SizedBox(width: gap),
                              _tab(
                                index,
                                _widths[index],
                                rowHeight,
                                duration,
                                palette,
                              ),
                            ],
                          ],
                        ),
                        // The selected background is one block that slides
                        // with the underline, so the whole selection travels
                        // as a single object.
                        AnimatedPositioned(
                          key: const ValueKey('home_tab_selection_block'),
                          left:
                              _tabCentre(_floatingPosition()) -
                              _selectedBlockWidth() / 2,
                          top: 0,
                          width: _selectedBlockWidth(),
                          height: rowHeight,
                          duration: indicatorDuration,
                          curve: Curves.easeOutCubic,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: palette.ink.withValues(
                                alpha: palette.dark ? 0.10 : 0.055,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        // One sliding underline, like PiliPlus's home tab bar:
                        // it travels between the tab centres instead of each
                        // tab fading its own line in and out.
                        AnimatedPositioned(
                          key: const ValueKey('home_tab_indicator'),
                          left:
                              _tabCentre(_floatingPosition()) -
                              ClassicHomeTabBar.indicatorWidth / 2,
                          top:
                              rowHeight -
                              ClassicHomeTabBar.indicatorHeight -
                              ClassicHomeTabBar.indicatorBottomGap,
                          width: ClassicHomeTabBar.indicatorWidth,
                          height: ClassicHomeTabBar.indicatorHeight,
                          duration: indicatorDuration,
                          curve: Curves.easeOutCubic,
                          child: Container(
                            decoration: BoxDecoration(
                              color: palette.ink,
                              borderRadius: BorderRadius.circular(
                                ClassicHomeTabBar.indicatorRadius,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  double _gapWidth(double availableWidth, List<double> widths) {
    final gaps = widget.categories.length - 1;
    if (gaps <= 0 || !availableWidth.isFinite) {
      return ClassicHomeTabBar.tabSpacing;
    }
    final contentWidth = widths.fold(0.0, (sum, width) => sum + width);
    // Fill phone widths without spreading the six labels across a desktop.
    final spare =
        availableWidth -
        2 * ClassicHomeTabBar.sidePadding -
        contentWidth -
        gaps * ClassicHomeTabBar.tabSpacing;
    if (spare <= 0) return ClassicHomeTabBar.tabSpacing;
    return ClassicHomeTabBar.tabSpacing +
        (spare / gaps).clamp(0.0, ClassicHomeTabBar.maxExtraSpacing);
  }

  /// The centre of the tab at the floating position [position], in the content
  /// coordinate space (inside the scroll padding).
  ///
  /// Delegates the shared floor/ceil→lerp math to [SlidingTabStrip].
  double _tabCentre(double position) {
    if (_centres.isEmpty || !_viewport.isFinite) return 0;
    // indicatorLeft returns centre - indicatorWidth/2; indicatorWidth=0
    // gives us the raw centre, which is what the callers need.
    return SlidingTabStrip.indicatorLeft(
      centres: _centres,
      position: position,
      indicatorWidth: 0,
    );
  }

  /// The floating tab position: the selected tab, plus the gesture progress.
  ///
  /// Delegates to [SlidingTabStrip.position] for the shared clamp math.
  double _floatingPosition() => SlidingTabStrip.position(
    index: widget.selectedIndex,
    progress: widget.progress ?? 0,
    count: widget.categories.length,
  );

  /// The width of the sliding selection block: the width of the tab it
  /// currently sits on (the selected one while a drag is in progress).
  double _selectedBlockWidth() {
    if (_widths.isEmpty) return 0;
    final index = widget.selectedIndex;
    if (index < 0 || index >= _widths.length) return 0;
    return _widths[index];
  }

  TextStyle _labelStyle(bool selected, HomePalette palette) => TextStyle(
    fontSize: selected
        ? ClassicHomeTabBar.selectedSize
        : ClassicHomeTabBar.unselectedSize,
    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    color: selected ? palette.ink : palette.muted,
    height: 1,
  );

  Widget _tab(
    int index,
    double width,
    double rowHeight,
    Duration duration,
    HomePalette palette,
  ) {
    final selected = index == widget.selectedIndex;
    final category = widget.categories[index];
    return Semantics(
      selected: selected,
      button: true,
      label: category.label,
      excludeSemantics: true,
      onTap: () => widget.onSelect(index),
      child: GestureDetector(
        key: ValueKey('home_category_$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSelect(index),
        child: SizedBox(
          height: rowHeight,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            width: width,
            decoration: BoxDecoration(
              // The selected background is a single block that slides with the
              // underline (see [_slidingBackground]), so it is drawn by the
              // bar and not by the tab itself.
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected && palette.eink
                    ? palette.ink
                    : Colors.transparent,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  style: _labelStyle(selected, palette),
                  child: Text(category.label, maxLines: 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
