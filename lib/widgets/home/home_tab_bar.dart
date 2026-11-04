import 'package:flutter/material.dart';

import 'home_archive.dart';
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

/// 分类条：编号 + 名称，选中项加粗并在分隔线上压一条 2dp 实线。
///
/// 编号 00–05 与 [homeCategories] 一一对应，只是顺序标识。整条固定，
/// 不随下面的内容滚动；只有这一条自身可以横滑。
class HomeTabBar extends StatelessWidget {
  static const double sidePadding = 16;
  static const double tabSpacing = 22;
  static const double selectedSize = 15;
  static const double unselectedSize = 15;

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<HomeCategory> categories;

  const HomeTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    this.categories = homeCategories,
  });

  @override
  Widget build(BuildContext context) {
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
      button: true,
      label: category.label,
      excludeSemantics: true,
      onTap: () => onSelect(index),
      child: GestureDetector(
        key: ValueKey('home_category_$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(index),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HomeCode(
                '${index < 10 ? '0' : ''}$index',
                size: 8,
                color: palette.muted,
              ),
              const SizedBox(height: 3),
              // Stack 让下划线跟住标签宽度：这一列在横向滚动里是无限宽，
              // 不能用 double.infinity 撑线。
              Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AnimatedDefaultTextStyle(
                      duration: duration,
                      curve: Curves.easeOutCubic,
                      style: TextStyle(
                        fontSize: selected ? selectedSize : unselectedSize,
                        height: 1.1,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
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
            ],
          ),
        ),
      ),
    );
  }
}
