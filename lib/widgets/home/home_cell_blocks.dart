import 'package:flutter/material.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';
import '../../services/app_style_tokens.dart';
import 'classic_home_rank_rail.dart';
import 'home_archive.dart';
import 'home_design.dart';
import 'home_rank_shelf.dart';
import 'home_shelf.dart';

// 流尾已拆到独立文件，这里保留导出，页面沿用原 import 即可。
export 'home_stream_footer.dart';

/// Bookstore blocks that the shelf still renders.
///
/// 2026-11 首页重做后只剩排行榜（511）有独立的区块结构，卡片流（384/385）
/// 仍由 `home_page.dart` 统一排成网格，流尾在 `home_stream_footer.dart`。
/// 排行榜的预览从「横向封面轨道」换成了立体书架（见 `home_rank_shelf.dart`）。

/// 「完整榜单」入口。
class HomeBlockMore extends StatelessWidget {
  const HomeBlockMore({super.key, required this.onTap, this.label = '完整榜单'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) =>
      HomeSectionAction(label: label, onTap: onTap);
}

// ── Rank block ─────────────────────────────────────────────────────────────

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

/// `RankCellV3`(511): 分区标签、榜单名、一排立体书脊。
///
/// 榜名切换仍是原地换数据（`RankMixContentHolder.K7`）；书脊阵列由
/// [HomeRankShelf] 绘制，墨水屏和「减少动效」下按整本切换。
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
    final palette = HomePalette.of(context);
    final names = homeRankNames(cell);
    final title = cell.name.isEmpty ? '排行榜' : cell.name;
    if (AppStyleTokens.of(context).isClassic) {
      return ClassicHomeRankRail(
        title: title,
        names: names,
        selectedIndex: _index,
        books: books,
        loading: _loading,
        onSelect: _select,
        onOpen: widget.onOpen,
        onMore: widget.onMore,
      );
    }
    final stepped = palette.eink || MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionLabel(
          code: '01 / RANKING',
          title: title,
          action: HomeBlockMore(onTap: widget.onMore),
          // 首页分类条下面的第一段：顶部留白与标签条的下缘一起构成
          // 「标签 → 排行榜」的间距，用默认 16 会空出近 38dp。
          topPadding: 8,
        ),
        if (names.length > 1)
          _BoardNames(names: names, selectedIndex: _index, onSelect: _select),
        const SizedBox(height: 8),
        if (_loading)
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: HomeRankShelf.loadingHeight(
                context,
                constraints.maxWidth,
              ),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.eink ? palette.ink : HomePalette.accent,
                  ),
                ),
              ),
            ),
          )
        else
          HomeRankShelf(books: books, onOpen: widget.onOpen, stepped: stepped),
      ],
    );
  }
}

/// 榜名保留全部真实选项，选中态用浅底与字重区分，避免抢走书架焦点。
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
          for (var index = 0; index < names.length; index++) ...[
            if (index > 0) const SizedBox(width: 6),
            Semantics(
              selected: index == selectedIndex,
              child: HomePressable(
                onTap: () => onSelect(index),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: index == selectedIndex
                          ? (palette.eink ? palette.mark : palette.soft)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: palette.line),
                    ),
                    child: Text(
                      names[index],
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.1,
                        fontWeight: index == selectedIndex
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: index == selectedIndex
                            ? (palette.eink ? palette.canvas : palette.ink)
                            : palette.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
