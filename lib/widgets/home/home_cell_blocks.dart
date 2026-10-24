import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';
import '../../services/poster_cache.dart';
import 'home_cell_renderers.dart';
import 'home_design.dart';

/// Block widgets for the bookstore feed, following the official layouts.
///
/// Sizes and structure come from the decompiled client rather than from
/// guesswork:
///
/// * `asb.xml` — the `RankCellV3` (511) block: **no card background**, 16dp
///   side margins, 14dp bottom margin, a 20dp top gap, a 32dp rank-name strip
///   (`TextRankLayout`) and 「更多」 on the right.
/// * `widge/o.java` — the rank preview under that strip: pages of **four**
///   rows, each page swiped horizontally, one row per book; the row itself is
///   `b8w.xml` — cover 44×66, a 22dp index column, 14sp title, 12sp subtitle.
/// * `av1.xml` — the `MixedDataInUnlimited` (339) card used by 「猜你喜欢」:
///   68×102 cover, 16sp title, two-line 12sp abstract, 22dp bottom padding.
/// * `StaggeredFeedLayout` / `us3.a.r` — that card stream is a **two column**
///   staggered grid on phones.
/// * `axb.xml` + `m0.java` case 82 — that stream hides its own title and its
///   filter row, so 「猜你喜欢」 renders as cards only.
///
/// The official client keeps these as separate holders dispatched by
/// `show_type`; the shapes are reproduced here, not the holder plumbing.

// ── Block frame (`asb.xml` / `as_`) ────────────────────────────────────────

const double _blockSideMargin = 16;
const double _blockBottomMargin = 14;

// ── Rank block (`asb.xml`, `widge/o.java`) ─────────────────────────────────

const double _rankStripHeight = 32;
/// `asb.xml` 头部 `marginTop=20dp`。2026-10-24 用户拍板不对齐官方：
/// 首页顶栏到排行榜条按视觉收紧，实测节奏（字形间距离）调到
/// tab→榜名条 ~24dp < 榜名条→预览首行 ~16dp 的倒挂消失，行间 ~12dp。
/// tab 条自身保留 bottomPadding=4 作为吸顶时与内容的缓冲。
const double _rankStripTopMargin = 0;

/// End margin of the title row (`asb.xml` `@id/ex` `layout_marginEnd="16dp"`),
/// which is what separates the strip from 「更多」.
const double _rankStripTabGap = 16;

/// Per-item inset of the strip's `ta5.c(1, 0)` decoration: `i(8)` puts 8dp on
/// each side of a middle item, so two neighbours sit 16dp apart. The first item
/// takes `k(16)`'s 16dp on its left; the last one ends flush at the right edge
/// because `l(0)` leaves that side empty.
const double _rankStripItemInset = 8;
const double _rankStripSelectedSize = 16;
const double _rankStripIdleSize = 14;
const double _rankStripIdleAlpha = 0.4;
/// 榜名条到预览首行的间距（`asb.xml` 为 8dp）。2026-10-24 用户拍板不对齐
/// 官方：标题贴近内容，8 → 2（见 [_rankStripTopMargin] 的节奏说明）。
const double _rankStripContentGap = 2;

/// `o.getPages()` returns 4 (3 only for the oversized-font path).
const int _rankRowsPerPage = 4;
const double _rankRowPadding = 6;
const double _rankCoverWidth = 44;
const double _rankCoverHeight = 66;

/// Index column width in `b8w.xml` (`@id/ggr`, `layout_width="22dp"`).
const double _rankIndexWidth = 22;
const double _rankTitleSize = 14;

/// Title column width in `b8w.xml` (`@id/ftb`, `layout_width="107.0dip"`).
const double _rankTitleWidth = 107;

/// One row's content width: cover + index + title column (`b8w.xml` children,
/// which is what the wrap-content page measures against).
const double _rankRowWidth =
    _rankCoverWidth + _rankIndexWidth + _rankTitleWidth;

/// One page of the preview (`cbs.xml`): 16dp start / 4dp end padding around
/// four wrap-content rows, laid out as its own page in a horizontal list.
///
/// The official pager keeps `layout_width="-2"` (wrap content) on every page
/// but the last (`o$g$a.onBind`), so on a phone two pages sit side by side —
/// the「第二列」the device dump shows is page 2, not a second grid column.
const double _rankPageStartPadding = 16;
const double _rankPageEndPadding = 4;
const double _rankPageSize =
    _rankRowWidth + _rankPageStartPadding + _rankPageEndPadding;

/// Subtitle line under the title (`b8w.xml` `e44` + the TagLayout the binding
/// revives): 12sp `skin_color_gray_40_light`, one line, 4dp below the title.
const double _rankSubtitleSize = 12;
const double _rankSubtitleTopGap = 4;

/// Top-three index colour in `b8w.xml`: `SkinDelegate.setTextColor(view,
/// 2131561676)` = `skin_color_FFDCAD6D_rank_light` = #FFDCAD6D; the rest keep
/// `@color/abd` = `skin_color_black_light` (#FF000000).
const Color _rankTopIndexColor = Color(0xFFDCAD6D);

// ── Book card ──────────────────────────────────────────────────────────────
//
// The card's authoritative spec is the server template `single_book_v0.0.2`
// (`data.tab_item[<bookstore>].static_configs`, filled into the KMP DSL
// renderer — the APK ships only the interpreter). Values below mirror that
// JSON, kept in `build/card_template.json` for reference:
//
//   root      vertical LinearLayout, fill×wrap, cornerRadius 8, bg #FFFFFFFF
//   cover     fill×wrap, ratio 1.4 (height = width × 1.4), grey placeholder
//   scrim     fill×32dp over the cover bottom, #00000000 → #00000026
//   score     white 12sp Medium badge on the cover, margin{left:10,bottom:8},
//             shadow radius 1 #000000CC, `#score_0`, 1 line
//   text box  padding{left:10, top:8, right:10, bottom:12}
//   title     `#title_0`, 2 lines, 14sp Medium, #FF000000, lineSpace 4
//   abstract  margin-top 4, `#abstract_0`, 2 lines, 12sp, #00000066,
//             lineSpace 3 + lineMultiply 1.6
//   tags      margin-top 4 (`#tag_list_0` — not parsed yet, skipped)

/// Cover height = column width × 1.4（模板 `imageConfig.ratio`）。
const double _cardCoverHeightRatio = 1.4;

const double _cardTitleSize = 14;
const double _cardMetaSize = 12;
const double _cardScoreSize = 12;

/// 标签行（模板 root/1/2 `#tag_list_0`）：chip 12sp、圆角 4dp、内边距
/// 水平 4 / 垂直 1、chip 间距 4dp（KMP `TagListViewKt` smali 常量）。
const double _cardTagSize = 12;

/// 文本区 padding（模板 root/1）。
const EdgeInsets _cardTextPadding = EdgeInsets.fromLTRB(10, 8, 10, 12);

/// 标题行高 = pointSize + lineSpace 4（模板 paragraphStyle）。
const double _cardTitleLineExtra = 4;

/// 简介行高 = pointSize × 1.6 + lineSpace 3（模板 paragraphStyle）。
const double _cardAbstractLineMultiply = 1.6;
const double _cardAbstractLineExtra = 3;

/// 模板暗色值（darkHex）：卡底 #1C1C1C、标题 #FFFFFFCC、简介 #66FFFFFF。
const Color _cardDarkBg = Color(0xFF1C1C1C);

// ── Card grid ──────────────────────────────────────────────────────────────

/// Column gutter, measured from the device.
///
/// S0 dumped the two card columns at x36-598 and x622-1184 on a 1220px-wide
/// screen: the gap is 24px = **8dp**, and the outer margin is 36px = 12dp —
/// now source-confirmed (`DoubleRowMarginConfig` defaults item_spacing=8 /
/// left_margin=12, `k1.java:1247`, `ta5/j.java`).
const double _gridGap = 8;
const double _gridRowGap = 8;

/// The card stream as the official `StaggeredFeedLayout` shapes it.
///
/// `us3.a.r` renders 「猜你喜欢」 as a **staggered** grid (two columns on
/// phones): each card takes its own height, so a card without an abstract or
/// without tag chips is simply shorter. A uniform `mainAxisExtent` instead
/// reserved the worst case — two-line abstract plus tag row — for every cell,
/// leaving 30–50dp of dead space on roughly half the stream and stretching
/// the feed's scroll length by the same amount.
SliverMasonryGrid homeBookMasonry(
  BuildContext context, {
  required IndexedWidgetBuilder itemBuilder,
  required int childCount,
}) => SliverMasonryGrid.count(
  crossAxisCount: homeColumnCount(context),
  crossAxisSpacing: _gridGap,
  mainAxisSpacing: _gridRowGap,
  itemBuilder: itemBuilder,
  childCount: childCount,
);

/// Columns for the card stream — a direct port of `us3.a.q()`.
///
/// ```java
/// public static final int q() {
///     float d = f.d(context);          // screen short side, dp
///     if (b() && d >= 1366f) return 5;
///     if (b() && d >= 1024f) return 4;
///     if (b() && d >= 516f)  return 3;
///     return 2;
/// }
///
/// public static final boolean b() {
///     return x.b.needFitPadScreen() && StorePadAdapt.a.a();  // pad adapt
/// }
/// ```
///
/// Every non-phone branch is guarded by `b()`, the pad-adapt flag, so a phone
/// is always 2 columns regardless of width — the 516/1024/1366 breakpoints
/// only apply on tablets. [padAdapt] mirrors `b()` and defaults to `false`.
///
/// Hard-coding 2 would look equivalent on a phone and break on a foldable, so
/// the breakpoints are kept.
int homeColumnCount(BuildContext context, {bool padAdapt = false}) {
  if (!padAdapt) return 2;
  final shortSide = MediaQuery.sizeOf(context).shortestSide;
  if (shortSide >= 1366) return 5;
  if (shortSide >= 1024) return 4;
  if (shortSide >= 516) return 3;
  return 2;
}

/// 「更多」 on a block header: 14sp label plus the 4×7 arrow (`asb.xml`).
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
            style: TextStyle(fontSize: 14, height: 1.2, color: palette.ink),
          ),
          const SizedBox(width: 4),
          Icon(LucideIcons.chevron_right, size: 12, color: palette.muted),
        ],
      ),
    );
  }
}

/// Rank-name strip (`TextRankLayout`, 32dp high).
///
/// The selected board is 16sp, the rest 14sp; both are bold and the idle ones
/// sit at 40% alpha (`TextRankLayout.T1` / `X1`, the latter only dropping to a
/// regular face behind the `topTabUnselectedFontWeightOptimize` AB flag).
/// Tapping a name switches the preview in place (`RankMixContentHolder.K7`);
/// when the block carries no board ids the tap falls through to [onMore].
///
/// Spacing comes from the strip's own `ta5.c(1, 0)` decoration
/// (`TextRankLayout` constructor): `i(8)` puts 8dp on each side of every middle
/// item — a 16dp gap — the first item takes `k(16)`'s 16dp on its left, and the
/// last item ends flush because `l(0)` leaves its right side empty. A lone name
/// instead takes the `k(16)`/`l(0)` pair wholesale, i.e. 16dp left and nothing
/// on the right.
class HomeRankStrip extends StatelessWidget {
  const HomeRankStrip({
    super.key,
    required this.names,
    this.selectedIndex = 0,
    this.onSelect,
  });

  final List<String> names;
  final int selectedIndex;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: _rankStripHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < names.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  left: i == 0 ? _rankStripItemInset * 2 : _rankStripItemInset,
                  right: i == names.length - 1 ? 0 : _rankStripItemInset,
                ),
                child: GestureDetector(
                  onTap: onSelect == null ? null : () => onSelect!(i),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Text(
                      names[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: i == selectedIndex
                            ? _rankStripSelectedSize
                            : _rankStripIdleSize,
                        height: 1.2,
                        // Both states are bold: `TextRankLayout.T1` (selected)
                        // and `X1` (idle) each call `setTypeface(P1(1))`; `X1`
                        // only drops to `P1(0)` behind the
                        // `topTabUnselectedFontWeightOptimize` AB flag, which is
                        // off by default. Size and the 0.4 alpha carry the state.
                        fontWeight: FontWeight.w700,
                        color: i == selectedIndex
                            ? palette.ink
                            : palette.ink.withValues(
                                alpha: _rankStripIdleAlpha,
                              ),
                      ),
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

/// The rank preview: a horizontal list of pages, four rows each.
///
/// `o$g$a` measures the pages `wrap_content` (`cbs.xml` is a FrameLayout
/// around a vertical RecyclerView), so the pager shows the current page and
/// the next one side by side on a phone — the whole strip scrolls left for
/// more boards' entries. A full-width `PageView` would instead hide every
/// other page, which is what the previous implementation drew.
class HomeRankPreview extends StatelessWidget {
  const HomeRankPreview({
    super.key,
    required this.books,
    required this.onOpen,
    this.rowsPerPage = _rankRowsPerPage,
  });

  final List<MediaItem> books;
  final ValueChanged<MediaItem> onOpen;
  final int rowsPerPage;

  /// Row height: `b8w.xml` fixes the row at the 66dp cover, so the cover plus
  /// its 6dp paddings is the pitch; the text column only wins at text scales
  /// where the title-plus-subtitle stack outgrows it.
  static double rowExtent(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final title = scaler.scale(_rankTitleSize) * 1.3;
    final subtitle =
        _rankSubtitleTopGap + scaler.scale(_rankSubtitleSize) * 1.3;
    return math.max(
      _rankCoverHeight + _rankRowPadding * 2,
      title + subtitle + _rankRowPadding * 2 + 4,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (books.isEmpty) return const SizedBox.shrink();
    final extent = rowExtent(context);
    final pageCount = (books.length / rowsPerPage).ceil();
    return SizedBox(
      height: extent * rowsPerPage,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemExtent: _rankPageSize,
        itemCount: pageCount,
        itemBuilder: (context, page) {
          final start = page * rowsPerPage;
          final end = math.min(start + rowsPerPage, books.length);
          return Padding(
            padding: const EdgeInsets.only(
              left: _rankPageStartPadding,
              right: _rankPageEndPadding,
            ),
            child: Column(
              children: [
                for (var i = start; i < end; i++)
                  SizedBox(
                    height: extent,
                    width: _rankRowWidth,
                    child: HomeRankRow(
                      item: books[i],
                      index: i,
                      onTap: () => onOpen(books[i]),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One rank row matching `b8w.xml`: cover 44×66, 22dp index column, a
/// 107dp title column with the rank-tag subtitle under the title.
///
/// The subtitle is the row's `secondary_info_list` rendered by the TagLayout
/// the binding revives (`o$g$a.b2` → `bindRankTags`) — 「多人二刷 · 9320万热度」.
/// With no tags the row is just the title line, same as before.
class HomeRankRow extends StatelessWidget {
  const HomeRankRow({
    super.key,
    required this.item,
    required this.index,
    required this.onTap,
  });

  final MediaItem item;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final tags = item.rankTags;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _rankRowPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(
              url: item.cover,
              width: _rankCoverWidth,
              height: _rankCoverHeight,
              palette: palette,
              radius: 4,
            ),
            SizedBox(
              width: _rankIndexWidth,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _rankTitleSize,
                    fontWeight: FontWeight.w700,
                    color: index < 3 ? _rankTopIndexColor : palette.ink,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: _rankTitleWidth,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _rankTitleSize,
                        height: 1.3,
                        color: palette.ink,
                      ),
                    ),
                    if (tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: _rankSubtitleTopGap,
                        ),
                        child: Text(
                          tags.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: _rankSubtitleSize,
                            height: 1.3,
                            color: palette.body,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One book card matching `av1.xml`: cover on the left, a single title line with
/// the score on its right, then the two-line abstract.
///
/// `av1.xml` has no author row — the author reaches the card through the tag
/// layout (`bp`, filled by `vb4.c.c`), which this client does not render yet —
/// and `aj4` is `android:lines="1"`, so a long title is ellipsised rather than
/// wrapped.
class HomeBookCard extends StatelessWidget {
  const HomeBookCard({super.key, required this.item, required this.onTap});

  final MediaItem item;
  final VoidCallback onTap;

  /// Score formatting: `9.3分`（模板 `#score_0` 的服务端 formatter 同款）。
  static String _scoreText(double score) => score == score.roundToDouble()
      ? score.toStringAsFixed(0)
      : score.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final dark = palette.dark;
    final abstract = item.intro;
    final score = item.score;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        // 模板 root：白底（暗色 #1C1C1C）8dp 圆角卡，圆角裁住封面。
        decoration: BoxDecoration(
          color: dark ? _cardDarkBg : Colors.white,
          borderRadius: BorderRadius.circular(_cardRadius),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_cardRadius),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 封面：高 = 宽 × 1.4；评分角标与压暗渐变叠在其上。
                  SizedBox(
                    width: double.infinity,
                    height: width * _cardCoverHeightRatio,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _Cover(
                          url: item.cover,
                          width: width,
                          height: width * _cardCoverHeightRatio,
                          palette: palette,
                          radius: 0,
                        ),
                        // 模板 scrim：封面底部 32dp，透明 → 15% 黑。
                        const Align(
                          alignment: Alignment.bottomCenter,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x00000000),
                                    Color(0x26000000),
                                  ],
                                ),
                              ),
                              child: SizedBox(
                                width: double.infinity,
                                height: _cardScrimHeight,
                              ),
                            ),
                          ),
                        ),
                        // 模板评分角标：左下 10/8，白 12sp Medium + 阴影。
                        if (score != null)
                          Positioned(
                            left: 10,
                            bottom: 8,
                            child: Text(
                              '${_scoreText(score)}分',
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: _cardScoreSize,
                                fontWeight: FontWeight.w500,
                                color: dark
                                    ? const Color(0xCCFFFFFF)
                                    : Colors.white,
                                shadows: const [
                                  Shadow(
                                    color: Color(0xCC000000),
                                    blurRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: _cardTextPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: _cardTitleSize,
                            // lineHeight = pointSize + lineSpace 4。
                            height:
                                (_cardTitleSize + _cardTitleLineExtra) /
                                _cardTitleSize,
                            fontWeight: FontWeight.w500,
                            color: dark
                                ? const Color(0xCCFFFFFF)
                                : const Color(0xFF000000),
                          ),
                        ),
                        if (abstract.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            abstract,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _cardMetaSize,
                              // lineHeight = pointSize × 1.6 + lineSpace 3。
                              height:
                                  (_cardMetaSize * _cardAbstractLineMultiply +
                                      _cardAbstractLineExtra) /
                                  _cardMetaSize,
                              color: dark
                                  ? const Color(0x66FFFFFF)
                                  : const Color(0x66000000),
                            ),
                          ),
                        ],
                        if (item.recTags.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final tag in item.recTags)
                                _RecTagChip(tag: tag, dark: dark),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 模板 root `layoutConfig.cornerRadius` = 8dp（`single_book_v0.0.2`）。
const double _cardRadius = 8;

/// 模板 scrim 高度（root/0/1 `height: 32`）。
const double _cardScrimHeight = 32;

class _Cover extends StatelessWidget {
  const _Cover({
    required this.url,
    required this.width,
    required this.height,
    required this.palette,
    this.radius = 4,
  });

  final String url;
  final double width;
  final double height;
  final HomePalette palette;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(color: palette.soft);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? fallback
            : CachedNetworkImage(
                // 同一张封面在旧管线（StoryCover）走 PosterCache 磁盘缓存
                // 并按格子尺寸解码；裸 Image.network 只有内存缓存且按原图
                // 分辨率解码，冷启动全量重下、快速滑动时反复重解码。
                cacheManager: PosterCache.instance,
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth:
                    (width * MediaQuery.devicePixelRatioOf(context))
                        .ceil()
                        .clamp(1, 1200),
                fadeInDuration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
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

bool _flag(Map<String, dynamic> style, String key) {
  final value = style[key];
  return value == true || value == 1 || value == 'true';
}

/// `hide_title` — set by the upstream on the 384 wrapper when it remembers
/// to. `m0.java` case 82 forces the card stream's title off either way, so
/// the two stream show types hide unconditionally here too; that is why
/// 「猜你喜欢」 never renders a section title even when the live payload
/// drops the flag.
bool homeHidesTitle(HomeCell cell) =>
    cell.showType == kHomeCellMixedFeed ||
    cell.showType == kHomeCellDoubleRowFeed ||
    _flag(cell.style, 'hide_title') ||
    cell.children.any((child) => _flag(child.style, 'hide_title'));

/// Loads one rank board for the preview: `(rankId, algo) → books`.
///
/// Injected so the block stays testable; the page wires it to
/// `ApiClient.rankBoard`.
typedef HomeRankLoader =
    Future<List<MediaItem>> Function(String rankId, int algo);

/// `RankCellV3`(511): rank-name strip, 「更多」, then the four-row preview.
///
/// `asb.xml` has no card background — the strip sits directly on the page
/// background (the archived official screenshot samples #F2–#F7 there, the
/// canvas, not card white), unlike the generic card blocks.
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

/// The 511 block, stateful because the strip switches boards in place
/// (`RankMixContentHolder.K7` → `H7` fetch → `R.i(1, true, null, …)`).
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
  /// Board picked from the strip; 0 is what the upstream previews
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
    final ranks = homeRankNames(cell);
    final title = cell.name.isEmpty ? '排行榜' : cell.name;
    // `asb.xml` root: 16dp margins on both sides, 14dp under the block, no
    // background of its own. The title row (`@id/ex`) takes another 16dp on
    // its end side; the pager's 16dp start / 4dp end padding live on each
    // page (`cbs.xml`), not here, so the three rows cannot share one inset.
    return Container(
      margin: const EdgeInsets.only(
        left: _blockSideMargin,
        right: _blockSideMargin,
        bottom: _blockBottomMargin,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              top: _rankStripTopMargin,
              right: _blockSideMargin,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: ranks.isEmpty
                      ? Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                          ),
                        )
                      // 榜名条本身就是这一块的标题行(`asb.xml` 的 `ex` 里没有
                      // 单独的标题 TextView)。
                      : HomeRankStrip(
                          names: ranks,
                          selectedIndex: _index,
                          onSelect: _select,
                        ),
                ),
                const SizedBox(width: _rankStripTabGap),
                HomeBlockMore(onTap: widget.onMore),
              ],
            ),
          ),
          const SizedBox(height: _rankStripContentGap),
          // The 「左滑查看更多」footer is *not* reproduced: it lives in the
          // optional 2131035687 footer that `RankCodeOptimizeHelper.p` turns
          // off with `N(false)` for every rank preview, so the official block
          // never renders it either.
          if (_loading)
            SizedBox(
              height: HomeRankPreview.rowExtent(context) * _rankRowsPerPage,
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
            HomeRankPreview(
              key: ValueKey<int>(_index),
              books: books,
              onOpen: widget.onOpen,
            ),
        ],
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

/// One tag chip（KMP `TagListViewKt`：12sp、圆角 4dp、padding 4/1）。
class _RecTagChip extends StatelessWidget {
  const _RecTagChip({required this.tag, required this.dark});

  final MediaRecTag tag;
  final bool dark;

  /// Wire `#RRGGBBAA` → Flutter `AARRGGBB`；解析失败回退 [fallback]。
  static Color? _color(String hex, Color? fallback) {
    final h = hex.trim();
    if (h.length == 9 && h.startsWith('#')) {
      final value = int.tryParse('FF${h.substring(1, 7)}', radix: 16);
      final alpha = int.tryParse(h.substring(7, 9), radix: 16);
      if (value != null) {
        return Color(value).withValues(alpha: (alpha ?? 255) / 255);
      }
    }
    if (h.length == 7 && h.startsWith('#')) {
      final value = int.tryParse('FF${h.substring(1)}', radix: 16);
      if (value != null) return Color(value);
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final text = _color(
      dark ? tag.darkTextColor : tag.textColor,
      dark ? const Color(0xCCFFFFFF) : const Color(0x99000000),
    )!;
    final bg = _color(dark ? tag.darkBgColor : tag.bgColor, null);
    final label = Text(
      tag.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: _cardTagSize, height: 1.2, color: text),
    );
    if (bg == null) return label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: label,
    );
  }
}
