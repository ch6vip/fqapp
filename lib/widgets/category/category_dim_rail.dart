import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 左侧维度栏宽度（官方 88dp 定值）。
const double categoryDimRailWidth = 88;

/// 左侧 88dp 维度栏：项高 50dp、14sp 居中；选中橙、未选黑（真机取证，
/// 官方无指示条、无选中底色——`TabPageLeftCell` 只有颜色分支）。
/// 墨水屏下两档都退化为黑色，靠选中加粗 + 左侧 2dp 黑指示条保留层级
/// （否则选中维度完全不可见）。
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
        color: palette.soft,
        child: ListView.builder(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
          itemCount: titles.length,
          itemBuilder: (context, index) {
            final selected = index == selectedIndex;
            final einkSelected = palette.eink && selected;
            return GestureDetector(
              key: ValueKey('category_dim_$index'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(index),
              child: Container(
                height: 50,
                alignment: Alignment.center,
                decoration: einkSelected ? _einkSelectedBorder : null,
                child: Text(
                  titles[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    // 墨屏黑字两档同色，选中只靠字重 + 指示条区分。
                    fontWeight: einkSelected ? FontWeight.w700 : null,
                    color: selected
                        ? (palette.eink ? palette.ink : HomePalette.accent)
                        : palette.ink,
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

const _einkSelectedBorder = BoxDecoration(
  border: Border(left: BorderSide(color: Colors.black, width: 2)),
);
