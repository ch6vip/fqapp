/// 点击区域：阅读页点按的 3x3 九宫格动作配置。
///
/// 布局参考 Legado 的“点击区域设置”（9 个区域、每格一个动作、至少保留
/// 一个菜单区），实现为 fqapp 自己的代码。区域按行优先编号：0-2 上行、
/// 3-5 中行、6-8 下行，每行内从左到右。
enum ReaderTapZoneAction {
  /// 不做任何事。
  none('无'),

  /// 打开 / 关闭控制栏。
  menu('菜单'),

  /// 上一页。
  prevPage('上一页'),

  /// 下一页。
  nextPage('下一页'),

  /// 上一章。
  prevChapter('上一章'),

  /// 下一章。
  nextChapter('下一章'),

  /// 打开目录。
  toc('目录');

  const ReaderTapZoneAction(this.label);

  /// 九宫格里显示的文案。
  final String label;
}

/// 默认九宫格：与历史行为一致——左列上一页、中列菜单、右列下一页。
const List<ReaderTapZoneAction> defaultReaderTapZones = [
  ReaderTapZoneAction.prevPage,
  ReaderTapZoneAction.menu,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.prevPage,
  ReaderTapZoneAction.menu,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.prevPage,
  ReaderTapZoneAction.menu,
  ReaderTapZoneAction.nextPage,
];

/// 单手模式九宫格：左、右列都是下一页，中列菜单。
/// 对应 #51 里 Legado 截图的布局，也是旧“单手模式”开关的效果。
const List<ReaderTapZoneAction> oneHandReaderTapZones = [
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.menu,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.menu,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.menu,
  ReaderTapZoneAction.nextPage,
];

/// 全屏翻页九宫格：只有正中一格是菜单，其余八格全部下一页。
/// 来自 #147 报告人附的图：单手使用时点屏幕下半部分（乃至除正中外的
/// 任何位置）都翻页，只有正中区域才打开菜单。
const List<ReaderTapZoneAction> fullscreenReaderTapZones = [
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.menu,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
];

/// 把九宫格规整为 9 个合法动作；长度不对或含未知值时回落默认。
/// 接受动作本身（内存里的九宫格）与动作名（持久化读回的字符串）。
List<ReaderTapZoneAction> normalizeReaderTapZones(List<Object?>? raw) {
  if (raw == null || raw.length != 9) {
    return List<ReaderTapZoneAction>.of(defaultReaderTapZones);
  }
  final zones = <ReaderTapZoneAction>[];
  for (final item in raw) {
    final action = switch (item) {
      ReaderTapZoneAction action => action,
      String name => ReaderTapZoneAction.values
          .where((value) => value.name == name)
          .firstOrNull,
      _ => null,
    };
    if (action == null) {
      return List<ReaderTapZoneAction>.of(defaultReaderTapZones);
    }
    zones.add(action);
  }
  return zones;
}

/// 安全不变量（与 Legado 的 detectClickArea 相同思路）：至少保留一个菜单区，
/// 否则点按永远打不开控制栏。没有菜单区时把中间格恢复为菜单。
List<ReaderTapZoneAction> ensureReaderTapZonesHaveMenu(
  List<ReaderTapZoneAction> zones,
) {
  final normalized = normalizeReaderTapZones(zones);
  if (normalized.contains(ReaderTapZoneAction.menu)) {
    return normalized;
  }
  final fixed = List<ReaderTapZoneAction>.of(normalized);
  fixed[4] = ReaderTapZoneAction.menu;
  return fixed;
}

/// 根据点按位置解析九宫格动作。坐标超出范围时钳制到边缘格。
ReaderTapZoneAction readerTapZoneActionAt({
  required List<ReaderTapZoneAction> zones,
  required double dx,
  required double dy,
  required double width,
  required double height,
}) {
  final normalized = normalizeReaderTapZones(zones);
  final column = width <= 0
      ? 1
      : ((dx / width) * 3).floor().clamp(0, 2);
  final row = height <= 0
      ? 1
      : ((dy / height) * 3).floor().clamp(0, 2);
  return normalized[row * 3 + column];
}

/// 九宫格的持久化形式：9 个动作名。
List<String> encodeReaderTapZones(List<ReaderTapZoneAction> zones) =>
    normalizeReaderTapZones(zones).map((zone) => zone.name).toList();
