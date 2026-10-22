import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';
import 'home_design.dart';

/// Block widgets for the bookstore feed, following the official layouts.
///
/// Sizes and structure come from the decompiled layouts rather than from
/// guesswork:
///
/// * `as_.xml` — the block container: 16dp side margins, 14dp bottom margin,
///   rounded card background.
/// * `bqe.xml` — the shared block header, reused by every block type:
///   title 18sp bold, padding 20 top / 12 bottom / 16 start, max width 180;
///   「更多」 on the right, 14sp + a 4×7 arrow, padding 16 end.
/// * `jd.xml` — the bottom 「更多书籍信息」 row: centred, 14sp + 5×8 arrow.
/// * `av2.xml` — the horizontal card: cover 68×102, title 16sp, author line
///   12sp, two-line abstract, tag row.
/// * `b7d.xml` — one rank row: cover 44×66, index column 23 wide, title 2
///   lines, subtitle 12sp.
///
/// The official client keeps these as separate holder types dispatched by
/// `show_type`; the shapes are reproduced here, not the holder plumbing.

// ── Shared metrics (from the layouts above) ────────────────────────────────

const double _blockSideMargin = 16;
const double _blockBottomMargin = 14;

/// 官方 `as_.xml` 的标题区：paddingTop **24**（不是 20）、paddingBottom 14、
/// paddingStart 16、paddingEnd **32**（右边给「更多」留位）。
const double _headerTopPadding = 24;
const double _headerBottomPadding = 14;
const double _headerStartPadding = 16;
const double _headerEndPadding = 32;
const double _headerTitleSize = 18;
const double _headerTitleMaxWidth = 180;
const double _moreLabelSize = 14;
const double _cardCoverWidth = 68;
const double _cardCoverHeight = 102;
const double _cardTitleSize = 16;
const double _cardMetaSize = 12;
const double _rankCoverWidth = 44;
const double _rankCoverHeight = 66;
const double _rankIndexWidth = 23;
const double _rankTitleSize = 14;
const double _rankSubtitleSize = 12;

/// The rounded card every block sits in (`as_.xml` / `ayt.xml`).
class HomeBlockCard extends StatelessWidget {
  const HomeBlockCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _blockSideMargin,
        0,
        _blockSideMargin,
        _blockBottomMargin,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          // 官方 `as_.xml` 用 `@drawable/skin_bg_new_book_mall_cell_light`，
          // 白底 + 圆角卡片。
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: padding ?? EdgeInsets.zero,
          child: child,
        ),
      ),
    );
  }
}

/// Shared block header (`bqe.xml`): title on the left, 「更多」 on the right.
class HomeBlockHeader extends StatelessWidget {
  const HomeBlockHeader({
    super.key,
    required this.title,
    this.onMore,
    this.moreLabel = '更多',
  });

  final String title;
  final VoidCallback? onMore;
  final String moreLabel;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return ConstrainedBox(
      // 标题最长 180dp，右边给「更多」留出固定空间（官方 paddingEnd 32dp）。
      constraints: const BoxConstraints(minHeight: 50),
      child: Padding(
        padding: const EdgeInsets.only(
          top: _headerTopPadding,
          bottom: _headerBottomPadding,
          left: _headerStartPadding,
          right: _headerEndPadding,
        ),
        child: Row(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _headerTitleMaxWidth),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _headerTitleSize,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: palette.ink,
                ),
              ),
            ),
            const Spacer(),
            if (onMore != null)
              GestureDetector(
                onTap: onMore,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      moreLabel,
                      style: TextStyle(
                        fontSize: _moreLabelSize,
                        height: 1.2,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      LucideIcons.chevron_right,
                      size: 14,
                      color: palette.muted,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bottom 「更多书籍信息」 row (`jd.xml`).
class HomeBlockFooter extends StatelessWidget {
  const HomeBlockFooter({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '更多书籍信息',
              style: TextStyle(fontSize: _moreLabelSize, color: palette.ink),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
          ],
        ),
      ),
    );
  }
}

/// Horizontal card matching `av2.xml`.
///
/// Cover 68×102 on the left; title, author, a two-line abstract and the tag
/// row on the right. This is the shape the official feed uses for its main
/// book stream — not a grid cell.
class HomeBookRowCard extends StatelessWidget {
  const HomeBookRowCard({super.key, required this.item, required this.onTap});

  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final abstract = item.intro;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_blockSideMargin, 8, _blockSideMargin, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(
              url: item.cover,
              width: _cardCoverWidth,
              height: _cardCoverHeight,
              palette: palette,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: _cardTitleSize,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: palette.ink,
                          ),
                        ),
                      ),
                      if (item.badge.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          item.badge,
                          style: TextStyle(
                            fontSize: 10,
                            color: HomePalette.accent,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (item.author.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _cardMetaSize,
                        height: 1.3,
                        color: palette.muted,
                      ),
                    ),
                  ],
                  if (abstract.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      abstract,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _cardMetaSize,
                        height: 1.45,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One rank row matching `b7d.xml`: cover 44×66, index column, title, subtitle.
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
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
                    color: index < 3 ? HomePalette.accent : palette.ink,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _rankTitleSize,
                      height: 1.3,
                      color: palette.ink,
                    ),
                  ),
                  if (item.author.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _rankSubtitleSize,
                        height: 1.3,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

/// `RankCellV3`(511): rank board preview as a vertical list inside a card.
Widget buildRankCell(
  BuildContext context,
  HomeCell cell, {
  required ValueChanged<MediaItem> onOpen,
  required VoidCallback onMore,
}) {
  final books = cell.flatten();
  if (books.isEmpty) return const SizedBox.shrink();
  return HomeBlockCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeBlockHeader(
          title: cell.name.isEmpty ? '排行榜' : cell.name,
          onMore: onMore,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _blockSideMargin),
          child: Column(
            children: [
              for (var i = 0; i < books.length; i++)
                HomeRankRow(
                  item: books[i],
                  index: i,
                  onTap: () => onOpen(books[i]),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
      ],
    ),
  );
}

/// A card-stream block: header + one horizontal card per book.
///
/// This is `av2.xml` repeated, which is what the official main stream looks
/// like — not a grid.
Widget buildCardSection(
  BuildContext context,
  HomeCell cell, {
  required ValueChanged<MediaItem> onOpen,
  required double gridWidth,
}) {
  final books = cell.flatten();
  if (books.isEmpty) return const SizedBox.shrink();
  return HomeBlockCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cell.name.isNotEmpty) HomeBlockHeader(title: cell.name),
        for (final item in books)
          HomeBookRowCard(item: item, onTap: () => onOpen(item)),
      ],
    ),
  );
}
