import 'package:flutter/material.dart';

import 'home/home_design.dart';

/// 离线缓存面板里的「分段选择器」。
///
/// 面板本身按 30 集一段分页，段数一多就出问题：34 段铺成一行 chip 是一条
/// 几千像素的长条，选中项还常常滚在屏幕外 —— 打开面板根本看不出自己在哪
/// 一段，也就定位不到要缓存的集。所以段数少时铺 chip（一眼可选），段数多
/// 时换成「上一段 / 下拉 / 下一段」，任何集数都能直接跳。
class DramaGroupPicker extends StatelessWidget {
  const DramaGroupPicker({
    super.key,
    required this.groupCount,
    required this.group,
    required this.total,
    required this.rangeOf,
    required this.onSelected,
    this.maxChipGroups = 8,
  });

  /// 一共有多少段。
  final int groupCount;

  /// 当前选中的段（0 起）。
  final int group;

  /// 这部剧总集数，只用于「共 N 集」的说明文字。
  final int total;

  /// 第 index 段的集号区间（闭区间，1 起）。
  final (int, int) Function(int index) rangeOf;

  final ValueChanged<int> onSelected;

  /// 超过这个段数就不铺 chip 了。
  final int maxChipGroups;

  @override
  Widget build(BuildContext context) {
    if (groupCount <= 1) return const SizedBox.shrink();
    final palette = HomePalette.of(context);
    if (groupCount <= maxChipGroups) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (var index = 0; index < groupCount; index++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('download-group-$index'),
                  label: Text(_chipLabel(index)),
                  selected: index == group,
                  onSelected: (_) => onSelected(index),
                ),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('download-group-prev'),
            tooltip: '上一段',
            onPressed: group > 0 ? () => onSelected(group - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const ValueKey('download-group-picker'),
                value: group,
                isExpanded: true,
                borderRadius: BorderRadius.circular(12),
                style: TextStyle(fontSize: 13, color: palette.ink),
                onChanged: (value) {
                  if (value != null) onSelected(value);
                },
                items: [
                  for (var index = 0; index < groupCount; index++)
                    DropdownMenuItem<int>(
                      key: ValueKey('download-group-item-$index'),
                      value: index,
                      child: Text(_rangeLabel(index)),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('download-group-next'),
            tooltip: '下一段',
            onPressed: group < groupCount - 1
                ? () => onSelected(group + 1)
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  String _chipLabel(int index) {
    final (start, end) = rangeOf(index);
    return '$start-$end集';
  }

  String _rangeLabel(int index) {
    final (start, end) = rangeOf(index);
    return '第 $start-$end 集 / 共 $total 集';
  }
}
