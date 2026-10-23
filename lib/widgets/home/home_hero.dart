import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// 官方书城顶栏（`res/layout/alx.xml` 的 `fua` 搜索行）。
///
/// 官方在这一层只有一条 36dp 的白色圆角搜索框（`c5e.xml`）：左侧 11dp
/// 放大镜，中间是 `@string/duw`「请输入书名或作者名」，右侧 marginEnd 12dp
/// 处是「识剧」图文入口。`alx.xml` 里 `h4f`（收缩搜索）与 `gpe`（分类）两个
/// 图标位默认 `visibility="gone"`，`i_y`（右上角分类入口）同样是 gone ——
/// 所以官方顶栏右侧**没有**任何常驻按钮。
///
/// 尺寸取自反编译布局：
/// * 搜索行 `fua`：height 51dp，paddingTop 6dp / paddingBottom 9dp；
/// * 搜索框本体 `c5e.xml`：height `@dimen/zl` = 36dp，左右 margin 16dp，
///   底色 `skin_color_search_bar_bg_v2_light` = #FFFFFF，
///   圆角 `skin_shape_search_bar_light` = 6dp；
/// * 放大镜 `c8`：11×11dp，marginStart 16dp；
/// * 「识剧」`h4i`：14sp，色 `skin_color_search_bar_text_v3_light`(#66000000)，
///   左侧分隔图 `skin_image_search_divider_icon_light` 与文字间隔 12dp。
class HomeHero extends StatelessWidget {
  static const double searchBarHeight = 36;
  static const double searchBarRadius = 6;

  /// 官方 `@string/duw`：`SearchWordDisplayView` 的默认文案。
  static const String searchHint = '请输入书名或作者名';

  /// 官方 `@string/dv8`。
  static const String imageSearchLabel = '识剧';

  final VoidCallback onSearch;
  final VoidCallback onImageSearch;

  const HomeHero({
    super.key,
    required this.onSearch,
    required this.onImageSearch,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      // 官方 fua：paddingTop 6dp / paddingBottom 9dp，左右 16dp。
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 9),
      child: HomePressable(
        key: const Key('home_search_button'),
        onTap: onSearch,
        borderRadius: BorderRadius.circular(searchBarRadius),
        semanticLabel: searchHint,
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
                  searchHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: palette.searchBarText,
                  ),
                ),
              ),
              // 官方 search_image_icon_container：右贴 parent、marginEnd 12dp。
              GestureDetector(
                key: const Key('home_image_search_button'),
                behavior: HitTestBehavior.opaque,
                onTap: onImageSearch,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(
                    children: [
                      // 官方分隔图 16dp 高，marginEnd 12dp。
                      Container(
                        width: 0.5,
                        height: 16,
                        color: palette.searchBarText.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        imageSearchLabel,
                        style: TextStyle(
                          fontSize: 14,
                          color: palette.searchBarText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
