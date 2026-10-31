import 'home_cell.dart';
import 'media_item.dart';

/// A parsed homepage page. Keeping the cursor next to the parsed cards lets
/// callers update the feed atomically after checking that the request is
/// still current.
class HomepagePage {
  /// Flat card list, in document order. Still the primary path: every caller
  /// that just wants cards keeps using this.
  final List<MediaItem> items;

  /// Same page, but keeping the upstream block boundaries.
  ///
  /// Empty when the payload had no recognisable blocks (or an older backend
  /// answered), so a renderer that wants blocks can fall back to [items]
  /// instead of showing nothing. See [HomeCell] for why the boundaries matter.
  final List<HomeCell> cells;

  final int? nextOffset;
  final String? sessionId;

  /// 服务端本次下发的一级分类（`data.tab_item` 逐条的 `tab_type` / `title`）。
  ///
  /// 官方书城顶部的 tab 条不是写死的：`tab_item` 里每一条就是一个 tab，
  /// 名字取服务端的 `title`、身份取 `tab_type`（官方 `BaseBookMallFragment`
  /// 的 `f()` 返回 `getTabType()`，`n()` 返回 `getTabName()`）。本地此前硬编码
  /// 了 6 个跨媒介分类，既缺官方实际下发的「经典/知识/短篇/新书/商城」，
  /// 又编了一个服务端根本没有的「漫剧」，所以顶栏怎么调都不像官方。
  ///
  /// 空表示这次响应没带 `tab_item`（老后端或非首页接口），调用方应退回
  /// 本地兜底表。
  final List<HomeTabItem> tabs;

  /// 这次响应声明自己属于哪个分类：`tab_item` 里被回答那一项的 `tab_type`。
  ///
  /// 上游的分类表只有**被回答的那一项**带 `cell_data`，其余项只有标题，
  /// `data.tab_index` 指向该项在本响应里的位置。客户端按 `tab_type` 认领自己
  /// 那份；认不到就等于这份区块/卡片是别人的——「听书」里画出推荐榜、
  /// 猜你喜欢的小说卡片就是这么来的，调用方必须据此拒绝（见
  /// `HomeNotifier._answersTab`）。
  ///
  /// `null` 搭配 [tabScoped] 为 true 表示带了分类表但没有一项是我们的。
  final int? answeredTabType;

  /// 响应是否被限定到单个分类（带了 `tab_item` 分类表）。
  ///
  /// 为 false 时 [answeredTabType] 没有意义：调用方无从判断声明归属（老后端、
  /// 视频第二段 `cell/change`）。第二段由调用方按构造事实自己标注归属；
  /// 没带分类表的首页响应还会再过一道「区块族与分类轴是否匹配」的检查（见
  /// `HomeNotifier._answersTab`）——只带推荐那一族区块的载荷入不了别的分类。
  final bool tabScoped;

  const HomepagePage({
    required this.items,
    required this.nextOffset,
    required this.sessionId,
    this.cells = const [],
    this.tabs = const [],
    this.answeredTabType,
    this.tabScoped = false,
  });
}

/// 服务端下发的一个一级分类（`data.tab_item` 的一项）。
class HomeTabItem {
  final int type;
  final String title;

  const HomeTabItem({required this.type, required this.title});

  @override
  bool operator ==(Object other) =>
      other is HomeTabItem && other.type == type && other.title == title;

  @override
  int get hashCode => Object.hash(type, title);

  @override
  String toString() => 'HomeTabItem($type, $title)';
}
