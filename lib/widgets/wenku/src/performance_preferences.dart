import 'package:flutter/widgets.dart';

enum PerformanceEffect {
  glass('performanceGlass', '液态玻璃折射', '关闭后使用奶白色轻量底板'),
  blur('performanceBlur', '背景模糊', '玻璃底板和封面背景的实时模糊'),
  edgeBlur('performanceEdgeBlur', '滚动边缘模糊', '页面顶部、底部和阅读器边缘的渐变模糊'),
  motion('performanceMotion', '过渡动效', '页面切换、菜单伸展和内容切入动效'),
  animatedIcons(
    'performanceAnimatedIcons',
    '动态图标',
    '图标入场、点按与状态变化的局部动作，可独立于过渡动效开启',
  ),
  shelf3d('performanceShelf3d', '立体书架', '关闭后改为平面封面轮播，保留书架浏览设置');

  const PerformanceEffect(this.preferenceKey, this.label, this.description);
  final String preferenceKey, label, description;
}

/// The lightweight preset is separate from the normal appearance preferences.
/// Switching it off restores those preferences without rewriting them.
@immutable
class PerformancePreferences {
  const PerformancePreferences({this.enabled = false, this.effects = const {}});
  final bool enabled;
  final Set<PerformanceEffect> effects;

  bool allows(PerformanceEffect effect) => !enabled || effects.contains(effect);
  bool get glass => allows(PerformanceEffect.glass);
  bool get blur => allows(PerformanceEffect.blur);
  bool get edgeBlur => allows(PerformanceEffect.edgeBlur);
  bool get motion => allows(PerformanceEffect.motion);
  bool get animatedIcons => allows(PerformanceEffect.animatedIcons);
  bool get shelf3d => allows(PerformanceEffect.shelf3d);
  bool get needsRuntimeEffects => glass || edgeBlur;

  @override
  bool operator ==(Object other) =>
      other is PerformancePreferences &&
      other.enabled == enabled &&
      other.effects.length == effects.length &&
      other.effects.containsAll(effects);
  @override
  int get hashCode => Object.hash(enabled, Object.hashAllUnordered(effects));
}

class PerformanceScope extends InheritedWidget {
  const PerformanceScope({
    super.key,
    required this.preferences,
    this.explicitReduceMotion,
    required super.child,
  });
  final PerformancePreferences preferences;

  /// The app/system accessibility choice before a performance preset makes
  /// MediaQuery.disableAnimations true for page transitions. Null preserves
  /// the existing MediaQuery contract for isolated widgets and other hosts.
  final bool? explicitReduceMotion;

  static bool reduceMotionOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PerformanceScope>()
          ?.explicitReduceMotion ??
      MediaQuery.disableAnimationsOf(context);
  static PerformancePreferences of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PerformanceScope>()
          ?.preferences ??
      const PerformancePreferences();
  @override
  bool updateShouldNotify(PerformanceScope oldWidget) =>
      preferences != oldWidget.preferences ||
      explicitReduceMotion != oldWidget.explicitReduceMotion;
}
