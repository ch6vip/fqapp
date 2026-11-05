import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 左侧维度栏宽度（官方 88dp 定值）。
const double categoryDimRailWidth = 88;

/// The selected dimension uses ink, a fine rule and a quiet surface fill.
class CategoryDimRail extends StatelessWidget {
  const CategoryDimRail({
    super.key,
    required this.titles,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<String> titles;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      width: categoryDimRailWidth,
      child: ColoredBox(
        color: palette.canvas,
        child: ListView.builder(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
          itemCount: titles.length,
          itemBuilder: (context, index) {
            final selected = index == selectedIndex;
            return Semantics(
              selected: selected,
              button: true,
              child: InkWell(
                key: ValueKey('category_dim_$index'),
                onTap: () => onSelect(index),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 50),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 14,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? palette.soft : Colors.transparent,
                    border: Border(
                      left: BorderSide(
                        color: selected ? palette.ink : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    titles[index],
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected ? palette.ink : palette.muted,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
