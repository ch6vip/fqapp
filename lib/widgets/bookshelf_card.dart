import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/poster_cache.dart';
import '../models/media_item.dart';
import 'home/home_design.dart';

/// The three shelf styles of the official bookshelf.
///
/// The enum order is the stored preference (0 宫格 / 1 双列 / 2 列表) and also
/// the order the 更多 menu lists them in, so [BookshelfLayout.values] can be
/// used directly for both the preference index and the menu.
///
/// Note: 官方书架形态的复刻范围与取舍见
/// .agents/notes/implemented/feature/2026-09-20-official-bookshelf.md
enum BookshelfLayout {
  grid('切换为宫格'),
  doubleColumn('切换为双列'),
  list('切换为列表');

  const BookshelfLayout(this.menuLabel);

  /// The official menu label (strings su/sh/sk).
  final String menuLabel;
}

const _kindLabels = {
  'book': '小说',
  'video': '短剧',
  'manju': '漫剧',
  'manga': '漫画',
  'audio': '听书',
};

const _kindColors = {
  'book': Color(0xFF4A90D9),
  'video': Color(0xFFE8532D),
  'manju': Color(0xFFAA5A92),
  'manga': Color(0xFF34A853),
  'audio': Color(0xFF9C6ADE),
};

String bookshelfKindLabel(String kind) => _kindLabels[kind] ?? kind;

/// The content types the 筛选 panel offers, in the official card order.
const bookshelfFilterKinds = ['book', 'video', 'manju', 'manga', 'audio'];

// ---------------------------------------------------------------------------
// 宫格: 3 columns, cover height = width × 1.3947369, radius 12dp.
// ---------------------------------------------------------------------------

const bookshelfGridColumns = 3;
const bookshelfGridSidePadding = 20.0;
const bookshelfGridSpacing = 19.0;
const bookshelfGridRunSpacing = 16.0;
const bookshelfGridCoverRatio = 1.3947369;
const bookshelfGridCoverRadius = 12.0;

const _gridTitleSize = 14.0;

/// Android `lineSpacingExtra="3.0dip"` on a 14sp title, as a height multiple.
const _gridTitleLineHeight = 1 + 3 / _gridTitleSize;
const _subtitleSize = 12.0;
const _subtitleLineHeight = 1.3;

// 列表: one 110dp row with a 60×90 cover.
const bookshelfListRowHeight = 110.0;
const bookshelfListSidePadding = 20.0;
const bookshelfListCoverWidth = 60.0;
const bookshelfListCoverHeight = 90.0;

// 双列: 110×162 cover, the info block overlaps its lower 84dp.
const bookshelfDoubleCoverWidth = 110.0;
const bookshelfDoubleCoverHeight = 162.0;
const bookshelfDoubleSidePadding = 12.0;
const bookshelfDoubleSpacing = 12.0;
const bookshelfDoubleRunSpacing = 16.0;
const _doubleCoverMarginStart = 12.0;
const _doubleInfoPadding = 12.0;
const _doubleInfoOverlap = 84.0;
const _doubleTitleSize = 16.0;

/// The 简介 slot keeps up to four 12sp lines.
const bookshelfDoubleInfoLines = 4;

/// The width of one 宫格 cell, including nothing of the page padding.
double bookshelfGridCellWidth(double availableWidth) => math.max(
  1.0,
  (availableWidth -
          bookshelfGridSidePadding * 2 -
          bookshelfGridSpacing * (bookshelfGridColumns - 1)) /
      bookshelfGridColumns,
);

/// Cell height that keeps the 3-column cover at its official ratio while the
/// title (two lines) and the info line still fit at the current text scale.
double bookshelfGridChildAspectRatio(
  BuildContext context, {
  required double availableWidth,
}) {
  final cellWidth = bookshelfGridCellWidth(availableWidth);
  final titleHeight =
      MediaQuery.textScalerOf(context).scale(_gridTitleSize) *
      _gridTitleLineHeight *
      2;
  final infoHeight =
      MediaQuery.textScalerOf(context).scale(_subtitleSize) *
      _subtitleLineHeight;
  final cellHeight =
      cellWidth * bookshelfGridCoverRatio +
      2 +
      titleHeight +
      4 +
      infoHeight +
      4;
  return cellWidth / cellHeight;
}

// ---------------------------------------------------------------------------
// Shared pieces.
// ---------------------------------------------------------------------------

Color _titleColor(HomePalette palette) =>
    palette.dark ? palette.ink : const Color(0xFF000000);

Color _subtitleColor(HomePalette palette) =>
    palette.dark ? palette.muted : const Color(0x66000000);

/// 宫格封面：宽 =(可用宽-40-19*(列数-1))/列数，高 = 宽 × 1.3947369，圆角 12dp。
class _ShelfCover extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;
  final double radius;
  final String? badgeText;
  final bool selected;

  const _ShelfCover({
    required this.item,
    required this.width,
    required this.height,
    required this.radius,
    this.badgeText,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final fallback = _FallbackCover(item: item);
    return SizedBox(
      key: const Key('bookshelf-cover'),
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: palette.soft,
              child: item.cover.trim().isEmpty
                  ? fallback
                  : CachedNetworkImage(
                      cacheManager: PosterCache.instance,
                      imageUrl: item.cover,
                      fit: BoxFit.cover,
                      memCacheWidth: math.max(1, (width * 3).round()),
                      fadeInDuration: const Duration(milliseconds: 150),
                      placeholder: (_, _) => fallback,
                      errorWidget: (_, _, _) => fallback,
                    ),
            ),
          ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                color: HomePalette.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: HomePalette.accent, width: 2),
              ),
            ),
          if (badgeText != null && !selected)
            Positioned(top: 4, right: 7, child: _UpdateBadge(text: badgeText!)),
        ],
      ),
    );
  }
}

/// 右上角角标：9sp 白字、minWidth 26dp、padding 1/4dp、marginTop 4dp。
///
/// 官方角标文案是「更新」；本地没有章节版本数据可以判定更新，因此角标里放
/// 真实的阅读进度百分比，几何尺寸仍按官方。
class _UpdateBadge extends StatelessWidget {
  final String text;

  const _UpdateBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 26),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [HomePalette.accent, Color(0xFFE4432E)],
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// 编辑态多选框：22×22dp，选中态填充品牌色。
class _SelectionBox extends StatelessWidget {
  final bool selected;
  final Color border;

  const _SelectionBox({required this.selected, required this.border});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected
              ? HomePalette.accent
              : Colors.black.withValues(alpha: 0.18),
          border: Border.all(
            color: selected ? HomePalette.accent : border,
            width: 1.5,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 14, color: Colors.white)
            : null,
      ),
    );
  }
}

class _FallbackCover extends StatelessWidget {
  final MediaItem item;

  const _FallbackCover({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _kindColors[item.kind] ?? scheme.primary;
    final background = Color.alphaBlend(
      accent.withValues(alpha: 0.13),
      scheme.surfaceContainerHighest,
    );
    // The placeholder stays visual only. The card's own title line sits right
    // below the cover, so drawing the title here as well printed it twice on
    // every cover-less entry; the home feed's fallback cover keeps to an icon
    // for the same reason.
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 70;
        return ColoredBox(
          color: background,
          child: Center(
            child: Icon(
              Icons.auto_stories_outlined,
              size: narrow ? 18 : 24,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 宫格 / 双列 / 列表 cards.
// ---------------------------------------------------------------------------

/// 宫格条目：封面 + 角标 + 两行标题 + 一行副信息。
class BookshelfGridCard extends StatelessWidget {
  final MediaItem item;
  final String? badgeText;
  final String? infoText;
  final bool editing;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfGridCard({
    super.key,
    required this.item,
    required this.onTap,
    this.badgeText,
    this.infoText,
    this.editing = false,
    this.selected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final titleHeight =
        MediaQuery.textScalerOf(context).scale(_gridTitleSize) *
        _gridTitleLineHeight *
        2;
    return Semantics(
      button: true,
      selected: selected,
      label: item.title,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(bookshelfGridCoverRadius),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : bookshelfGridCellWidth(360);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    _ShelfCover(
                      item: item,
                      width: width,
                      height: width * bookshelfGridCoverRatio,
                      radius: bookshelfGridCoverRadius,
                      badgeText: editing ? null : badgeText,
                      selected: selected,
                    ),
                    if (editing)
                      Positioned(
                        top: 5,
                        left: 5,
                        child: _SelectionBox(
                          selected: selected,
                          border: Colors.white,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: titleHeight,
                  width: double.infinity,
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _gridTitleSize,
                      height: _gridTitleLineHeight,
                      color: _titleColor(palette),
                    ),
                  ),
                ),
                if (infoText != null) ...{
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: Text(
                      infoText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _subtitleSize,
                        height: _subtitleLineHeight,
                        color: _subtitleColor(palette),
                      ),
                    ),
                  ),
                },
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 双列条目：110×162 封面，信息区自封面下方 84dp 处起（官方 layout bns.xml）。
class BookshelfDoubleCard extends StatelessWidget {
  final MediaItem item;
  final String? badgeText;
  final String? subtitleText;

  /// Up to [bookshelfDoubleInfoLines] real meta lines, filling the official
  /// 简介 slot. The model carries no synopsis, so this is author / progress /
  /// length rather than a fake blurb.
  final List<String> infoLines;
  final bool editing;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfDoubleCard({
    super.key,
    required this.item,
    required this.onTap,
    this.badgeText,
    this.subtitleText,
    this.infoLines = const [],
    this.editing = false,
    this.selected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final lines = infoLines.take(bookshelfDoubleInfoLines).toList();
    return Semantics(
      button: true,
      selected: selected,
      label: item.title,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cellWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : bookshelfDoubleCoverWidth + _doubleCoverMarginStart;
            final coverWidth = math.min(
              bookshelfDoubleCoverWidth,
              math.max(1.0, cellWidth - _doubleCoverMarginStart),
            );
            final coverHeight =
                coverWidth *
                (bookshelfDoubleCoverHeight / bookshelfDoubleCoverWidth);
            final infoTop = math.max(0.0, coverHeight - _doubleInfoOverlap);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: infoTop,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.soft,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: palette.line, width: 0.5),
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        left: _doubleCoverMarginStart,
                      ),
                      child: Stack(
                        children: [
                          _ShelfCover(
                            item: item,
                            width: coverWidth,
                            height: coverHeight,
                            radius: 10,
                            badgeText: editing ? null : badgeText,
                            selected: selected,
                          ),
                          if (editing)
                            Positioned(
                              top: 5,
                              left: 5,
                              child: _SelectionBox(
                                selected: selected,
                                border: Colors.white,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        _doubleInfoPadding,
                        0,
                        _doubleInfoPadding,
                        16,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _doubleTitleSize,
                              height: 1 + 3 / _doubleTitleSize,
                              color: _titleColor(palette),
                            ),
                          ),
                          if (subtitleText != null) ...{
                            const SizedBox(height: 8),
                            Text(
                              subtitleText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: _subtitleSize,
                                height: _subtitleLineHeight,
                                color: _subtitleColor(palette),
                              ),
                            ),
                          },
                          if (lines.isNotEmpty) ...{
                            const SizedBox(height: 8),
                            for (final line in lines)
                              Text(
                                line,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: _subtitleSize,
                                  height: _subtitleLineHeight,
                                  color: _subtitleColor(palette),
                                ),
                              ),
                          },
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 列表条目：110dp 行高、60×90 封面、标题 15sp + 两行 12sp 副信息。
class BookshelfListCard extends StatelessWidget {
  final MediaItem item;
  final String? progressText;
  final String? metaText;
  final bool editing;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfListCard({
    super.key,
    required this.item,
    required this.onTap,
    this.progressText,
    this.metaText,
    this.editing = false,
    this.selected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: item.title,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: bookshelfListRowHeight),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(width: bookshelfListSidePadding),
              if (editing) ...{
                _SelectionBox(selected: selected, border: palette.line),
                const SizedBox(width: 20),
              },
              _ShelfCover(
                item: item,
                width: bookshelfListCoverWidth,
                height: bookshelfListCoverHeight,
                radius: 6,
                selected: selected,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        color: _titleColor(palette),
                      ),
                    ),
                    if (progressText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Text(
                          progressText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: _subtitleSize,
                            height: _subtitleLineHeight,
                            color: _subtitleColor(palette),
                          ),
                        ),
                      ),
                    if (metaText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          metaText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: _subtitleSize,
                            height: _subtitleLineHeight,
                            color: _subtitleColor(palette),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: bookshelfListSidePadding),
            ],
          ),
        ),
      ),
    );
  }
}

/// The cell height of the 双列 grid: cover plus the info block below it.
double bookshelfDoubleCellWidth(double availableWidth) => math.max(
  1.0,
  (availableWidth - bookshelfDoubleSidePadding * 2 - bookshelfDoubleSpacing) /
      2,
);

double bookshelfDoubleChildAspectRatio(
  BuildContext context, {
  required double availableWidth,
}) {
  final scaler = MediaQuery.textScalerOf(context);
  final cellWidth = bookshelfDoubleCellWidth(availableWidth);
  final coverWidth = math.min(
    bookshelfDoubleCoverWidth,
    math.max(1.0, cellWidth - _doubleCoverMarginStart),
  );
  final coverHeight =
      coverWidth * (bookshelfDoubleCoverHeight / bookshelfDoubleCoverWidth);
  final infoHeight =
      scaler.scale(_doubleTitleSize) * (1 + 3 / _doubleTitleSize) +
      8 +
      scaler.scale(_subtitleSize) * _subtitleLineHeight +
      8 +
      scaler.scale(_subtitleSize) *
          _subtitleLineHeight *
          bookshelfDoubleInfoLines +
      16;
  return cellWidth / (coverHeight + infoHeight + 8);
}
