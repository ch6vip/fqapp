import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';

/// Block widgets for the bookstore feed.
///
/// Two block types come back on the first tab (`tab_type=2`):
///
/// * `RankCellV3`(511)「排行榜」 — 6 rank lists, 16 categories, and one book
///   per rank as a preview. Rendered as a horizontal strip; tapping a book
///   opens it, tapping 「更多」 opens the rank board.
/// * `MultiTabMixedUnlimitedV2`(384) → `DoubleRowMixedUnlimitedWithFilter`(385)
///   → `MixedDataInUnlimited`(339) — the main card stream, rendered as a grid
///   under its section title.
///
/// The official client dispatches far more types; these two are the ones this
/// feed actually returns. Anything else falls back to the generic grid.

/// Section title above a block, matching the existing homepage headers.
class HomeBlockHeader extends StatelessWidget {
  const HomeBlockHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final sub = subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 19,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: palette.ink,
                  ),
                ),
                if (sub != null && sub.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    sub,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: palette.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// `RankCellV3`(511): the rank board preview.
///
/// The block itself carries no rank list — `rank_with_category_data` does — so
/// the strip only shows the preview books this block ships, with their index as
/// the rank number. The board itself is a separate page.
Widget buildRankCell(
  BuildContext context,
  HomeCell cell, {
  required ValueChanged<MediaItem> onOpen,
  required VoidCallback onMore,
}) {
  final palette = HomePalette.of(context);
  final books = cell.flatten();
  if (books.isEmpty) return const SizedBox.shrink();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      HomeBlockHeader(
        title: cell.name.isEmpty ? '排行榜' : cell.name,
        subtitle: '按榜单看当下最热',
        action: TextButton(
          onPressed: onMore,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: palette.muted,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('更多', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 2),
              Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
            ],
          ),
        ),
      ),
      SizedBox(
        height: 186,
        child: ListView.separated(
          key: const ValueKey('home_rank_strip'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: books.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final item = books[index];
            return SizedBox(
              width: 92,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _RankedCover(
                    item: item,
                    rank: index + 1,
                    onTap: () => onOpen(item),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
}

/// Cover with a rank badge in the corner.
class _RankedCover extends StatelessWidget {
  const _RankedCover({
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
    // 前三名用品牌色，其余用中性色：官方榜单条也是这个分法。
    final badgeColor = rank <= 3 ? HomePalette.accent : palette.muted;
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 1 / 1.4,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              item.cover.isEmpty
                  ? ColoredBox(color: palette.soft)
                  : Image.network(
                      item.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          ColoredBox(color: palette.soft),
                    ),
              Positioned(
                left: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: const BorderRadius.only(
                      bottomRight: Radius.circular(8),
                    ),
                  ),
                  child: Text(
                    '$rank',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Card grid for a card-bearing block (`MultiTabMixedUnlimitedV2` & friends).
///
/// Uses two columns like the rest of the homepage; the official block asks for
/// two rows at a time, which reads the same way in a phone-width grid.
Widget buildCardSection(
  BuildContext context,
  HomeCell cell, {
  required ValueChanged<MediaItem> onOpen,
  required double gridWidth,
}) {
  final books = cell.flatten();
  if (books.isEmpty) return const SizedBox.shrink();
  final cardWidth = homeCardWidth(context, gridWidth);
  const gap = 12.0;
  final columns = 2;
  final rows = (books.length + columns - 1) ~/ columns;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (cell.name.isNotEmpty) HomeBlockHeader(title: cell.name),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          children: [
            for (var row = 0; row < rows; row++) ...[
              if (row > 0) const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) const SizedBox(width: gap),
                    Expanded(
                      child: () {
                        final index = row * columns + col;
                        if (index >= books.length) {
                          return const SizedBox.shrink();
                        }
                        final item = books[index];
                        return HomeMediaCard(
                          item: item,
                          coverWidth: cardWidth,
                          onTap: () => onOpen(item),
                        );
                      }(),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    ],
  );
}
