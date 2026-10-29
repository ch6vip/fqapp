import 'package:flutter/material.dart';

import 'home_design.dart';

// The home shelf: one card language, one gutter, one rhythm.
//
// 首页按「以书为主」重做（用户 2026-10-26 拍板），不再逐像素对齐官方书城。
// 这一层只放共享的版式：16dp 栏距、12dp 列距、统一的分区头；卡片在
// home_media_card.dart，榜单在 home_cell_blocks.dart，继续阅读那一行在
// home_reading_row.dart，页面组合在 home_page.dart。

/// The only side gutter on the home surface. 搜索行、分类条、分区头和网格都
/// 落在同一条 16dp 竖线上——旧版 12/16/20 三套栏距是页面看起来「没对齐」
/// 的主因。
const double homeGutter = 16;

/// Column gutter of the book grid. 8dp（官方卡片流的值）在 16dp 栏距下显得
/// 挤，12dp 让两列之间的留白与栏距成比例。
const double homeGridGap = 12;

/// 网格标题到正文的间距。
const double homeHeaderGap = 12;

/// 分区之间的呼吸。用户 2026-10-30 反馈：收起「继续阅读」后顶部留白显空，
/// 所以从上往下压紧——20dp 对 19sp 标题、12dp 到内容。
const double homeSectionGap = 20;

/// Bottom clearance above the floating navigation bar: bar 64 + its 8dp
/// padding + the system inset + 24dp of breathing room.
double homeBottomClearance(BuildContext context) =>
    64 + 8 + MediaQuery.paddingOf(context).bottom + 24;

/// Columns for the book grid.
///
/// 手机 3 列（≥360dp 宽时）是「以书为主」的取舍：封面仍是主角，一屏能
/// 扫到六本书；320dp 的小屏和大字号会退到 2 列，否则 15sp 的标题在 88dp
/// 宽里只剩四五个字。平板与桌面按同一套宽度断点放宽。
int homeShelfColumns(BuildContext context, double width) {
  final largeType = MediaQuery.textScalerOf(context).scale(15) > 22;
  if (largeType && width < 640) return 2;
  if (width < 360) return 2;
  if (width < 640) return 3;
  if (width < 900) return 4;
  return 5;
}

/// Laid-out width of one card, handed down so the card can decode its cover at
/// exactly this size (and skip a LayoutBuilder of its own).
double homeShelfCardWidth(BuildContext context, double width) {
  final columns = homeShelfColumns(context, width);
  return (width - (columns - 1) * homeGridGap) / columns;
}

SliverGridDelegate homeShelfDelegate(BuildContext context, double width) {
  final scaler = MediaQuery.textScalerOf(context);
  final cardWidth = homeShelfCardWidth(context, width);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: homeShelfColumns(context, width),
    crossAxisSpacing: homeGridGap,
    mainAxisSpacing: 20,
    mainAxisExtent: homeCardExtent(context, cardWidth, scaler),
  );
}

/// Cover (5:7) + 8dp + two title lines + 4dp + one meta line.
double homeCardExtent(
  BuildContext context,
  double cardWidth,
  TextScaler scaler,
) =>
    cardWidth * 1.4 +
    8 +
    scaler.scale(15) * 1.35 * 2 +
    4 +
    scaler.scale(11) * 1.3 +
    2;

/// A section title on the shelf: 19sp, tight tracking, no accent bar, no icon.
///
/// 旧版的「橙色竖条 + 罗盘图标 + 20sp 副标题」是三件套装饰，去掉了；层级
/// 由字号和留白承担。`action` 放在同一行右端（榜单的「更多」）。
class HomeSectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;

  const HomeSectionHeader({super.key, required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        homeGutter,
        homeSectionGap,
        homeGutter,
        homeHeaderGap,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 19,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: palette.ink,
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 12), action!],
        ],
      ),
    );
  }
}
