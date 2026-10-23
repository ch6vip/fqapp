import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';
import '../../services/app_links.dart';
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
const double _rankStripTopMargin = 20;

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
const double _rankStripContentGap = 8;

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
// Vertical card (S0 verdict): cover across the full column, then score, title
// and abstract stacked underneath. The official grid is Compose-rendered, so
// only pixels were available — see `homeCardCoverAspect`.

const double _cardTitleSize = 16;
const double _cardMetaSize = 12;

/// Bottom padding of the card (`av1.xml` root `paddingBottom="22.0dip"`).
const double _cardBottomPadding = 22;

/// `j6.e` renders the score as digits plus a「分」suffix in brand orange
/// (#FFFA6725 = `skin_color_orange_brand_light`). `InfiniteSingleBookHolder`
/// passes `.n(16)` — `aVar.c`, the size used when a score exists — so the line
/// is 16sp; only the digits are bold (`aVar.k`'s `StyleSpan(1)`).
const Color _scoreColor = Color(0xFFFA6725);
const double _scoreSize = 16;

// ── Card grid ──────────────────────────────────────────────────────────────

/// Column gutter, measured from the device.
///
/// S0 dumped the two card columns at x36-598 and x622-1184 on a 1220px-wide
/// screen: the gap is 24px = **8dp**, and the outer margin is 36px = 12dp.
/// (`av1.xml`'s own 16dp margins belong to the single-column `av1` surface,
/// not this grid.)
const double _gridGap = 8;
const double _gridRowGap = 8;

// ── 书荒广场 topic card (`axy.xml` / `bdr.xml` / `dap.xml`) ────────────────

/// Fallback title: `bv2.r3` writes 「书荒广场」 whenever `cell_name` is empty.
const String _topicFallbackTitle = '书荒广场';

/// `axy.xml` `icon` is 16×16dp; `b07` is 14sp with `maxLength="6"`.
const double _topicIconSize = 16;
const double _topicHeaderSize = 14;
const double _topicMoreSize = 12;
const double _topicTopPadding = 16;
const double _topicBottomPadding = 16;

/// `axy.xml` draws the rows edge to edge; `bdr.xml` keeps 10dp on each side.
const double _topicCardInset = 10;

/// `bdr.xml` row: 40×56 cover, `ibg` 12sp over two lines, `htk` 10sp tips.
const double _topicCoverWidth = 40;
const double _topicCoverHeight = 56;
const double _topicTitleSize = 12;
const double _topicTipsSize = 10;
const double _topicTitleGap = 8;
const double _topicTipsGap = 4;

/// Row pitch between two topics: `drawable/aob.xml` is a 14dp transparent gap.
const double _topicRowGap = 14;

/// `dap.xml` pill: 12sp brand orange on a 10% tint, 6dp/12dp padding.
const double _topicPillSize = 12;
const double _topicPillInsetX = 12;
const double _topicPillInsetY = 6;
const Color _topicOrange = Color(0xFFFA6725);
const Color _topicOrangeTint = Color(0x1AFA6725);

/// Height of one card cell.
///
/// Vertical card (S0 verdict): cover on top at the full column width, then
/// score, title (2 lines) and the 2-line abstract.
///
/// The cover height depends on the column width, and the column width depends
/// on the screen — so the caller passes [columnWidth]. Height still follows the
/// text scale, otherwise a large-font device would clip the abstract.
double homeBookCardExtent(BuildContext context, {required double columnWidth}) {
  final scaler = MediaQuery.textScalerOf(context);
  final cover = columnWidth / homeCardCoverAspect;
  final score = scaler.scale(_scoreSize) * 1.25 + _cardTitleGap;
  final title = scaler.scale(_cardTitleSize) * 1.25 * 2;
  final abstract = _cardAbstractGap + scaler.scale(_cardMetaSize) * 1.45 * 2;
  return cover + _cardTitleGap + score + title + abstract + _cardBottomPadding;
}

/// Column width for a card block, given the width available to the cards.
///
/// Mirrors the grid math so [homeBookCardExtent] and the actual layout cannot
/// disagree by a rounding step.
double homeCardColumnWidth(BuildContext context, double available) {
  final columns = homeColumnCount(context);
  return (available - _gridGap * (columns - 1)) / columns;
}

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

/// Grid delegate for callers that still render a real [SliverGrid].
///
/// `mainAxisExtent` tracks [homeColumnCount] and [available] so a wide screen
/// neither stretches the columns nor keeps a phone-sized card height.
SliverGridDelegate homeBookGridDelegate(
  BuildContext context, {
  required double available,
}) => SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: homeColumnCount(context),
  crossAxisSpacing: _gridGap,
  mainAxisSpacing: _gridRowGap,
  mainAxisExtent: homeBookCardExtent(
    context,
    columnWidth: homeCardColumnWidth(context, available),
  ),
);

/// The 书荒广场 card (`axy.xml`, holder `bv2.r3`).
///
/// This is the one card in the feed that carries no `book_data`: `m0.java:1501`
/// turns it into a `StaggeredUgcModel` whose rows are `topic_data[]`. It is a
/// normal grid cell, not a full-width banner — the staggered span check
/// (`c1.B4` → `gt3.f.a.f`) returns false for it, so upstream gives it one
/// column, which is what [HomeTopicCard] assumes.
///
/// Two shapes exist, picked by `style.dynamic_card_move_title_and_entry_to_bottom`
/// (`bv2.r3.n4()` → `m4`/`r4`). The real feed sets it, which hides the header
/// row (icon + title + 「更多」) and moves the entry to a pill at the bottom of
/// the card. The other shape is kept because the flag is upstream-controlled.
class HomeTopicCard extends StatelessWidget {
  const HomeTopicCard({super.key, required this.cell});

  final HomeCell cell;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final moveToBottom = _flag(
      cell.style,
      'dynamic_card_move_title_and_entry_to_bottom',
    );
    final title = cell.name.isEmpty ? _topicFallbackTitle : cell.name;
    final rowHeight = _topicRowHeight(context);

    return GestureDetector(
      // `bv2.r3.r3` opens the card target on the whole card, but only when the
      // pill is configured at all (`ShuhuangMoreButtonPosition != None`).
      onTap: () => openAppLink(context, cell.url),
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: palette.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _topicCardInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!moveToBottom) _header(context, palette, title),
              Padding(
                padding: EdgeInsets.only(
                  top: moveToBottom ? _topicTopPadding : 0,
                ),
                child: Column(
                  children: [
                    for (final topic in cell.topics)
                      Padding(
                        padding: const EdgeInsets.only(bottom: _topicRowGap),
                        child: SizedBox(
                          height: rowHeight,
                          child: _TopicRow(
                            topic: topic,
                            palette: palette,
                            rowHeight: rowHeight,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: _topicBottomPadding),
                child: Center(child: _pill(context, title)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `axy.xml` header: 16dp topic icon, 14sp title (`b07`) and 「更多」.
  Widget _header(BuildContext context, HomePalette palette, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: _topicTopPadding),
      child: Row(
        children: [
          Icon(LucideIcons.hash, size: _topicIconSize, color: palette.muted),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _topicHeaderSize,
                height: 1.2,
                color: palette.ink,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => openAppLink(context, cell.url),
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '更多',
                  style: TextStyle(
                    fontSize: _topicMoreSize,
                    color: palette.ink,
                  ),
                ),
                Icon(LucideIcons.chevron_right, size: 12, color: palette.muted),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The `dap.xml` pill: 12sp brand orange on a 10% orange capsule.
  Widget _pill(BuildContext context, String label) {
    return GestureDetector(
      onTap: () => openAppLink(context, cell.url),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: _topicPillInsetX,
          vertical: _topicPillInsetY,
        ),
        decoration: BoxDecoration(
          color: _topicOrangeTint,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: _topicPillSize,
                // Explicit height: the extent computed in `homeTopicCardExtent`
                // has to match what the text actually measures, and an inherited
                // line height would silently add a pixel or two per line.
                height: 1.2,
                color: _topicOrange,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              LucideIcons.chevron_right,
              size: 12,
              color: _topicOrange,
            ),
          ],
        ),
      ),
    );
  }
}

/// One row of the 书荒广场 card (`bdr.xml`): 40×56 cover, two title lines and
/// the 10sp `card_tips` line, which upstream bottom-aligns to the cover.
class _TopicRow extends StatelessWidget {
  const _TopicRow({
    required this.topic,
    required this.palette,
    required this.rowHeight,
  });

  final HomeTopic topic;
  final HomePalette palette;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => openAppLink(context, topic.url),
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Cover(
            url: topic.cover,
            width: _topicCoverWidth,
            height: _topicCoverHeight,
            palette: palette,
          ),
          const SizedBox(width: _topicTitleGap),
          Expanded(
            child: SizedBox(
              height: rowHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    topic.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _topicTitleSize,
                      // `ibg` carries `lineSpacingExtra="3dp"`.
                      height: 1.45,
                      color: palette.ink,
                    ),
                  ),
                  if (topic.tips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: _topicTipsGap),
                      child: Text(
                        topic.tips,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _topicTipsSize,
                          height: 1.2,
                          color: palette.muted,
                        ),
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

/// Height of the 书荒广场 card: rows, the pill and the two paddings.
///
/// The card is taller than a book card, which is why a block holding one is
/// laid out row by row instead of with the fixed-extent [homeBookGridDelegate].
double homeTopicCardExtent(BuildContext context, {int rows = 3}) {
  final scaler = MediaQuery.textScalerOf(context);
  final pill = scaler.scale(_topicPillSize) * 1.2 + _topicPillInsetY * 2;
  final count = math.max(1, rows);
  return _topicTopPadding +
      count * _topicRowHeight(context) +
      count * _topicRowGap +
      pill +
      _topicBottomPadding;
}

/// One row's height: the cover, or the two title lines plus the tips.
double _topicRowHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final text =
      scaler.scale(_topicTitleSize) * 1.45 * 2 +
      _topicTipsGap +
      scaler.scale(_topicTipsSize) * 1.2;
  return math.max(_topicCoverHeight, text);
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

  /// Score formatting shared with [homeBookCardExtent].
  static String _scoreText(double score) => score == score.roundToDouble()
      ? score.toStringAsFixed(0)
      : score.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final abstract = item.intro;
    final score = item.score;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Vertical card (S0 verdict): the cover fills the column width and
          // the text stacks underneath. The official grid is rendered by
          // Compose (`epx` = ComposeView), so `uiautomator` exposes only the
          // text nodes — but pixel scanning of the card region shows the cover
          // spanning the full column (562/562 px) from y1565 to y2285, with a
          // pure text area below it. `av1`/`av2` (68x102 cover, text right) is
          // a different surface, not this one.
          final width = constraints.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(
                url: item.cover,
                width: width,
                height: width / homeCardCoverAspect,
                palette: palette,
                radius: homeCardCoverRadius,
              ),
              const SizedBox(height: _cardTitleGap),
              if (score != null)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _scoreText(score),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: '分'),
                    ],
                  ),
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: _scoreSize,
                    height: 1.25,
                    color: _scoreColor,
                  ),
                ),
              if (score != null) const SizedBox(height: _cardTitleGap),
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _cardTitleSize,
                  height: 1.25,
                  // `skin_color_black_light` = #ff000000.
                  color: palette.ink,
                ),
              ),
              if (abstract.isNotEmpty) ...[
                const SizedBox(height: _cardAbstractGap),
                Text(
                  abstract,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _cardMetaSize,
                    height: 1.45,
                    // `skin_color_gray_40_light` = #66000000.
                    color: palette.body,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Aspect ratio of the cover in the card stream.
///
/// Measured from the device, not from a layout file: the card is Compose in
/// the official client, so only pixels are available. The cover occupied
/// ~562 x 240 px at 187dp column width, i.e. roughly 2.34:1. Kept as a ratio
/// so a different cover image cannot be cropped short.
const double homeCardCoverAspect = 2.34;

/// `app:roundedCornerRadius="4.0dip"` on `ScaleBookCover` (`cgw.xml`).
const double homeCardCoverRadius = 4;

/// Gap between the cover and the first text line.
const double _cardTitleGap = 8;

/// Gap before the abstract (`av2.xml` `qg` `layout_marginTop="8.0dip"`).
const double _cardAbstractGap = 8;

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
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? ColoredBox(color: palette.soft)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(color: palette.soft),
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

/// `hide_title` — set by the upstream on the 384 wrapper, and forced on the
/// 385 one inside `m0.java` (`case 82`).
bool homeHidesTitle(HomeCell cell) =>
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

/// A two-column card block as a sliver (`av1.xml` cards, spanCount 2).
///
/// The block title is dropped when the block asks for it (`hide_title`), which
/// is how 「猜你喜欢」 arrives and how `m0.java` forces the 385 wrapper.
///
/// Cards come from [homeCellEntries] rather than [HomeCell.flatten], because
/// the 书荒广场 card in this stream is not a book at all — it has to keep its
/// place in the grid instead of collapsing the cells after it.
Widget buildCardSectionSliver(
  BuildContext context,
  HomeCell cell, {
  required ValueChanged<MediaItem> onOpen,
  required double gridWidth,
  VoidCallback? onMore,
}) {
  final entries = homeCellEntries(cell);
  if (entries.isEmpty) {
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }
  final showTitle = cell.name.isNotEmpty && !homeHidesTitle(cell);
  return SliverMainAxisGroup(
    slivers: [
      // `as_.xml` `l2` (the card list) carries its own `paddingStart/End=16dp`
      // *inside* the white block card. The card's own 16dp side margin is on
      // `HomeBlockCard`, so this inner 16dp is a second, separate inset.
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: _blockSideMargin),
        sliver: SliverMainAxisGroup(
          slivers: [
            if (showTitle)
              SliverToBoxAdapter(child: HomeSectionTitle(title: cell.name)),
            SliverToBoxAdapter(child: _cardsBlock(context, entries, onOpen)),
            // `as_.xml` `anr`: the `jd.xml` strip, 16dp side / 16dp bottom.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: HomeBlockMoreBooks(onTap: onMore),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// The cards of one block, as a non-scrolling box widget.
///
/// The block is wrapped in [HomeBlockCard] by the caller, so this has to be a
/// plain widget and cannot be a sliver: a white rounded card cannot wrap a
/// sliver list, and a nested `GridView(shrinkWrap: true)` has no bounded
/// height to lay out against.
///
/// Every card here is a book card. 书荒广场 / ad cells are out of scope by
/// request, so there is no mixed-height case left to handle — the previous
/// masonry path existed only for that UGC card and has been removed.
Widget _cardsBlock(
  BuildContext context,
  List<HomeCardEntry> entries,
  ValueChanged<MediaItem> onOpen,
) {
  return _FixedGrid(
    columns: homeColumnCount(context),
    columnSpacing: _gridGap,
    rowSpacing: _gridRowGap,
    children: [for (final entry in entries) _cardFor(entry, onOpen)],
  );
}

/// A fixed-extent grid laid out with plain rows.
///
/// The block sits inside a white rounded card, which is itself a box widget,
/// so a nested scrollable (`GridView(shrinkWrap: true)`) cannot be used there:
/// those grids need a bounded height and the block's height is driven by its
/// card count. Rows and columns avoid the whole problem and match the official
/// layout — `k1.java:459` builds the manager with `setGapStrategy(0)`
/// (`GAP_HANDLING_NONE`), i.e. cards are placed strictly in data order and gaps
/// are never back-filled.
class _FixedGrid extends StatelessWidget {
  const _FixedGrid({
    required this.columns,
    required this.columnSpacing,
    required this.rowSpacing,
    required this.children,
  });

  final List<Widget> children;
  final int columns;
  final double columnSpacing;
  final double rowSpacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Card height depends on the column width (the cover fills it), so the
        // real width is measured here rather than assumed.
        final columnWidth =
            (constraints.maxWidth - columnSpacing * (columns - 1)) / columns;
        final extent = homeBookCardExtent(context, columnWidth: columnWidth);
        final rows = <Widget>[];
        for (var start = 0; start < children.length; start += columns) {
          final slice = children.sublist(
            start,
            math.min(start + columns, children.length),
          );
          rows.add(
            SizedBox(
              height: extent,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < columns; i++) ...[
                    if (i > 0) SizedBox(width: columnSpacing),
                    Expanded(
                      child: i < slice.length
                          ? slice[i]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) SizedBox(height: rowSpacing),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}

/// One block as a plain widget: white card, `as_` title, cards, then the
/// 「更多书籍信息」 strip.
///
/// Used instead of [buildCardSectionSliver] when the caller needs a box widget
/// (a white rounded card cannot wrap a sliver list). Inner 16dp matches
/// `as_.xml` `l2`'s own `paddingStart/End`.
Widget buildCardSection(
  BuildContext context,
  HomeCell cell, {
  required ValueChanged<MediaItem> onOpen,
  required double gridWidth,
  VoidCallback? onMore,
}) {
  final entries = homeCellEntries(cell);
  if (entries.isEmpty) return const SizedBox.shrink();
  final showTitle = cell.name.isNotEmpty && !homeHidesTitle(cell);
  return HomeBlockCard(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: _blockSideMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) HomeSectionTitle(title: cell.name),
          _cardsBlock(context, entries, onOpen),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: HomeBlockMoreBooks(onTap: onMore),
          ),
        ],
      ),
    ),
  );
}

/// One cell of the grid: a book card, or the 书荒广场 card.
Widget _cardFor(HomeCardEntry entry, ValueChanged<MediaItem> onOpen) {
  final item = entry.item;
  if (item != null) {
    return HomeBookCard(item: item, onTap: () => onOpen(item));
  }
  return HomeTopicCard(cell: entry.cell!);
}

/// Block title (`as_.xml` node `b07`).
///
/// Sizes come from `as_.xml`, not from the generic `bqe.xml` header:
///
/// * 18sp, black, single line, `ellipsize=end`;
/// * `paddingTop=24dp`, `paddingBottom=14dp`;
/// * `paddingStart=16dp`, `paddingEnd=32dp` (the 32 leaves room for 「更多」);
/// * `lineSpacingExtra=6dp`.
///
/// `bqe.xml` is a *different*, denser header (20/12) used by other surfaces;
/// the bookstore blocks use the `as_` variant. Sizing this from `bqe` is why
/// the first version sat 4dp too tight on top and 2dp too tight on the bottom.
class HomeSectionTitle extends StatelessWidget {
  const HomeSectionTitle({super.key, required this.title});

  final String title;

  /// `as_.xml` `b07` padding.
  static const EdgeInsets padding = EdgeInsets.fromLTRB(
    _blockSideMargin,
    24,
    _blockTitleEndPadding,
    14,
  );

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: padding,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 18,
          // `lineSpacingExtra="6.0dip"` on 18sp text ≈ 1.33 line box.
          height: 1.33,
          fontWeight: FontWeight.w700,
          color: palette.ink,
        ),
      ),
    );
  }
}

/// `as_.xml` `b07` `paddingEnd="32.0dip"`.
const double _blockTitleEndPadding = 32;

// ── Block card container (`as_.xml` root) ──────────────────────────────────

/// Official block frame: a white card with 8dp corners.
///
/// `as_.xml` root uses `@drawable/skin_bg_new_book_mall_cell_light` with
/// `marginStart/End=16dp` and `marginBottom=14dp`. That drawable is
/// `<corners android:radius="8.0dip"/>` + `<solid skin_color_bg_card_ff_light/>`
/// — 8dp radius on pure white.
///
/// This is what gives the official page its depth: white cards floating on the
/// `#F6F6F6` canvas. Without it every block sits flat on grey, which is the
/// largest single visual difference from upstream.
class HomeBlockCard extends StatelessWidget {
  const HomeBlockCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      // The horizontal 16dp lives here (from `as_.xml` margins) and must not be
      // repeated inside, or the content ends up inset twice.
      margin: const EdgeInsets.fromLTRB(
        _blockSideMargin,
        0,
        _blockSideMargin,
        _blockBottomMargin,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(blockCornerRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// `8.0dip` from `drawable/skin_bg_new_book_mall_cell_light.xml`.
const double blockCornerRadius = 8;

/// The 「更多书籍信息」 strip closing a block (`jd.xml`, node `anr`).
///
/// `jd.xml` centres a row of `anz` (14sp, black) + a 5×8 chevron inside a
/// 40dp-tall frame (`app:f="40.0dip"` on `anz`). `as_.xml` includes it as
/// `anr` with 16dp side margins and a 16dp bottom margin.
class HomeBlockMoreBooks extends StatelessWidget {
  const HomeBlockMoreBooks({super.key, this.onTap, this.label = '更多书籍信息'});

  final VoidCallback? onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 14, height: 1.2, color: palette.ink),
        ),
        const SizedBox(width: 4),
        // `ao1` sits in a 5×8dp ScaleLayout.
        Icon(LucideIcons.chevron_right, size: 8, color: palette.muted),
      ],
    );
    return SizedBox(
      height: 40,
      child: Center(
        child: onTap == null
            ? row
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: row,
              ),
      ),
    );
  }
}
