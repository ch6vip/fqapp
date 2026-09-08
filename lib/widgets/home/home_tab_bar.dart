import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

class HomeCategory {
  final String label;
  final IconData icon;

  const HomeCategory(this.label, this.icon);
}

const homeCategories = [
  HomeCategory('推荐', LucideIcons.sparkles),
  HomeCategory('小说', LucideIcons.book_open),
  HomeCategory('短剧', LucideIcons.clapperboard),
  HomeCategory('漫画', LucideIcons.image),
  HomeCategory('听书', LucideIcons.headphones),
];

class HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final double extent;

  HomeTabBarDelegate({
    required this.selectedIndex,
    required this.onSelect,
    this.extent = 60,
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
        : const Duration(milliseconds: 220);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(
          bottom: BorderSide(color: palette.line.withValues(alpha: 0.65)),
        ),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        scrollDirection: Axis.horizontal,
        itemCount: homeCategories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 3),
        itemBuilder: (context, index) {
          final selected = index == selectedIndex;
          final category = homeCategories[index];
          return Semantics(
            selected: selected,
            button: true,
            label: category.label,
            excludeSemantics: true,
            onTap: () => onSelect(index),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('home_category_$index'),
                onTap: () => onSelect(index),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            category.icon,
                            size: 15,
                            color: selected
                                ? HomePalette.accent
                                : palette.muted,
                          ),
                          const SizedBox(width: 5),
                          AnimatedDefaultTextStyle(
                            duration: duration,
                            style: Theme.of(context).textTheme.labelLarge!
                                .copyWith(
                                  fontSize: 16,
                                  fontWeight: selected
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: selected ? palette.ink : palette.muted,
                                ),
                            child: Text(category.label),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      AnimatedContainer(
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        height: 3,
                        width: selected ? 22 : 6,
                        decoration: BoxDecoration(
                          color: selected
                              ? HomePalette.accent
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  bool shouldRebuild(HomeTabBarDelegate oldDelegate) =>
      selectedIndex != oldDelegate.selectedIndex ||
      extent != oldDelegate.extent ||
      onSelect != oldDelegate.onSelect;
}
