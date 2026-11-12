import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/gestures.dart';

/// 横滑方向识别器，移植自 PiliPlus 的 `CustomHorizontalDragGestureRecognizer`。
///
/// 标准 [HorizontalDragGestureRecognizer] 只要横向位移 `|dx|` 越过 touchSlop
/// 就接受，完全不看纵向分量。于是斜向横滑时，内层更深的竖滑识别器（手势竞技场
/// 平局先赢）常常抢先接受，表现就是用户反馈的「左右滑被当成上下滑」。这里加两道
/// 闸让方向判定干脆：
///
/// * 横向 touchSlop 取设备值 + 6（比竖滑略大，轻微抖动不会误触横滑）；
/// * 角度守卫：横向位移须大于纵向 3 倍（`|dx| > 3·|dy|`）才接受——真横滑稳稳
///   赢，竖滑因角度不达标永远不会被横滑抢走。
///
/// 不覆盖 [runtimeType]：PiliPlus 把它报成基类，是为了塞进 `Scrollable` 按基类
/// 建键的识别器表；这里走 [RawGestureDetector]，表按本类建键，框架会断言
/// `recognizer.runtimeType == 键`，覆盖成基类反而让断言失败、整片手势失效。
/// 竞技场按实例裁决，从不看 [runtimeType]，所以不覆盖不影响方向判定。
///
/// **生效范围**：只在 `TabSwipeArea.pages` 的 `motionless`（减弱动态效果）分支
/// 与旧三段式构造器里挂载。走真实 `PageView` 的默认路径由框架内部创建
/// `HorizontalDragGestureRecognizer`，本 SDK 的 `ScrollBehavior` 没有暴露
/// 替换识别器的钩子，注入不进去——那条路径仍是框架默认裁决，斜向横滑可能
/// 被判给内层竖滑。要覆盖它得换一种接法（例如在 PageView 外套一层
/// `RawGestureDetector` 接管手势，或改用自定义 `ScrollPhysics` + 手动拖动），
/// 不要误以为已经全路径生效。
class CustomHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  CustomHorizontalDragGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  Offset? _initialPosition;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _initialPosition = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    _initialPosition = event.position;
    super.addAllowedPointerPanZoom(event);
  }

  @override
  DeviceGestureSettings get gestureSettings => _gestureSettings;
  final DeviceGestureSettings _gestureSettings = DeviceGestureSettings(
    touchSlop: _touchSlopH,
  );

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final initial = _initialPosition;
    if (initial == null) return false;
    final moved = globalDistanceMoved.abs();
    switch (pointerDeviceKind) {
      case PointerDeviceKind.mouse:
        return moved > kPrecisePointerHitSlop;
      case PointerDeviceKind.touch:
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
      case PointerDeviceKind.trackpad:
      case PointerDeviceKind.unknown:
        final offset = lastPosition.global - initial;
        return moved > _touchSlopH && offset.dx.abs() > offset.dy.abs() * 3;
    }
  }
}

/// 横向 touchSlop：设备逻辑 slop + 6（PiliPlus 默认值）。
final double _touchSlopH = _deviceTouchSlop() + 6.0;

double _deviceTouchSlop() {
  final view = PlatformDispatcher.instance.views.first;
  final physicalTouchSlop = view.gestureSettings.physicalTouchSlop;
  return physicalTouchSlop == null
      ? kTouchSlop
      : physicalTouchSlop / view.devicePixelRatio;
}
