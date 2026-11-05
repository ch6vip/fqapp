import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'search_source_switch.dart';

/// Underlined categories and a separate source switch. Source selection keeps
/// its existing behavior; Shuqi disables both touch and semantic category actions.
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
    return Container(
      height: height,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          Expanded(child: _categories(palette)),
          Container(width: 1, height: 20, color: palette.line),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: homeGutter),
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
      padding: const EdgeInsets.only(left: homeGutter - 8, right: homeGutter),
      children: [
        for (var i = 0; i < categories.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _tab(palette, i),
          ),
      ],
    );
    return IgnorePointer(
      ignoring: shuqi,
      child: Opacity(
        opacity: shuqi && !palette.eink ? 0.4 : 1,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            // 最后 24dp 渐隐；内容宽度不足 24dp 时直接保持不透明。
            final fadeStart = !palette.eink && bounds.width > fadeWidth
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

  Widget _tab(HomePalette palette, int index) {
    final category = categories[index];
    final isSelected = !shuqi && index == selectedIndex;
    return Semantics(
      button: true,
      selected: isSelected,
      enabled: !shuqi,
      child: InkWell(
        onTap: shuqi ? null : () => onSelectCategory(index),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? palette.ink : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            category,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
              color: isSelected ? palette.ink : palette.muted,
            ),
          ),
        ),
      ),
    );
  }
}
