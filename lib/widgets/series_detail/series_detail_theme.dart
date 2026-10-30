import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 短剧详情页的配色换算。
///
/// 页面跟随应用主题（浅色 / 深色 / OLED / 墨水屏），颜色一律从
/// [HomePalette] 取。剧集自己的 `series_color_hex` 只留作顶部一条淡色带，
/// 见 [seriesBandTint]。

/// 主行动钮与当前集描边用强调色。
///
/// 墨水屏没有彩色：强调色退化为纯黑，黑白对比就是全部层级。
Color seriesAccent(HomePalette palette) =>
    palette.eink ? palette.ink : HomePalette.accent;

/// 强调色块上的文字 / 图标色。
Color seriesOnAccent(HomePalette palette) =>
    palette.eink ? palette.canvas : Colors.white;

/// 剧集主色在画布上的淡色带（已按透明度混合的感觉给值）。
///
/// 只接受六位 hex；缺失、非法或灰色系（饱和度 < 0.05）都不出色带——
/// 官方对灰色系也是回退，只是旧实现回退成一整块深灰背景，现在回退成
/// 普通画布。墨水屏整页纯黑白，同样不出色带。
Color? seriesBandTint(String hex, HomePalette palette) {
  if (palette.eink) return null;
  final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
  if (match == null) return null;
  final color = Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
  if (HSLColor.fromColor(color).saturation < 0.05) return null;
  // 深色下同一条色相的色带要更实一点才看得出来，但仍远低于正文对比度。
  return color.withValues(alpha: palette.dark ? 0.16 : 0.10);
}
