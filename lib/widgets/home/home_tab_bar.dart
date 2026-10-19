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

/// Pinned category navigation.
///
/// Text and a short accent underline replace the previous row of filled pills.
/// The result is quieter, easier to scan and much closer to the editorial
/// rhythm of the rest of the page.
class HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final double extent;
  final bool dark;
  final bool eink;

  HomeTabBarDelegate({
    required this.selectedIndex,
    required this.onSelect,
    this.extent = 52,
    this.dark = false,
    this.eink = false,
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
    final accent = palette.eink ? Colors.black : HomePalette.accent;

    return Container(
      color: palette.canvas,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: palette.hairline, width: 0.8),
          ),
        ),
        child: Center(
          child: SizedBox(
            height: extent,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              scrollDirection: Axis.horizontal,
              itemCount: homeCategories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
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
                      borderRadius: BorderRadius.circular(10),
                      splashColor: accent.withValues(alpha: 0.07),
                      highlightColor: Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedDefaultTextStyle(
                              duration: duration,
                              curve: Curves.easeOutCubic,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.2,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                letterSpacing: selected ? 0.1 : 0.2,
                                color: selected ? accent : palette.muted,
                              ),
                              child: Text(
                                category.label,
                                textScaler: MediaQuery.textScalerOf(
                                  context,
                                ).clamp(maxScaleFactor: 1.5),
                              ),
                            ),
                            const SizedBox(height: 6),
                            AnimatedContainer(
                              duration: duration,
                              curve: Curves.easeOutCubic,
                              width: selected ? 16 : 0,
                              height: 2.5,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(2),
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
          ),
        ),
      ),
    );
  }

  /// Brightness and e-ink affect the painted palette even without a tab change.
  @override
  bool shouldRebuild(HomeTabBarDelegate oldDelegate) =>
      selectedIndex != oldDelegate.selectedIndex ||
      extent != oldDelegate.extent ||
      onSelect != oldDelegate.onSelect ||
      dark != oldDelegate.dark ||
      eink != oldDelegate.eink;
}
