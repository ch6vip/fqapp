import 'package:flutter/material.dart';

import '../../models/rank.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart' show homeGutter;

/// 榜单层级：与首页榜单块同一套下划线文字 tab（13sp，选中墨色加粗 +
/// 16×2 短线），不再用橙底白字胶囊 —— 胶囊和下面的分类筛选是两套
/// 选中态，页面看起来像两种设计拼在一起。
///
/// 文字本身只有约 23dp 高；可点区域交给 [HomePressable] 的 InkWell 补到
/// 44dp 高、48dp 宽，同时获得焦点遍历与键盘 Enter/Space 激活。
class RankBoardTabs extends StatelessWidget {
  const RankBoardTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<RankTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 44,
      child: ListView.separated(
        key: const Key('rank_tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: homeGutter),
        itemCount: tabs.length,
        separatorBuilder: (context, _) => const SizedBox(width: 20),
        itemBuilder: (context, index) {
          final tab = tabs[index];
          final selected = index == selectedIndex;
          return Center(
            child: Semantics(
              selected: selected,
              button: true,
              label: '查看${tab.name}',
              excludeSemantics: true,
              onTap: () => onSelect(index),
              child: HomePressable(
                key: ValueKey('rank_tab_${tab.algo}'),
                onTap: () => onSelect(index),
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 44,
                  ),
                  child: Center(
                    widthFactor: 1,
                    heightFactor: 1,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Text(
                            tab.name,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.2,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected ? palette.ink : palette.muted,
                            ),
                          ),
                        ),
                        Container(
                          width: 16,
                          height: 2,
                          decoration: BoxDecoration(
                            color: selected ? palette.ink : Colors.transparent,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
