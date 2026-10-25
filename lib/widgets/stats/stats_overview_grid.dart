import 'package:flutter/material.dart';

/// The four overview tiles (今日 / 本月 / 总计 / 活跃天数) on the statistics page.
///
/// Laid out as intrinsic rows instead of a fixed-extent grid. A grid has to
/// declare one height up front, and that constant only holds for one text
/// scale and one font: when a label wraps or the system font is taller, the
/// guess is wrong and the excess shows up as dead space under the last row.
/// Rows sized by their own content cannot disagree with the text.
class StatsOverviewGrid extends StatelessWidget {
  final List<(String, String)> stats;

  const StatsOverviewGrid({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var row = 0; row < stats.length; row += 2) ...[
          if (row > 0) const SizedBox(height: 10),
          Row(
            // 不用 CrossAxisAlignment.stretch：这个 Row 在 ListView 里拿到的是
            // 纵向无界约束，stretch 会把 Infinity 传给孩子。两列的内容结构一致
            // （一行带省略号的值 + 一行标签），高度本来就相等。
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < 2; column++) ...[
                if (column > 0) const SizedBox(width: 10),
                Expanded(
                  child: _StatsTile(
                    label: stats[row + column].$2,
                    value: stats[row + column].$1,
                    scheme: scheme,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _StatsTile extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme scheme;

  const _StatsTile({
    required this.label,
    required this.value,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 19,
              height: 1.2,
              fontWeight: FontWeight.bold,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
