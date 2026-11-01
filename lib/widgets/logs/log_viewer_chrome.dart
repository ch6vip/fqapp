import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_chip.dart';
import '../home/home_design.dart';
import 'log_filter_sheet.dart';

/// 日志来源：应用内环形缓冲，或核心落盘文件。
enum LogSource {
  app('应用'),
  rust('核心');

  const LogSource(this.label);
  final String label;
}

/// 日志页顶部工具栏：搜索框 + 筛选入口 + 来源 / 播放诊断 / 生效筛选胶囊。
class LogToolbar extends StatelessWidget {
  const LogToolbar({
    super.key,
    required this.controller,
    required this.query,
    required this.source,
    required this.playerOnly,
    required this.filters,
    required this.onQueryChanged,
    required this.onPickFilters,
    required this.onSelectSource,
    required this.onTogglePlayerOnly,
    required this.onClearLevel,
    required this.onClearTimeWindow,
  });

  final TextEditingController controller;
  final String query;
  final LogSource source;
  final bool playerOnly;
  final LogFilterSelection filters;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onPickFilters;
  final ValueChanged<LogSource> onSelectSource;
  final ValueChanged<bool> onTogglePlayerOnly;
  final VoidCallback onClearLevel;
  final VoidCallback onClearTimeWindow;

  int get _filterCount =>
      (filters.level == null ? 0 : 1) + (filters.timeWindow == null ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
          child: Row(
            children: [
              Expanded(child: _searchField(palette)),
              const SizedBox(width: 8),
              _filterButton(palette),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: _chips()),
        ),
      ],
    );
  }

  Widget _searchField(HomePalette palette) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      // 墨水屏下 surface 与画布同为白：没有描边搜索框会整个消失。
      borderSide: palette.eink
          ? BorderSide(color: palette.line)
          : BorderSide.none,
    );
    return TextField(
      controller: controller,
      onChanged: onQueryChanged,
      style: TextStyle(color: palette.ink, fontSize: 14),
      decoration: InputDecoration(
        hintText: '搜索标签或内容',
        hintStyle: TextStyle(color: palette.searchBarText, fontSize: 14),
        filled: true,
        fillColor: palette.searchBar,
        isDense: true,
        prefixIcon: Icon(LucideIcons.search, size: 20, color: palette.muted),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                tooltip: '清除搜索',
                icon: Icon(LucideIcons.x, size: 18, color: palette.muted),
                onPressed: () {
                  controller.clear();
                  onQueryChanged('');
                },
              ),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
      ),
    );
  }

  Widget _filterButton(HomePalette palette) {
    return IconButton(
      tooltip: '筛选日志',
      onPressed: onPickFilters,
      style: IconButton.styleFrom(
        backgroundColor: palette.soft,
        foregroundColor: palette.ink,
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: palette.eink
              ? BorderSide(color: palette.line)
              : BorderSide.none,
        ),
      ),
      icon: Badge(
        isLabelVisible: _filterCount > 0,
        backgroundColor: palette.eink ? palette.ink : HomePalette.accent,
        textColor: palette.eink ? palette.canvas : Colors.white,
        label: Text('$_filterCount'),
        child: const Icon(LucideIcons.sliders_horizontal, size: 20),
      ),
    );
  }

  List<Widget> _chips() {
    return [
      for (final value in LogSource.values) ...[
        HomeChip(
          label: value.label,
          selected: source == value,
          onTap: () => onSelectSource(value),
        ),
        const SizedBox(width: 8),
      ],
      HomeChip(
        label: '播放诊断',
        selected: playerOnly,
        onTap: () => onTogglePlayerOnly(!playerOnly),
      ),
      if (filters.level case final level?) ...[
        const SizedBox(width: 8),
        HomeChip(
          label: level.label,
          selected: true,
          semanticLabel: '清除级别筛选',
          onTap: onClearLevel,
        ),
      ],
      if (filters.timeWindow case final window?) ...[
        const SizedBox(width: 8),
        HomeChip(
          label: logTimeWindowLabel(window),
          selected: true,
          semanticLabel: '清除时间筛选',
          onTap: onClearTimeWindow,
        ),
      ],
    ];
  }
}

/// 日志页底栏：条数 / 暂停状态 + 实时跟随 / 回到最新。
class LogFollowBar extends StatelessWidget {
  const LogFollowBar({
    super.key,
    required this.count,
    required this.following,
    required this.pendingCount,
    required this.onToggle,
  });

  final int count;
  final bool following;
  final int pendingCount;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.line, width: 0.6)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count 条${following ? '' : ' · 已暂停'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
          ),
          TextButton.icon(
            onPressed: onToggle,
            style: TextButton.styleFrom(foregroundColor: palette.accentText),
            icon: Icon(
              following ? LucideIcons.pause : LucideIcons.arrow_down,
              size: 18,
            ),
            label: Text(
              following
                  ? '实时跟随'
                  : pendingCount == 0
                  ? '回到最新'
                  : '新增 $pendingCount 条',
            ),
          ),
        ],
      ),
    );
  }
}
