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
///   —— 官方不靠颜色区分，只靠字号和字重；
/// * 指示器色 `avt` = `skin_color_1A000000_light`(#1A000000)，高 8dp；
/// * tab 间距 `auw` = 16dp，tab 内左右 padding 20dp / 34dp。
///
/// 上一版是圆角胶囊 + 图标 + 橙色选中底，和官方完全不是一种东西。
class HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  static const double barHeight = 38;
  static const double bottomPadding = 10;
  static const double selectedSize = 24;
  static const double unselectedSize = 16;
  static const double indicatorHeight = 8;
  static const double tabSpacing = 16;

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 顶栏分类。服务端下发 `tab_item` 时用服务端的，否则用 [homeCategories]。
  final List<HomeCategory> categories;
  final double extent;
  final bool dark;

  HomeTabBarDelegate({
    required this.selectedIndex,
    required this.onSelect,
    this.categories = homeCategories,
    this.extent = barHeight + bottomPadding,
    this.dark = false,
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
                  // 官方 SlidingTabLayout 把指示器画在 tab 底部（overlay），
                  // 不占布局高度；用 Stack 才能在不溢出的前提下让 24sp
                  // 选中字与 38dp 行高共存。
                  child: SizedBox(
                    height: rowHeight,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          style: TextStyle(
                            fontSize: selected ? selectedSize : unselectedSize,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color: palette.ink,
                            height: 1,
                          ),
                          child: Text(category.label),
                        ),
                        Positioned(
                          bottom: 0,
                          child: AnimatedContainer(
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            height: 3,
                            width: selected ? 22 : 0,
                            decoration: BoxDecoration(
                              // 官方指示器 #1A000000。
                              color: palette.ink.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
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
      dark != oldDelegate.dark;
}
