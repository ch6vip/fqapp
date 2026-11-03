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

/// Fixed above the swipeable feed; each label reserves its selected width.
class HomeTabBar extends StatelessWidget {
  static const double barHeight = 40;
  static const double bottomPadding = 6;
  static const double selectedSize = 17;
  static const double unselectedSize = 15;
  static const double tabSpacing = 8;
  static const double labelPadding = 6;
  static const double sidePadding = 16;
  static const double maxExtraSpacing = 12;

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
    final scaler = MediaQuery.textScalerOf(context);
    final widths = <double>[];
    var rowHeight = barHeight;
    for (final category in categories) {
      final painter = TextPainter(
        text: TextSpan(text: category.label, style: _labelStyle(true, palette)),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widths.add(painter.width + labelPadding * 2);
      if (painter.height + 20 > rowHeight) rowHeight = painter.height + 20;
      painter.dispose();
    }

    return DecoratedBox(
      decoration: BoxDecoration(color: palette.canvas),
      child: Padding(
        padding: const EdgeInsets.only(bottom: bottomPadding),
        child: SizedBox(
          height: rowHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gap = _gapWidth(constraints.maxWidth, widths);
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: sidePadding),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < categories.length; index++) ...[
                      if (index > 0) SizedBox(width: gap),
                      _tab(index, widths[index], rowHeight, duration, palette),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  double _gapWidth(double availableWidth, List<double> widths) {
    final gaps = categories.length - 1;
    if (gaps <= 0 || !availableWidth.isFinite) return tabSpacing;
    final contentWidth = widths.fold(0.0, (sum, width) => sum + width);
    // Fill phone widths without spreading the six labels across a desktop.
    final spare =
        availableWidth - 2 * sidePadding - contentWidth - gaps * tabSpacing;
    if (spare <= 0) return tabSpacing;
    return tabSpacing + (spare / gaps).clamp(0.0, maxExtraSpacing);
  }

  TextStyle _labelStyle(bool selected, HomePalette palette) => TextStyle(
    fontSize: selected ? selectedSize : unselectedSize,
    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    color: selected ? palette.ink : palette.muted,
    height: 1,
  );

  Widget _tab(
    int index,
    double width,
    double rowHeight,
    Duration duration,
    HomePalette palette,
  ) {
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
        child: SizedBox(
          height: rowHeight,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            width: width,
            decoration: BoxDecoration(
              color: selected && !palette.eink
                  ? palette.ink.withValues(alpha: palette.dark ? 0.10 : 0.055)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected && palette.eink
                    ? palette.ink
                    : Colors.transparent,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  style: _labelStyle(selected, palette),
                  child: Text(category.label, maxLines: 1),
                ),
                const SizedBox(height: 5),
                AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  width: 16,
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: selected ? palette.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
