import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// 官方书城顶栏（`res/layout/alx.xml` 的 `fua` / `Toolbar h7` 区域）。
///
/// 官方在这一层只有两样东西：一条 36dp 的白色圆角搜索框（`c5e.xml`），
/// 以及右侧两个默认 gone 的图标位（`h4f` 收缩搜索、`gpe` 分类）。
/// 没有品牌 logo、没有 slogan、没有「每日发现」角标 —— 上一版自制的
/// 品牌头是整页最不像官方的地方，这里按官方收掉。
///
/// 尺寸取自反编译布局：
/// * 搜索框行 `fua`：height 51dp，paddingTop 6dp / paddingBottom 9dp；
/// * 搜索框本体 `c5e.xml`：height `@dimen/zl` = 36dp，左右 margin 16dp，
///   底色 `skin_color_search_bar_bg_v2_light` = #FFFFFF，
///   圆角 `skin_shape_search_bar_light` = 6dp；
/// * 放大镜 `c8`：11×11dp，marginStart 16dp。
class HomeHero extends StatelessWidget {
  static const double searchBarHeight = 36;
  static const double searchBarRadius = 6;

  final VoidCallback onSearch;
  final VoidCallback onRanks;
  final Future<void> Function() onRefresh;
  final bool refreshing;

  const HomeHero({
    super.key,
    required this.onSearch,
    required this.onRanks,
    required this.onRefresh,
    this.refreshing = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      // 官方 fua：paddingTop 6dp / paddingBottom 9dp，左右 16dp。
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 9),
      child: Row(
        children: [
          Expanded(
            child: HomePressable(
              key: const Key('home_search_button'),
              onTap: onSearch,
              borderRadius: BorderRadius.circular(searchBarRadius),
              semanticLabel: '搜索书名、作者',
              child: Container(
                height: searchBarHeight,
                padding: const EdgeInsets.only(left: 16, right: 12),
                decoration: BoxDecoration(
                  color: palette.searchBar,
                  borderRadius: BorderRadius.circular(searchBarRadius),
                ),
                child: Row(
                  children: [
                    // 官方 c8：11×11dp 放大镜。
                    Icon(
                      LucideIcons.search,
                      size: 11,
                      color: palette.searchBarText,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '搜索书名、作者',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: palette.searchBarText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 官方这两个位置（h4f / gpe）是默认 gone 的图标位，这里承载
          // 排行榜与刷新两个入口，尺寸与搜索框同高，避免破坏官方顶栏比例。
          _HeroIconButton(
            buttonKey: const Key('home_ranks_button'),
            tooltip: '排行榜',
            icon: LucideIcons.trophy,
            onTap: onRanks,
          ),
          const SizedBox(width: 6),
          _HeroIconButton(
            buttonKey: const Key('home_refresh_button'),
            tooltip: '刷新推荐',
            icon: LucideIcons.refresh_ccw,
            onTap: refreshing ? null : () => onRefresh(),
            busy: refreshing,
          ),
        ],
      ),
    );
  }
}

class _HeroIconButton extends StatelessWidget {
  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  const _HeroIconButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Tooltip(
      message: tooltip,
      child: HomePressable(
        key: buttonKey,
        onTap: onTap ?? () {},
        borderRadius: BorderRadius.circular(HomeHero.searchBarRadius),
        semanticLabel: tooltip,
        child: Container(
          width: HomeHero.searchBarHeight,
          height: HomeHero.searchBarHeight,
          decoration: BoxDecoration(
            color: palette.searchBar,
            borderRadius: BorderRadius.circular(HomeHero.searchBarRadius),
          ),
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: HomePalette.accent,
                    ),
                  )
                : Icon(icon, size: 17, color: palette.searchBarText),
          ),
        ),
      ),
    );
  }
}
