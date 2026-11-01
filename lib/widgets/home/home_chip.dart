import 'package:flutter/material.dart';

import 'home_design.dart';

/// 首页 / 搜索 / 分类共用的胶囊筛选 chip（替换 Material 默认 ChoiceChip）。
///
/// 规格取自搜索页的分类条：soft 底、ink 实心选中、StadiumBorder、无勾、
/// 13sp。Material 默认 chip 在墨水屏下选中态用 `secondaryContainer`（白）
/// 会和未选中态撞色，选中态直接消失；这里显式给出墨水屏分支：选中 =
/// 黑底白字，未选中 = 白底黑字 + 1px 黑描边，保证可区分。
///
/// 视觉高度 32dp，触控高度不小于 48dp（InkWell 铺满整块可点区域）。
class HomeChip extends StatelessWidget {
  const HomeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticLabel,
  });

  /// 视觉胶囊高度；触控高度见 [minTapTarget]。
  static const double height = 32;

  /// 触控区域最小高度（比视觉高度多出的部分是透明留白）。
  static const double minTapTarget = 48;

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // eink 下 palette.ink = 黑、palette.canvas = 白，下面两行自然得到
    // 黑底白字 / 白底黑字；非 eink 沿用搜索页的 soft → ink 选中。
    final background = selected ? palette.ink : palette.soft;
    final foreground = selected ? palette.canvas : palette.ink;
    final side = palette.eink && !selected
        ? const BorderSide(color: Colors.black)
        : BorderSide.none;
    return Semantics(
      label: semanticLabel,
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: minTapTarget),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Container(
                height: height,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                // 宽度必须收缩到文字宽度：Wrap / Center 给的是有限最大宽，
                // 带 alignment 的 Container 会撑满整行，胶囊就变成整条。
                decoration: ShapeDecoration(
                  color: background,
                  shape: StadiumBorder(side: side),
                ),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
