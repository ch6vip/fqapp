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

  const HomePalette(this.dark, {this.eink = false});

  factory HomePalette.of(BuildContext context) => HomePalette(
    Theme.of(context).brightness == Brightness.dark,
    eink: einkModeNotifier.value,
  );

  /// 官方书城底色 `skin_color_F6F6F6_light`（#F6F6F6），见 res/layout/alx.xml
  /// 根 FrameLayout。此前是暖纸色 #FCFAF7，与官方不一致。
  Color get canvas => eink
      ? Colors.white
      : (dark ? const Color(0xFF151517) : const Color(0xFFF6F6F6));
  Color get surface =>
      eink ? Colors.white : (dark ? const Color(0xFF242427) : Colors.white);
  Color get ink =>
      eink ? Colors.black : (dark ? const Color(0xFFF5F1EB) : const Color(0xFF262522));
  Color get muted =>
      eink ? Colors.black : (dark ? const Color(0xFFA7A39E) : const Color(0xFF706C66));
  Color get accentText => eink ? Colors.black : (dark ? accent : accentStrong);
  Color get soft =>
      eink ? Colors.white : (dark ? const Color(0xFF202023) : const Color(0xFFF1EEE9));
  Color get line =>
      eink ? Colors.black : (dark ? const Color(0xFF333336) : const Color(0xFFE8E4DE));

  /// 官方搜索框底色 `skin_color_search_bar_bg_v2_light` = #FFFFFF
  /// （res/values/colors.xml），暗色下用 surface。
  Color get searchBar => eink
      ? Colors.white
      : (dark ? const Color(0xFF2A2A2E) : const Color(0xFFFFFFFF));

  /// 官方搜索框提示字色 `skin_color_search_bar_text_v3_light` = #66000000。
  Color get searchBarText => eink
      ? Colors.black
      : (dark ? const Color(0xFF8E8A85) : const Color(0x66000000));
}

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
