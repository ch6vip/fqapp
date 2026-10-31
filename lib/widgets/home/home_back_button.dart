import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// 页面统一返回键：Lucide chevron_left + tooltip「返回」。
///
/// 与详情页 / 短剧详情的顶栏返回键同一几何（36×36 点击区、20dp 图标）；
/// Material 的 `BackButton` 是 arrow_back，和项目其余 Lucide 图标不搭。
/// 外层留白（AppBar 的 leading padding、leadingWidth）由页面决定。
class HomeBackButton extends StatelessWidget {
  const HomeBackButton({
    super.key,
    this.onPressed,
    this.tooltip = '返回',
    this.iconSize = 20,
    this.size = 36,
    this.color,
  });

  final VoidCallback? onPressed;
  final String tooltip;
  final double iconSize;
  final double size;

  /// 缺省取 `HomePalette.ink`，深色 / 墨水屏自动跟随。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed ?? () => Navigator.maybePop(context),
      style: IconButton.styleFrom(
        foregroundColor: color ?? palette.ink,
        fixedSize: Size.square(size),
        minimumSize: Size.square(size),
        padding: EdgeInsets.zero,
      ),
      icon: Icon(LucideIcons.chevron_left, size: iconSize),
    );
  }
}
