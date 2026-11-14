import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:material_ui/material_ui.dart';

/// 底栏滚动自动隐藏的控制器：value=true 表示当前收起。
///
/// 对齐 PiliPlus 悬浮底栏的配套行为（pages/common/common_page.dart）：由
/// [UserScrollNotification] 的拖动方向驱动——继续下滚（reverse）收起、
/// 往回滚（forward）露出，横轴通知（频道 pager、卡片横排）忽略。只监听
/// 用户拖动，甩动惯性阶段不反复翻转，方向一变即翻转，无累积阈值。
///
/// 收起/露出只做平移不改槽位高度（extendBody 下内容本来就画在 dock 下方），
/// 页面滚动位置与安全区都不因它变化。
class DockAutoHide extends ValueNotifier<bool> {
  DockAutoHide({this.disabledProbe}) : super(false);

  /// 外部短路的探针（可选）：返回 true 时 [handleUserScroll] 直接丢弃通知，
  /// [hidden] 保持不变。调用方可用它表达「平台不适合自动隐藏」（桌面鼠标
  /// 滚轮/墨水屏）。[reveal] 不走该短路：切 tab / 子路由 pop 仍会强制露出，
  /// 适合在开关翻转时把旧状态一并归位。
  final bool Function()? disabledProbe;

  bool get hidden => value;

  /// 喂入壳层 body 冒泡上来的用户拖动通知。
  void handleUserScroll(UserScrollNotification notification) {
    if (disabledProbe?.call() ?? false) return;
    if (notification.metrics.axis == Axis.horizontal) return;
    switch (notification.direction) {
      case ScrollDirection.reverse:
        value = true;
      case ScrollDirection.forward:
        value = false;
      case ScrollDirection.idle:
        break;
    }
  }

  /// 无条件露出：切 tab、回顶等场景调用——dock 收起时用户够不到它，
  /// 换页这类「明确回到入口」的动作必须把它带回来。
  void reveal() => value = false;
}

/// 把 [DockAutoHide.reveal] 挂到当前路由的 secondaryAnimation 上：
/// 子路由 pop 回本页时自动露出 dock。
///
/// 与 [VideoPlayerChrome] 同约定（不引入全局 RouteObserver），测试里裸
/// MaterialApp 也能生效。宿主在 didChangeDependencies 里 [attach]，
/// dispose 时 [detach]。
class DockRouteReveal {
  DockRouteReveal(this.hide);

  final DockAutoHide hide;
  Animation<double>? _animation;
  bool _covered = false;

  /// 从当前上下文中解析 ModalRoute.secondaryAnimation，变化时重新订阅。
  void attach(BuildContext context) {
    final next = ModalRoute.of(context)?.secondaryAnimation;
    if (identical(next, _animation)) return;
    _animation?.removeListener(_onChange);
    _animation = next;
    _animation?.addListener(_onChange);
    _covered = (next?.value ?? 0) > 0;
  }

  void _onChange() {
    final animation = _animation;
    if (animation == null) return;
    final covered = animation.value > 0;
    if (covered == _covered) return;
    // 由「被盖住」转为「回到最上」= 子路由 pop 完成；此刻 reveal 一次。
    if (!covered) hide.reveal();
    _covered = covered;
  }

  void detach() {
    _animation?.removeListener(_onChange);
    _animation = null;
    _covered = false;
  }
}

/// 按控制器状态给 dock 套一层滑入滑出。
class DockAutoHideSlide extends StatelessWidget {
  const DockAutoHideSlide({
    super.key,
    required this.hide,
    this.reduceMotion = false,
    required this.child,
  });

  final ValueListenable<bool> hide;
  final Widget child;

  /// 与系统「减弱动态效果」同等对待，直接落位。
  /// 墨水屏已通过 disabledProbe 完全禁用收起（见 DockAutoHide），正常流程下
  /// hidden 始终为 false；reduceMotion 仅覆盖「进入 eink 时 reveal 旧 hidden
  /// 态」这一过渡帧，让 offset 从 (0,1)→(0,0) 即时到位而不跑 500ms 平移。
  final bool reduceMotion;

  /// 与 PiliPlus 同参：500ms、easeInOutCubicEmphasized
  /// （main/view.dart 的 AnimatedSlide）。
  static const Duration slideDuration = Duration(milliseconds: 500);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: hide,
      builder: (context, hidden, child) {
        // AnimatedSlide 只平移绘制/命中区，Semantics 节点仍然挂在语义树里；
        // TalkBack/VoiceOver 用户可读到并激活「看不见」的 tab 按钮，产生无
        // 视觉来源的页面切换。hidden 时一并屏蔽语义与指针命中，只保留布局
        // 槽位（extendBody 下 dock 槽位高度不变）。
        // 注：Key 假设 DockAutoHideSlide 全局单例（RootShell）；若日后出现
        // 嵌套多实例（如桌面分栏），需改为 instance-scoped key。
        return ExcludeSemantics(
          key: const ValueKey('dock-auto-hide-exclude'),
          excluding: hidden,
          child: IgnorePointer(
            key: const ValueKey('dock-auto-hide-ignore'),
            ignoring: hidden,
            child: AnimatedSlide(
              offset: Offset(0, hidden ? 1 : 0),
              // 系统「减弱动态效果」或墨水屏下直接落位，不跑 500ms 滑出。
              duration: MediaQuery.disableAnimationsOf(context) || reduceMotion
                  ? Duration.zero
                  : slideDuration,
              curve: Curves.easeInOutCubicEmphasized,
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}
