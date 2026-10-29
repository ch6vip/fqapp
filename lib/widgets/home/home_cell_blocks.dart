import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';
import 'home_shelf.dart';

/// Bookstore blocks that the shelf still renders.
///
/// 首页改成「以书为主」后只保留两块有独立结构的区块：排行榜（511）与流尾
/// （`aes.xml` 的三态文案）。卡片流（384/385）不再由区块自绘，交给
/// `home_page.dart` 统一排成书架网格；官方那套 `asb.xml` / `b8w.xml` 的
/// 尺寸引用随之移除，排行榜改成横向大封面轨道（见 [HomeRankCell]）。

/// 「更多」 — 12sp 灰字 + 箭头，放在分区头右端。
class HomeBlockMore extends StatelessWidget {
  const HomeBlockMore({super.key, required this.onTap, this.label = '更多'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, height: 1.2, color: palette.muted),
          ),
          const SizedBox(width: 2),
          Icon(LucideIcons.chevron_right, size: 13, color: palette.muted),
        ],
      ),
    );
  }
}

// ── Rank block ─────────────────────────────────────────────────────────────

const double _rankCardWidth = 100;
const double _rankCoverHeight = 140;
const double _rankCardGap = 12;

/// 排行榜改成横向轨道后的整段高度：封面 + 8 + 两行书名 + 4 + 一行副标题。
double _rankRailHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return _rankCoverHeight +
      8 +
      scaler.scale(13) * 1.35 * 2 +
      4 +
      scaler.scale(11) * 1.3;
}

/// The rank boards shipped with the block
/// (`rank_with_category_data.rank_algo_list[]`).
List<Map<String, dynamic>> _rankAlgos(HomeCell cell) {
  final data = cell.extra['rank_with_category_data'];
  if (data is! Map) return const [];
  final list = data['rank_algo_list'];
  if (list is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final entry in list) {
    if (entry is! Map) continue;
    final name = (entry['rank_name'] ?? '').toString();
    if (name.isEmpty) continue;
    out.add(Map<String, dynamic>.from(entry));
  }
  return out;
}

/// Rank board names shipped with the block
/// (`rank_with_category_data.rank_algo_list[name].rank_name`).
List<String> homeRankNames(HomeCell cell) => [
  for (final entry in _rankAlgos(cell)) entry['rank_name'].toString(),
];

/// `rank_algo` of every board, passed back as `algo_type` when the strip
/// switches boards (`m0.W0` → `RankListAlgoInfo.rankAlgo`).
List<int> homeRankAlgos(HomeCell cell) => [
  for (final entry in _rankAlgos(cell))
    int.tryParse('${entry['rank_algo']}') ?? -1,
];

/// The rank list id this block previews (`cell_id_str`).
String homeRankId(HomeCell cell) => cell.id;

/// Loads one rank board for the preview: `(rankId, algo) → books`.
///
/// Injected so the block stays testable; the page wires it to
/// `ApiClient.rankBoard`.
typedef HomeRankLoader =
    Future<List<MediaItem>> Function(String rankId, int algo);

/// `RankCellV3`(511) entry point for the renderer registry.
Widget buildRankCell(
  BuildContext context,
  HomeCell cell, {
  required ValueChanged<MediaItem> onOpen,
  required VoidCallback onMore,
  HomeRankLoader? loadBoard,
}) => HomeRankCell(
  cell: cell,
  onOpen: onOpen,
  onMore: onMore,
  loadBoard: loadBoard,
);

/// `RankCellV3`(511): a section title, the board names, and one rail of books.
///
/// 原版是「四行一页、横向翻页」的榜单预览，读起来像报表；改成大封面轨道
/// 后，榜单的「排位」用封面左下角的大号数字直接表达（真实名次，不是装饰
/// 序号）。榜名切换仍是原地换数据（`RankMixContentHolder.K7`）。
class HomeRankCell extends StatefulWidget {
  const HomeRankCell({
    super.key,
    required this.cell,
    required this.onOpen,
    required this.onMore,
    this.loadBoard,
  });

  final HomeCell cell;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onMore;
  final HomeRankLoader? loadBoard;

  @override
  State<HomeRankCell> createState() => _HomeRankCellState();
}

class _HomeRankCellState extends State<HomeRankCell> {
  /// Board picked from the names row; 0 is what the upstream previews
  /// (`first_show=false`).
  int _index = 0;

  /// Books of [_index] once loaded; null means "still the upstream preview".
  List<MediaItem>? _loaded;
  bool _loading = false;

  /// Guards against a slow response for an older board overwriting a newer one.
  int _generation = 0;

  List<MediaItem> get _books => _loaded ?? widget.cell.flatten();

  Future<void> _select(int index) async {
    if (index == _index) return;
    final algos = homeRankAlgos(widget.cell);
    final loader = widget.loadBoard;
    final rankId = homeRankId(widget.cell);
    setState(() {
      _index = index;
      _loading = false;
      _loaded = null;
    });
    // Nothing to fetch with: fall back to the rank page like 「更多」 does.
    if (loader == null ||
        index >= algos.length ||
        algos[index] < 0 ||
        rankId.isEmpty) {
      widget.onMore();
      return;
    }
    final generation = ++_generation;
    setState(() => _loading = true);
    try {
      final books = await loader(rankId, algos[index]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loaded = books.isEmpty ? null : books;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      // Keep whatever the preview already had rather than blanking the block.
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cell = widget.cell;
    final books = _books;
    if (books.isEmpty) return const SizedBox.shrink();
    final names = homeRankNames(cell);
    final title = cell.name.isEmpty ? '排行榜' : cell.name;
    final railHeight = _rankRailHeight(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(
          title: title,
          action: HomeBlockMore(onTap: widget.onMore),
        ),
        if (names.length > 1)
          _BoardNames(names: names, selectedIndex: _index, onSelect: _select),
        const SizedBox(height: 12),
        if (_loading)
          SizedBox(
            height: railHeight,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: HomePalette.accent,
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: railHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: homeGutter),
              itemCount: books.length,
              separatorBuilder: (_, _) => const SizedBox(width: _rankCardGap),
              itemBuilder: (context, index) {
                final item = books[index];
                return _RankCard(
                  key: ValueKey('rank:${item.kind}:${item.id}'),
                  item: item,
                  rank: index + 1,
                  onTap: () => widget.onOpen(item),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// The board names under the title: plain text tabs, selected in ink with a
/// 2dp underline. 旧版的字号跳变（16/14）加 40% 透明度太吵，这里只留
/// 字重与下划线。
class _BoardNames extends StatelessWidget {
  const _BoardNames({
    required this.names,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<String> names;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      child: Row(
        children: [
          for (var index = 0; index < names.length; index++)
            Padding(
              padding: EdgeInsets.only(left: index == 0 ? 0 : 20),
              child: GestureDetector(
                onTap: () => onSelect(index),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        names[index],
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.2,
                          fontWeight: index == selectedIndex
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: index == selectedIndex
                              ? palette.ink
                              : palette.muted,
                        ),
                      ),
                    ),
                    Container(
                      width: 16,
                      height: 2,
                      decoration: BoxDecoration(
                        color: index == selectedIndex
                            ? palette.ink
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RankCard extends StatelessWidget {
  const _RankCard({
    super.key,
    required this.item,
    required this.rank,
    required this.onTap,
  });

  final MediaItem item;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final score = item.score;
    final meta = item.rankTags.isNotEmpty
        ? item.rankTags.first
        : item.author.isNotEmpty
        ? item.author
        : score != null
        ? homeScoreText(score)
        : '';
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      semanticLabel: '$rank ${item.title}',
      child: SizedBox(
        width: _rankCardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RankCover(item: item, rank: rank),
            const SizedBox(height: 8),
            SizedBox(
              height: scaler.scale(13) * 1.35 * 2,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The cover with a TOP-3 badge. 只有前三名戴角标：封面上不再压大号数字，
/// 名次仍然是真的（轨道顺序 = 榜单顺序），但不再挡住书封。
class _RankCover extends StatelessWidget {
  const _RankCover({required this.item, required this.rank});

  final MediaItem item;
  final int rank;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _rankCardWidth,
      height: _rankCoverHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            StoryCover(item: item, cacheWidth: 200),
            if (rank <= 3)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'TOP $rank',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The card stream's tail (`aes.xml` + `widget/u4.java`, footer type 199).
///
/// Three states, all 12sp `skin_color_gray_40_light` (#66000000):
/// loading「加载中...」/ retry「加载失败，点击重试」(tap reloads) /
/// done「已显示全部内容」— the done form sits between two 12×0.5dp rules
/// with 8dp top / 32dp bottom padding; the others take 16dp top / 24dp
/// bottom (`vu`)。
class HomeStreamFooter extends StatelessWidget {
  const HomeStreamFooter.loading({super.key, this.onRetry})
    : _state = _StreamFooterState.loading;
  const HomeStreamFooter.retry({super.key, required this.onRetry})
    : _state = _StreamFooterState.retry;
  const HomeStreamFooter.done({super.key, this.onRetry})
    : _state = _StreamFooterState.done;

  final _StreamFooterState _state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = palette.body;
    switch (_state) {
      case _StreamFooterState.done:
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 12, height: 0.5, color: color),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '已显示全部内容',
                  style: TextStyle(fontSize: 12, height: 1.2, color: color),
                ),
              ),
              Container(width: 12, height: 0.5, color: color),
            ],
          ),
        );
      case _StreamFooterState.retry:
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 24),
          child: GestureDetector(
            onTap: onRetry,
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: Text(
                '加载失败，点击重试',
                style: TextStyle(fontSize: 12, height: 1.2, color: color),
              ),
            ),
          ),
        );
      case _StreamFooterState.loading:
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 24),
          child: Center(
            child: Text(
              '加载中...',
              style: TextStyle(fontSize: 12, height: 1.2, color: color),
            ),
          ),
        );
    }
  }
}

enum _StreamFooterState { loading, retry, done }
