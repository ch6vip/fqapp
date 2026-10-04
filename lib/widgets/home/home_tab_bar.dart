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
  HomeCategory('漫剧', LucideIcons.film),
  HomeCategory('漫画', LucideIcons.image),
  HomeCategory('听书', LucideIcons.headphones),
];

class HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final double extent;
  final bool dark;

  HomeTabBarDelegate({
    required this.selectedIndex,
    required this.onSelect,
    this.extent = 54,
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
        : const Duration(milliseconds: 200);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(
          bottom: BorderSide(
            color: palette.line.withValues(alpha: 0.5),
            width: 0.6,
          ),
        ),
      ),
      child: Center(
        child: SizedBox(
          height: 38,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: homeCategories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
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
                    borderRadius: BorderRadius.circular(19),
                    child: AnimatedContainer(
                      duration: duration,
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? HomePalette.accent
                            : palette.soft.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(19),
                        boxShadow: selected
                            ? [
                                BoxShadow(
                                  color: HomePalette.accent.withValues(alpha: 0.28),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            category.icon,
                            size: 14,
                            color: selected ? Colors.white : palette.muted,
                          ),
                          const SizedBox(width: 5),
                          AnimatedDefaultTextStyle(
                            duration: duration,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w500,
                              color: selected ? Colors.white : palette.ink,
                              letterSpacing: 0.2,
                            ),
                            child: Text(category.label),
                          ),
                        ],
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
      dark != oldDelegate.dark;
}
