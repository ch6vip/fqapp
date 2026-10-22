import 'package:flutter/material.dart';

import 'home_design.dart';

class HomeCategory {
  final String label;
  final IconData icon;

  const HomeCategory(this.label, this.icon);
}

const homeCategories = [
  HomeCategory('推荐', Icons.circle),
  HomeCategory('小说', Icons.circle),
  HomeCategory('短剧', Icons.circle),
  HomeCategory('漫剧', Icons.circle),
  HomeCategory('漫画', Icons.circle),
  HomeCategory('听书', Icons.circle),
];

/// 官方书城顶部 tab 条（`res/layout/alx.xml` 的 `SlidingTabLayout aj0`）。
///
/// 尺寸全部取自反编译布局，不是估计值：
/// * 高度 38dp，paddingBottom 10dp；
/// * paddingStart 20dp / paddingEnd 13dp；
/// * 选中字号 `av5` = 24sp，未选中字号 `avq` = 16sp；
/// * 选中色 `aui` 与未选中色 `avn` 都是 `skin_color_black_light`(#000000)
///   —— 官方不靠颜色区分，只靠字号、字重（两态都粗体）和未选中 0.4 透明度；
/// * tab 间距 `avb` = 20dp（`SlidingTabLayout.O()` 里
///   `setMargins(0, 0, this.K, 0)`，`this.K` 就是 `avb`），tab 高 `avc` = 34dp；
/// * 指示器：`aup` = 0dp（高度 0）。`onDraw` 里 `if (this.s > 0.0f)` 才绘制，
///   所以官方书城顶栏**没有下划线**。`auw` = 16dp 是宽度，高度为 0 时无效。
///
/// 上一版是圆角胶囊 + 图标 + 橙色选中底，和官方完全不是一种东西。
class HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  static const double barHeight = 38;
  // `alx.xml` 为 10dp；2026-10-24 用户拍板不对齐官方——顶栏与排行榜条
  // 的距离按视觉收紧（与区块头 margin 联动，见 _rankStripTopMargin）。
  static const double bottomPadding = 4;
  static const double selectedSize = 24;
  static const double unselectedSize = 16;
  static const double tabSpacing = 20;

  /// 未选中项的透明度 `avr`（`SlidingTabLayout.a6`，`L2048 getFloat(55, 0.4f)`）。
  static const double unselectedAlpha = 0.4;

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 顶栏分类。服务端下发 `tab_item` 时用服务端的，否则用 [homeCategories]。
  final List<HomeCategory> categories;
  final double extent;
  final bool dark;

  /// 墨水屏与 OLED 两档会换掉画布、线条和柔色，但都不改变 [dark]：OLED
  /// 只在深色下生效（深色仍是深色），墨水屏本身也是浅色外观。所以它们
  /// 必须各自单列进 [shouldRebuild]，否则切换后吸顶条会保留旧色板。
  final bool eink;
  final bool oled;

  HomeTabBarDelegate({
    required this.selectedIndex,
    required this.onSelect,
    this.categories = homeCategories,
    this.extent = barHeight + bottomPadding,
    this.dark = false,
    this.eink = false,
    this.oled = false,
  });

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final palette = HomePalette.of(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    // pinned header 的 layoutExtent 必须等于 extent，否则 Flutter 报
    // "layoutExtent exceeds paintExtent"。字号随 textScale 长大时 extent
    // 同步变大，所以这里的高度必须从 extent 反推，不能用写死的 38。
    final rowHeight = (extent - bottomPadding).clamp(barHeight, 200.0);

    return DecoratedBox(
      decoration: BoxDecoration(color: palette.canvas),
      child: Padding(
        padding: const EdgeInsets.only(bottom: bottomPadding),
        child: SizedBox(
          height: rowHeight,
          child: ListView.separated(
            padding: const EdgeInsets.only(left: 20, right: 13),
            scrollDirection: Axis.horizontal,
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: tabSpacing),
            itemBuilder: (context, index) {
              final selected = index == selectedIndex;
              final category = categories[index];
              return Semantics(
                selected: selected,
                button: true,
                label: category.label,
                excludeSemantics: true,
                onTap: () => onSelect(index),
                child: GestureDetector(
                  key: ValueKey('home_category_$index'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(index),
                  // 官方书城顶栏不画指示器：`alx.xml` 把 `aup`(指示器高度)
                  // 设成 0，`SlidingTabLayout.onDraw` 只在 `s > 0` 时绘制。
                  //
                  // 选中态只差「字号 + 透明度」：`s0()` 对每一项都调
                  // `setTypeface(a(1))`（`R5 = getInt(53, 2)` 让 `z` 恒为真），
                  // 所以两态都是粗体；未选中项再叠加 `alpha = a6` = 0.4
                  // （`avr`，`L2048 getFloat(55, 0.4f)`）。
                  child: SizedBox(
                    height: rowHeight,
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        style: TextStyle(
                          fontSize: selected ? selectedSize : unselectedSize,
                          fontWeight: FontWeight.w700,
                          color: palette.ink.withValues(
                            alpha: selected ? 1 : unselectedAlpha,
                          ),
                          height: 1,
                        ),
                        child: Text(category.label),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // Note: pinned header 必须把主题算进 shouldRebuild — 见
  // .agents/notes/implemented/bug-fix/2026-09-18-home-geometry-and-backup.md
  @override
  bool shouldRebuild(HomeTabBarDelegate oldDelegate) =>
      selectedIndex != oldDelegate.selectedIndex ||
      extent != oldDelegate.extent ||
      onSelect != oldDelegate.onSelect ||
      categories != oldDelegate.categories ||
      dark != oldDelegate.dark ||
      eink != oldDelegate.eink ||
      oled != oldDelegate.oled;
}
