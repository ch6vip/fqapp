import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'search_source_switch.dart';

/// 搜索页的范围条：分类页签 + 右缘渐隐 + 来源切换。
///
/// 这是固定顶栏的第二层（第一层是 AppBar 里的搜索框）。分类页签沿用原来的
/// [ChoiceChip] 样式，横向滚动；右缘 24dp 渐隐后接一根 1×20 的竖线，再往右
/// 是固定的「番茄 | 书旗」两段切换。选中书旗时分类页签降到 0.4 透明度并停止
/// 响应点击，退出书旗只能点「番茄」。
class SearchScopeBar extends StatelessWidget {
  static const double fadeWidth = 24;

  final List<String> categories;
  final int selectedIndex;
  final bool shuqi;
  final ValueChanged<int> onSelectCategory;
  final ValueChanged<bool> onSelectSource;

  const SearchScopeBar({
    super.key,
    required this.categories,
    required this.selectedIndex,
    required this.shuqi,
    required this.onSelectCategory,
    required this.onSelectSource,
  });

  /// 范围条高度：48dp 起，随字体缩放长大（与首页顶栏同一口径）。
  static double heightFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final scale = scaler.scale(13) / 13;
    return math.max(48, 48 + (scale - 1).clamp(0.0, 2.0) * 16);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final height = heightFor(context);
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(child: _categories(palette)),
          Container(width: 1, height: 20, color: palette.line),
          Padding(
            padding: const EdgeInsets.only(left: 12, right: homeGutter),
            child: SearchSourceSwitch(
              shuqi: shuqi,
              tapHeight: height,
              onChanged: onSelectSource,
            ),
          ),
        ],
      ),
    );
  }

  Widget _categories(HomePalette palette) {
    final list = ListView(
      key: const Key('search-category-tabs'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(
        left: homeGutter - 4,
        right: homeGutter - 8,
      ),
      children: [
        for (var i = 0; i < categories.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(child: _chip(palette, i)),
          ),
      ],
    );
    return IgnorePointer(
      ignoring: shuqi,
      child: Opacity(
        opacity: shuqi ? 0.4 : 1,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            // 最后 24dp 渐隐；内容宽度不足 24dp 时直接保持不透明。
            final fadeStart = bounds.width > fadeWidth
                ? (bounds.width - fadeWidth) / bounds.width
                : 1.0;
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [Colors.black, Colors.black, Colors.transparent],
              stops: [0, fadeStart, 1],
            ).createShader(bounds);
          },
          child: list,
        ),
      ),
    );
  }

  Widget _chip(HomePalette palette, int index) {
    final category = categories[index];
    final isSelected = !shuqi && index == selectedIndex;
    return ChoiceChip(
      label: Text(category),
      selected: isSelected,
      onSelected: (_) => onSelectCategory(index),
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
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        color: isSelected ? palette.canvas : palette.ink,
      ),
    );
  }
}
