import 'package:flutter/material.dart';

import '../../services/app_style_tokens.dart';
import 'classic_home_tab_bar.dart';
import 'home_design.dart';

class HomeCategory {
  final String label;

  const HomeCategory(this.label);
}

const homeCategories = [
  HomeCategory('推荐'),
  HomeCategory('小说'),
  HomeCategory('短剧'),
  HomeCategory('漫剧'),
  HomeCategory('漫画'),
  HomeCategory('听书'),
];

/// 六个媒介分类固定在顶部；保留名称和下划线，不再重复分区的编号层级。
class HomeTabBar extends StatelessWidget {
  static const double sidePadding = 16;
  static const double tabSpacing = 22;
  static const double selectedSize = 15;
  static const double unselectedSize = 15;

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<HomeCategory> categories;

  /// The live horizontal swipe progress: -1 is the previous tab, 0 the current
  /// one, 1 the next one. See [ClassicHomeTabBar.progress].
  ///
  /// **只有经典主题（[ClassicHomeTabBar]）会消费它**：档案风格的标签条是
  /// 每个标签自己带一条下划线，横滑时不做跟手位移，这里仅透传、不参与布局。
  final double? progress;

  const HomeTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    this.categories = homeCategories,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    if (AppStyleTokens.of(context).isClassic) {
      return ClassicHomeTabBar(
        selectedIndex: selectedIndex,
        onSelect: onSelect,
        categories: categories,
        progress: progress,
      );
    }
    final palette = HomePalette.of(context);
    final duration = palette.eink || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(bottom: BorderSide(color: palette.line, width: 1)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: sidePadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var index = 0; index < categories.length; index++) ...[
              if (index > 0) const SizedBox(width: tabSpacing),
              _tab(index, duration, palette),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tab(int index, Duration duration, HomePalette palette) {
    final selected = index == selectedIndex;
    final category = categories[index];
    return Semantics(
      selected: selected,
      child: HomePressable(
        key: ValueKey('home_category_$index'),
        onTap: () => onSelect(index),
        borderRadius: BorderRadius.zero,
        // Stack follows the label width inside the horizontal scroll view.
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: AnimatedDefaultTextStyle(
                duration: duration,
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  fontSize: selected ? selectedSize : unselectedSize,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? palette.ink : palette.muted,
                ),
                child: Text(category.label, maxLines: 1),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 2,
              child: AnimatedContainer(
                duration: duration,
                curve: Curves.easeOutCubic,
                color: selected ? palette.mark : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
