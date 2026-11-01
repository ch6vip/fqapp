import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 漫画阅读器 chrome（顶栏 / 底栏）共用的图标按钮。
///
/// 视觉上是 20dp Lucide 图标 + 44dp 点击区，点按走 [HomePressable] 的弹簧
/// 缩放；颜色取 [HomePalette]，墨水屏自动黑图标 / 白底。禁用时只降透明度，
/// 不响应点按。
class ComicChromeButton extends StatelessWidget {
  const ComicChromeButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 44,
    this.iconSize = 20,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final enabled = onPressed != null;
    final glyph = Icon(
      icon,
      size: iconSize,
      color: enabled ? palette.ink : palette.muted.withValues(alpha: 0.4),
    );
    final box = SizedBox(
      width: size,
      height: size,
      child: Center(child: glyph),
    );
    return Tooltip(
      message: tooltip,
      child: enabled
          ? HomePressable(
              onTap: onPressed!,
              semanticLabel: tooltip,
              borderRadius: BorderRadius.circular(12),
              child: box,
            )
          : box,
    );
  }
}
