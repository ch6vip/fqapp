/// 短剧 feed 的竖滑翻页物理，对齐官方 `SeriesPagerLayoutManager`。
///
/// 官方容器是 RecyclerView：`SeriesBookMallTabFragment.java:1184` 挂垂直
/// `SeriesPagerLayoutManager`，吸附器 `yn3.b extends PagerSnapHelper`。行为：
/// - fling（≥ 最小 fling 速度）：**沿方向翻一页**
///   （`PagerSnapHelper.findTargetSnapPosition`，无论速度多大都只翻一页）；
/// - 吸附动画由 `SnapHelper.createSnapScroller` → `LinearSmoothScroller`
///   以**恒速滑行**执行：`MILLISECONDS_PER_INCH = 100ms/英寸`。1 英寸 =
///   160×density 逻辑像素、dpi = 160×density，密度相消后恒为
///   **1600 逻辑像素/秒**——一整页 ≈ 500ms，到位即停（没有末端弹簧）；
/// - 慢速松手（低于 fling 门）：就近吸附（`snapToTargetExistingView`）。
///
/// Flutter 默认 `PageScrollPhysics` 用临界阻尼弹簧收尾，起步猛、收尾硬，
/// 观感不圆润；本类把上面的三条行为落进 ballistic simulation。
library;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/widgets.dart';

/// 短剧 feed 专用翻页物理。给 `PageView.physics` 直接传 `const` 实例即可；
/// `applyTo` 会把平台物理（Android 上是 Clamping）接回父链，边界钳制不变。
class SeriesPagerScrollPhysics extends PageScrollPhysics {
  const SeriesPagerScrollPhysics({super.parent});

  @override
  SeriesPagerScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      SeriesPagerScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if (position is! PageMetrics ||
        !position.hasPixels ||
        !position.hasContentDimensions ||
        !position.hasViewportDimension) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position.page;
    final viewport = position.viewportDimension;
    if (page == null || !page.isFinite || viewport <= 0) {
      return super.createBallisticSimulation(position, velocity);
    }
    // 最后一页的下标（PageView 一页占满 viewport）。
    final lastPage = position.maxScrollExtent / viewport;
    final double target;
    if (velocity.abs() >= minFlingVelocity) {
      // 官方 ViewConfiguration 最小 fling 速度就是 50dp/s（与 Flutter 的
      // kMinFlingVelocity 一致）。上滑 offset 增大、velocity 为正 → 下一页。
      target = velocity > 0 ? page.floorToDouble() + 1 : page.ceilToDouble() - 1;
    } else {
      target = page.roundToDouble();
    }
    final safeTarget = target.clamp(0.0, lastPage).toDouble();
    final distance = safeTarget * viewport - position.pixels;
    if (distance.abs() < precisionErrorTolerance) {
      return super.createBallisticSimulation(position, velocity);
    }
    return SeriesPagerGlideSimulation(position.pixels, distance);
  }
}

/// `LinearSmoothScroller` 的恒速滑行吸附：从 [start] 匀速走 [distance]，
/// 速率 1600 逻辑像素/秒（= 官方 100ms/英寸），到位即停。
class SeriesPagerGlideSimulation extends Simulation {
  SeriesPagerGlideSimulation(double start, double distance)
    : _start = start,
      _end = start + distance,
      _velocity = distance.isNegative ? -_settleSpeed : _settleSpeed,
      _duration = distance.abs() / _settleSpeed;

  static const _settleSpeed = 1600.0;

  final double _start;
  final double _end;
  final double _velocity;
  final double _duration;

  @override
  double x(double time) => time >= _duration ? _end : _start + _velocity * time;

  @override
  double dx(double time) => time >= _duration ? 0 : _velocity;

  @override
  bool isDone(double time) => time >= _duration;
}
