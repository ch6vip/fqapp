import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 搜索页的「书旗」数据源开关。
///
/// 书旗不是番茄的分类维度，所以放在筛选行而不是分类页签行；样式与分类
/// 页签保持一致。
class ShuqiSourceChip extends StatelessWidget {
  final bool selected;
  final VoidCallback onSelected;

  const ShuqiSourceChip(this.selected, this.onSelected, {super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return FilterChip(
      key: const Key('search-shuqi-source'),
      label: const Text('书旗'),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: palette.soft,
      selectedColor: palette.ink,
      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? palette.canvas : palette.ink,
      ),
    );
  }
}
