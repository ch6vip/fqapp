import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../services/app_theme.dart';

/// The home surface keeps its warm paper / tomato identity in both themes.
class HomePalette {
  static const accent = Color(0xFFEF5038);
  static const accentStrong = Color(0xFFC73D29);
  final bool dark;

  /// #15/#9：墨水屏时所有纸面 / 文字 / 线条退化为纯黑白。accent 静态常量
  /// 仍为品牌橙（93 处直接引用），本轮不全量替换，见收尾未验项。
  final bool eink;

  /// OLED 纯黑：画布用纯黑省电，卡片 / 弹层保持近黑，靠描边维持层次。
  /// 只在深色外观下生效（见 [oledActive]），这里的 `&& dark` 是二重保险。
  final bool oled;

  const HomePalette(this.dark, {this.eink = false, this.oled = false});

  factory HomePalette.of(BuildContext context) => HomePalette(
    Theme.of(context).brightness == Brightness.dark,
    eink: einkModeNotifier.value,
    oled: oledActive(),
  );

  /// 官方书城底色 `skin_color_F6F6F6_light`（#F6F6F6），见 res/layout/alx.xml
  /// 根 FrameLayout。此前是暖纸色 #FCFAF7，与官方不一致。
  ///
  /// OLED 纯黑只在深色下多出一档：画布给纯黑省电，卡片 / 弹层退回近黑。
  /// 写成逐层判断而非嵌套三元，三个候选一眼能数清。
  Color get canvas {
    if (eink) return Colors.white;
    if (oled && dark) return Colors.black;
    return dark ? const Color(0xFF151517) : const Color(0xFFF6F6F6);
  }

  Color get surface {
    if (eink) return Colors.white;
    if (oled && dark) return const Color(0xFF0C0C0E);
    return dark ? const Color(0xFF242427) : Colors.white;
  }

  Color get ink =>
      eink ? Colors.black : (dark ? const Color(0xFFF5F1EB) : const Color(0xFF262522));
  Color get muted =>
      eink ? Colors.black : (dark ? const Color(0xFFA7A39E) : const Color(0xFF706C66));
  Color get accentText => eink ? Colors.black : (dark ? accent : accentStrong);

  Color get soft {
    if (eink) return Colors.white;
    if (oled && dark) return const Color(0xFF141417);
    return dark ? const Color(0xFF202023) : const Color(0xFFF1EEE9);
  }

  Color get line {
    if (eink) return Colors.black;
    if (oled && dark) return const Color(0xFF2E2E34);
    return dark ? const Color(0xFF333336) : const Color(0xFFE8E4DE);
  }

  /// 官方搜索框底色 `skin_color_search_bar_bg_v2_light` = #FFFFFF
  /// （res/values/colors.xml），暗色下用 surface。
  Color get searchBar => eink
      ? Colors.white
      : (dark ? const Color(0xFF2A2A2E) : const Color(0xFFFFFFFF));

  /// 官方搜索框提示字色 `skin_color_search_bar_text_v3_light` = #66000000。
  Color get searchBarText => eink
      ? Colors.black
      : (dark ? const Color(0xFF8E8A85) : const Color(0x66000000));

  /// 官方正文次级色 `skin_color_gray_40_light` = **#66000000**（60% 黑）。
  ///
  /// 官方信息层级是「纯黑标题 + 60% 黑正文」两档；此前实现用的是
  /// `#262522` + `#706C66` 两档实色灰，整体偏灰，与官方观感不同。
  /// 暗色下按同一「次级」语义给 60% 白。
  Color get body => eink
      ? Colors.black
      : (dark ? const Color(0x99FFFFFF) : const Color(0x66000000));
}

/// 底部弹层（bottom sheet）的底色。
///
/// 深色 / OLED 下换成比画布高一档的 surface：barrier 的黑色叠在纯黑画布
/// 上不会让页面变暗，弹层若仍取 canvas 就和页面连成一片，看不出上缘；
/// 浅色仍用原来的画布色，弹层靠 barrier 变暗区分。
Color homeSheetColor(HomePalette palette) =>
    palette.dark ? palette.surface : palette.canvas;

/// 弹层里成组的卡片：深色下比 [homeSheetColor] 再错一档（字段色），
/// 浅色仍是白卡。
Color homeSheetCardColor(HomePalette palette) =>
    palette.dark ? palette.soft : palette.surface;

/// 弹层上缘的一圈发丝线：OLED 下画布与浮层都是近黑，没有它边界仍不明显。
///
/// 只给深色 / OLED：浅色弹层与奶白画布本来就靠 barrier 区分，多一圈线反而
/// 突兀；墨水屏 `line` 是纯黑，下发了就会在弹层四周描出一圈黑边。
RoundedRectangleBorder homeSheetShape(HomePalette palette, {double top = 24}) =>
    RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(top)),
      side: palette.dark
          ? BorderSide(color: palette.line.withValues(alpha: 0.8), width: 0.8)
          : BorderSide.none,
    );

/// Pointer, keyboard and accessibility activation share the same action.
/// The spring settles after interaction; no idle animation is scheduled.
class HomePressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final String? semanticLabel;

  const HomePressable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.semanticLabel,
  });

  @override
  State<HomePressable> createState() => _HomePressableState();
}

class _HomePressableState extends State<HomePressable>
    with SingleTickerProviderStateMixin {
  late final _scale = AnimationController.unbounded(vsync: this, value: 1);

  void _press(bool pressed) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _scale.stop();
      _scale.value = 1;
      return;
    }
    _scale.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 30),
        _scale.value,
        pressed ? 0.972 : 1,
        0,
      ),
    );
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _scale,
    builder: (context, child) =>
        Transform.scale(scale: _scale.value, child: child),
    child: Semantics(
      label: widget.semanticLabel,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          borderRadius: widget.borderRadius,
          splashColor: HomePalette.accent.withValues(alpha: 0.08),
          highlightColor: Colors.transparent,
          child: widget.child,
        ),
      ),
    ),
  );
}

/// Fades and lifts a newly arrived child into place.
///
/// The fade costs an [Opacity] layer for as long as it runs, and a sliver
/// disposes the children that leave its cache extent, so a child that is
/// re-mounted by scrolling back up the feed must opt out ([animate] false) or
/// every scroll past the first screenful replays a layer per card.
class HomeEntrance extends StatelessWidget {
  final int index;
  final bool animate;
  final Widget child;

  const HomeEntrance({
    super.key,
    this.index = 0,
    this.animate = true,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!animate || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + index.clamp(0, 5) * 45),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: 0.5 + value * 0.5,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}
