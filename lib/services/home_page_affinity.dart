import '../models/home_cell.dart';
import 'api_client.dart';
import 'app_log.dart';

/// 首页一页响应与当前分类的归属关系。
enum HomePageAffinity {
  /// 这一页就是本分类的内容。
  ours,

  /// 响应声明自己回答的是别的分类（`tab_type` 对不上）。
  foreignTab,

  /// 区块族与分类轴不匹配：拿到的是别的分类的区块。
  foreignBlocks,
}

/// 判定一页首页响应能不能当成本分类的载荷。
///
/// 背景：`/reading/bookapi/bookmall/tab/v` 的分类表只给**被回答那一项**带
/// `cell_data`，其余项只有标题，`data.tab_index` 指向被回答项的位置。所以
/// 「这份区块/卡片是谁的」必须由响应自己说清楚；说不清还照单全收，就是
/// 真机上「听书」里画出推荐/小说的排行榜与猜你喜欢。
///
/// 实测的区块族（推荐/听书/看剧/视频/漫剧五个分类，经内嵌后端打真实上游）：
///
/// | 分类 | `tab_type` | 区块 |
/// | --- | --- | --- |
/// | 推荐 | 2 | 511 排行榜 + 384 猜你喜欢 |
/// | 听书 | 5 | 337 |
/// | 看剧 | 8 | 506 |
/// | 视频 | 16 | 407 |
/// | 漫剧 | 24 | 385 |
///
/// 于是判定分三步：声明对不上 → [HomePageAffinity.foreignTab]；区块族与
/// 分类轴对不上 → [HomePageAffinity.foreignBlocks]；其余接受。未收录的
/// `tab_type` 与未知区块类型一律放行，不拿猜测去否决响应。
///
/// 被接受的页会留一行 `home` 调试日志（分类、回答的分类、区块、卡片数、
/// 游标），被拒的留警告——真机出问题时日志直接说明第二次响应的真身。
HomePageAffinity homePageAffinity(
  HomepagePage page, {
  required int tabType,
  required String kind,
}) {
  if (page.tabScoped && page.answeredTabType != tabType) {
    AppLog.w(
      'home',
      '丢弃不属于 tab_type=$tabType 的首页响应（回答的是 '
          '${page.answeredTabType ?? "未声明的分类"}，'
          'shows=${describeHomeCells(page.cells)}，items=${page.items.length}）',
    );
    return HomePageAffinity.foreignTab;
  }
  if (page.cells.any((cell) => !_blockFitsKind(cell.showType, kind))) {
    AppLog.w(
      'home',
      '丢弃带别的分类区块的 tab_type=$tabType 首页响应'
          '（shows=${describeHomeCells(page.cells)}，items=${page.items.length}）',
    );
    return HomePageAffinity.foreignBlocks;
  }
  AppLog.d(
    'home',
    '收下 tab_type=$tabType 首页响应（回答 ${page.answeredTabType ?? "未声明"}，'
        'shows=${describeHomeCells(page.cells)}，items=${page.items.length}，'
        'next=${page.nextOffset}）',
  );
  return HomePageAffinity.ours;
}

/// 区块族与分类轴对不对得上。
///
/// 511（排行榜）与 384/385（猜你喜欢卡片流）是**书籍轴**的区块，漫剧也会用
/// 385；书籍类（`book`）与漫剧（`manju`）因此放行，声书类（`audio`）等收到
/// 这一族就是别人的页。其余区块（337 听书 / 506 看剧 / 407 视频…）与未知
/// 类型一律放行。
bool _blockFitsKind(int showType, String kind) => switch (showType) {
  kHomeCellRankShowType => kind == 'book',
  kHomeCellMixedFeedShowType ||
  kHomeCellDoubleRowFeedShowType => kind == 'book' || kind == 'manju',
  _ => true,
};

/// 区块类型的紧凑描述，给日志用（`511,384`，空表是 `-`）。
String describeHomeCells(List<HomeCell> cells) =>
    cells.isEmpty ? '-' : cells.map((cell) => '${cell.showType}').join(',');
