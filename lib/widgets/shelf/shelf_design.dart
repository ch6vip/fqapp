import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// 书架重设计的视觉 token 总表（docs/system_design.md §1.2）。
///
/// 合同（三条，可核对）：
/// 1. 三档版式几何（边距 / 圆角 / 封面比 / 行高 / 进度条粗细）与跨组件复用的
///    字号、图标尺寸一律走本表，三档卡片与书架页不写字面量；
/// 2. 颜色一律走 `HomePalette.of(context)` 明暗双主题，唯二允许的固定色是
///    accent 上的白字/白图标与删除红 [deleteRed]（官方
///    `skin_color_red_delete_light`）；
/// 3. 单个私有组件内部的一次性装饰尺寸（图标直径、控件内边距、elevation、
///    0.5/0.6dp 发丝描边）留在使用处 —— 它们只服务一个组件，抽进总表只增加
///    跳转成本，不减少重复。
class ShelfTokens {
  ShelfTokens._();

  // ---- 几何 ----

  /// 三档版式统一的页面水平边距（原 20/12/20 混用，统一收敛）。
  static const double screenPadding = 16.0;

  /// 内容区底部留白：三档版式的最后一行不被悬浮底栏与手势条压住。
  static const double contentBottomInset = 88.0;

  /// 编辑态顶部操作栏高度（全选 / 已选择 N 本 / 完成）。
  static const double editBarHeight = 52.0;

  /// 宫格 / 双列封面圆角。
  static const double radiusCover = 10.0;

  /// 列表封面圆角（更小的行内缩略图用更小的圆角）。
  static const double radiusListCover = 8.0;

  /// 双列信息卡、空态图标容器圆角。
  static const double radiusCard = 14.0;

  /// 筛选胶囊（全圆角观感）。
  static const double radiusChip = 18.0;

  /// 工具栏按钮（版式分段控件外壳、页头按钮）。
  static const double radiusButton = 12.0;

  // ---- 宫格 ----

  static const int gridColumns = 3;
  static const double gridSpacing = 12.0;
  static const double gridRunSpacing = 20.0;

  /// 封面高宽比。与官方 1.3947369 视觉等价，取整洁值 1.4。
  static const double gridCoverRatio = 1.4;

  // ---- 双列 ----

  /// 双列封面同比例（设计上与宫格共用视觉语言）。
  static const double doubleCoverRatio = 1.4;

  /// 双列卡片内边距：封面 = 满格宽减去两侧 padding。
  static const double doubleCardPadding = 12.0;

  // ---- 列表 ----

  /// 列表行高从 110 收紧到 84：信息密度提高，ConstrainedBox minHeight
  /// 在大字号下仍自适应增高（无障碍用例继续覆盖）。
  static const double listRowHeight = 84.0;
  static const double listCoverWidth = 56.0;
  static const double listCoverHeight = 78.0;

  /// 列表行底部进度条粗细。
  static const double listProgressHeight = 3.0;

  // ---- 间距标尺 ----

  static const double spaceXS = 4.0;
  static const double spaceS = 8.0;
  static const double spaceM = 12.0;
  static const double spaceL = 16.0;

  // ---- 图标 ----

  /// 行内小图标（今日已读 / 页头按钮 / 排序胶囊）。
  static const double iconInline = 13.0;

  // ---- 字号 ----

  /// 宫格标题（原 14 w400，收紧字重提高层级）。
  static const double titleGrid = 13.0;

  /// 双列标题。
  static const double titleDouble = 15.0;

  /// 列表标题。
  static const double titleList = 15.0;

  /// 副信息（原 12）。
  static const double subtitle = 11.5;

  /// 双列类型小标签字号。
  static const double kindTagSize = 10.0;

  /// 小号控件文本（筛选胶囊 / 页头按钮 / 排序胶囊）。
  static const double labelControl = 12.5;

  // ---- 行高倍率 ----

  /// 标题行高（近似官方 lineSpacingExtra 3dp 的观感）。
  static const double titleLineHeight = 1.25;

  /// 副信息行高。
  static const double subtitleLineHeight = 1.3;

  // ---- 颜色（唯二允许的固定色） ----

  /// 底栏删除的官方色 `skin_color_red_delete_light`。挪到这里统一管理，
  /// 页面与卡片不再各自硬编码。
  static const Color deleteRed = Color(0xFFF43207);
}

/// The three shelf layouts.
///
/// The enum order is the stored preference (0 宫格 / 1 双列 / 2 列表，语义与
/// 旧版完全一致，6.0 以前的「列数」旧值迁移逻辑见 library_page)，also the
/// order the 更多 menu lists them in, so [BookshelfLayout.values] can be used
/// directly for both the preference index and the menu.
enum BookshelfLayout {
  grid('切换为宫格', 'grid', LucideIcons.layout_grid),
  doubleColumn('切换为双列', 'double', LucideIcons.columns_2),
  list('切换为列表', 'list', LucideIcons.list);

  const BookshelfLayout(this.menuLabel, this.segmentKey, this.menuIcon);

  /// The official menu label (strings su/sh/sk).
  final String menuLabel;

  /// 版式分段控件的 Key 片段（`shelf-layout-<segmentKey>`）。
  final String segmentKey;

  /// 更多菜单里的图标。
  final IconData menuIcon;
}

const _kindLabels = {
  'book': '小说',
  'video': '短剧',
  'manju': '漫剧',
  'manga': '漫画',
  'audio': '听书',
};

/// 内容类型色。用于双列卡片的类型小标签（12% 透明度底色）与无封面占位，
/// 是「数据真实存在」的类型标识色，不属于主题色，明暗两套同值。
const _kindColors = {
  'book': Color(0xFF4A90D9),
  'video': Color(0xFFE8532D),
  'manju': Color(0xFFAA5A92),
  'manga': Color(0xFF34A853),
  'audio': Color(0xFF9C6ADE),
};

String bookshelfKindLabel(String kind) => _kindLabels[kind] ?? kind;

Color? bookshelfKindColor(String kind) => _kindColors[kind];

// ---------------------------------------------------------------------------
// 三档版式的网格几何（textScaler 自适应，卡片 build 内的固定高度必须与
// 这里的计算保持同一套 token，否则大字号下会溢出或留白）。
// ---------------------------------------------------------------------------

/// The width of one 宫格 cell, including nothing of the page padding.
double shelfGridCellWidth(
  double availableWidth, {
  int columns = ShelfTokens.gridColumns,
}) => math.max(
  1.0,
  (availableWidth -
          ShelfTokens.screenPadding * 2 -
          ShelfTokens.gridSpacing * (columns - 1)) /
      columns,
);

/// Cell height that keeps the 3-column cover at its ratio while the title
/// (two lines) and the info line still fit at the current text scale.
double shelfGridChildAspectRatio(
  BuildContext context, {
  required double availableWidth,
  int columns = ShelfTokens.gridColumns,
}) {
  final scaler = MediaQuery.textScalerOf(context);
  final cellWidth = shelfGridCellWidth(availableWidth, columns: columns);
  final cellHeight =
      cellWidth * ShelfTokens.gridCoverRatio +
      2 +
      scaler.scale(ShelfTokens.titleGrid) * ShelfTokens.titleLineHeight * 2 +
      ShelfTokens.spaceXS +
      scaler.scale(ShelfTokens.subtitle) * ShelfTokens.subtitleLineHeight +
      ShelfTokens.spaceXS;
  return cellWidth / cellHeight;
}

/// The width of one 双列 cell, including nothing of the page padding.
double shelfDoubleCellWidth(double availableWidth) => math.max(
  1.0,
  (availableWidth - ShelfTokens.screenPadding * 2 - ShelfTokens.gridSpacing) /
      2,
);

/// 双列类型小标签的实测高度（10sp 文本 + 上下 3dp 内边距）。
double shelfKindTagHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(ShelfTokens.kindTagSize) * 1.2 + 6;

/// 双列整卡高度：卡片内边距 + 封面 + 标题 1 行 + 副信息 1 行 + 类型标签。
double shelfDoubleChildAspectRatio(
  BuildContext context, {
  required double availableWidth,
}) {
  final scaler = MediaQuery.textScalerOf(context);
  final cellWidth = shelfDoubleCellWidth(availableWidth);
  final coverWidth = math.max(
    1.0,
    cellWidth - ShelfTokens.doubleCardPadding * 2,
  );
  final cellHeight =
      ShelfTokens.doubleCardPadding +
      coverWidth * ShelfTokens.doubleCoverRatio +
      ShelfTokens.spaceS +
      scaler.scale(ShelfTokens.titleDouble) * ShelfTokens.titleLineHeight +
      ShelfTokens.spaceXS +
      scaler.scale(ShelfTokens.subtitle) * ShelfTokens.subtitleLineHeight +
      6 +
      shelfKindTagHeight(context) +
      ShelfTokens.doubleCardPadding;
  return cellWidth / cellHeight;
}
