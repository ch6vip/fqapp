import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';

/// 搜索内容区的第一行工具条：评分筛选 + 视图切换。
///
/// 它属于内容区而不是固定顶栏，所以会跟发现区 / 结果一起滚走。书旗来源没有
/// 上游评分，左边换成一行 12sp 的说明文字。
class SearchContentToolbar extends StatelessWidget {
  static const double height = 44;

  final bool shuqi;
  final bool scoreEnabled;
  final double minimumScore;
  final ValueChanged<double> onMinimumScore;
  final bool listView;
  final VoidCallback onToggleLayout;

  /// 「筛选已加载结果…」提示只在评分阈值生效时跟在工具条下面。
  final bool showRatingHint;

  const SearchContentToolbar({
    super.key,
    required this.shuqi,
    required this.scoreEnabled,
    required this.minimumScore,
    required this.onMinimumScore,
    required this.listView,
    required this.onToggleLayout,
    this.showRatingHint = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: homeGutter,
            right: homeGutter - 8,
          ),
          child: SizedBox(
            height: height,
            child: Row(
              children: [
                if (shuqi)
                  Text(
                    '书旗来源暂不提供评分',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      color: palette.muted,
                    ),
                  )
                else
                  _scoreDropdown(palette),
                const Spacer(),
                IconButton(
                  key: const Key('search-layout-toggle'),
                  tooltip: listView ? '切换为封面视图' : '切换为无封面列表',
                  onPressed: onToggleLayout,
                  padding: EdgeInsets.zero,
                  iconSize: 19,
                  color: palette.ink,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(height, height),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    listView ? LucideIcons.layout_grid : LucideIcons.list,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showRatingHint)
          Padding(
            padding: const EdgeInsets.only(left: homeGutter, bottom: 8),
            child: Text(
              '筛选已加载结果，未评分作品不计入；可继续加载更多。',
              style: TextStyle(fontSize: 11.5, color: palette.muted),
            ),
          ),
      ],
    );
  }

  Widget _scoreDropdown(HomePalette palette) {
    final active = scoreEnabled && minimumScore > 0;
    return DropdownButtonHideUnderline(
      child: DropdownButton<double>(
        key: const Key('search-minimum-score'),
        value: scoreEnabled ? minimumScore : 0,
        isDense: true,
        borderRadius: BorderRadius.circular(14),
        dropdownColor: palette.surface,
        icon: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Icon(
            LucideIcons.chevron_down,
            size: 14,
            color: active ? palette.accentText : palette.muted,
          ),
        ),
        style: TextStyle(
          fontSize: 13,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: active ? palette.accentText : palette.muted,
        ),
        items: const [
          DropdownMenuItem(value: 0, child: Text('评分不限')),
          DropdownMenuItem(value: 8, child: Text('8 分及以上')),
          DropdownMenuItem(value: 9, child: Text('9 分及以上')),
        ],
        onChanged: scoreEnabled
            ? (value) {
                if (value != null) onMinimumScore(value);
              }
            : null,
      ),
    );
  }
}

/// 按作品 ID 查找命中后的提示行；只在结果态出现，随内容一起滚动。
class SearchIdLookupHint extends StatelessWidget {
  /// 「按关键词搜索」要用输入框里的当前文字，调用方直接传入当前文本。
  final VoidCallback onKeywordSearch;

  const SearchIdLookupHint({super.key, required this.onKeywordSearch});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 2, homeGutter, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '按作品 ID 查找',
              style: TextStyle(fontSize: 12, height: 1.2, color: palette.muted),
            ),
          ),
          TextButton(
            onPressed: onKeywordSearch,
            style: TextButton.styleFrom(
              foregroundColor: palette.accentText,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              '按关键词搜索',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
