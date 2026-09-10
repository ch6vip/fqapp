import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';

const bookshelfCoverAspectRatio = 3 / 4;

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

/// Legado-style grid entry: a 3:4 cover, a small status badge and a centered
/// two-line title. It is intentionally separate from [MediaCard], whose extra
/// author row and 5:7 cover are designed for discovery feeds rather than a
/// compact personal shelf.
class BookshelfGridCard extends StatelessWidget {
  final MediaItem item;
  final String? badgeText;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfGridCard({
    super.key,
    required this.item,
    required this.onTap,
    this.badgeText,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight = math.max(32.0, scaler.scale(12) * 1.25 * 2 + 1);
    return Semantics(
      button: true,
      label: item.title,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AspectRatio(
                aspectRatio: bookshelfCoverAspectRatio,
                child: _BookshelfCover(
                  item: item,
                  badgeText: badgeText ?? bookshelfKindLabel(item.kind),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: titleHeight,
                width: double.infinity,
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
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

/// Legado-style list entry. Standard mode mirrors the roomy classic row;
/// compact mode reduces the cover and combines metadata into fewer lines.
class BookshelfListCard extends StatelessWidget {
  final MediaItem item;
  final bool compact;
  final String? readingText;
  final String? lastUpdateText;
  final String? badgeText;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfListCard({
    super.key,
    required this.item,
    required this.compact,
    required this.onTap,
    this.readingText,
    this.lastUpdateText,
    this.badgeText,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coverWidth = compact ? 58.0 : 78.0;
    final metadata = <String>[
      if (item.author.trim().isNotEmpty) item.author.trim(),
      if (readingText?.trim().isNotEmpty == true) readingText!.trim(),
    ];
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: compact ? 82 : 112),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 8,
              vertical: compact ? 4 : 5,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: coverWidth,
                    child: AspectRatio(
                      aspectRatio: bookshelfCoverAspectRatio,
                      child: _BookshelfCover(item: item),
                    ),
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
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: compact ? 4 : 6),
                        if (compact)
                          Text(
                            metadata.isEmpty
                                ? bookshelfKindLabel(item.kind)
                                : metadata.join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        else ...[
                          if (item.author.trim().isNotEmpty)
                            _MetaLine(
                              icon: Icons.person_outline,
                              text: item.author.trim(),
                            ),
                          if (readingText?.trim().isNotEmpty == true)
                            _MetaLine(
                              icon: Icons.history,
                              text: readingText!.trim(),
                            ),
                          if (item.ep.trim().isNotEmpty)
                            _MetaLine(
                              icon: Icons.menu_book_outlined,
                              text: _totalText(item),
                            ),
                          if (item.author.trim().isEmpty &&
                              readingText?.trim().isNotEmpty != true &&
                              item.ep.trim().isEmpty)
                            _MetaLine(
                              icon: Icons.category_outlined,
                              text: bookshelfKindLabel(item.kind),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (badgeText?.trim().isNotEmpty == true ||
                      lastUpdateText?.trim().isNotEmpty == true)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(
                          0,
                          (constraints.maxWidth - coverWidth - 12) / 2,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (badgeText?.trim().isNotEmpty == true)
                              _StatusBadge(
                                text: badgeText!.trim(),
                                color: _kindColors[item.kind] ?? scheme.primary,
                              ),
                            if (lastUpdateText?.trim().isNotEmpty == true) ...[
                              const SizedBox(height: 6),
                              Text(
                                lastUpdateText!.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _totalText(MediaItem item) {
    final suffix = switch (item.kind) {
      'video' || 'manju' || 'audio' => '集',
      'manga' => '话',
      _ => '章',
    };
    return '共 ${item.ep}$suffix';
  }
}

class _MetaLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookshelfCover extends StatelessWidget {
  final MediaItem item;
  final String? badgeText;

  const _BookshelfCover({required this.item, this.badgeText});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final cacheWidth = constraints.maxWidth.isFinite
            ? math.max(1, (constraints.maxWidth * ratio).round())
            : null;
        final cacheHeight = constraints.maxHeight.isFinite
            ? math.max(1, (constraints.maxHeight * ratio).round())
            : null;
        final fallback = _FallbackCover(item: item);
        return Material(
          color: scheme.surfaceContainerHighest,
          elevation: 2,
          shadowColor: Colors.black38,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (item.cover.trim().isNotEmpty)
                CachedNetworkImage(
                  imageUrl: item.cover,
                  fit: BoxFit.cover,
                  memCacheWidth: cacheWidth,
                  memCacheHeight: cacheHeight,
                  fadeInDuration: const Duration(milliseconds: 150),
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, _, _) => fallback,
                )
              else
                fallback,
              if (badgeText?.trim().isNotEmpty == true)
                Positioned(
                  top: 5,
                  left: 5,
                  right: 5,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: _StatusBadge(
                      text: badgeText!.trim(),
                      color: _kindColors[item.kind] ?? scheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 70;
        final largeText = MediaQuery.textScalerOf(context).scale(12) > 18;
        final showAuthor =
            !narrow && !largeText && item.author.trim().isNotEmpty;
        return ColoredBox(
          color: background,
          child: Padding(
            padding: EdgeInsets.all(narrow ? 4 : 7),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.auto_stories_outlined,
                  size: narrow ? 18 : 24,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                ),
                SizedBox(height: narrow ? 4 : 8),
                Flexible(
                  child: Center(
                    child: Text(
                      item.title,
                      maxLines: narrow ? 2 : 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: narrow ? 9 : 12,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                if (showAuthor) ...[
                  const SizedBox(height: 5),
                  Text(
                    item.author.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String text;
  final Color color;

  const _StatusBadge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Calculates enough grid height to keep the cover exactly 3:4 while allowing
/// two title lines at the current accessibility text scale.
double bookshelfGridChildAspectRatio(
  BuildContext context, {
  required double availableWidth,
  required int columns,
}) {
  final safeColumns = columns.clamp(2, 6);
  final cellWidth = math.max(1.0, (availableWidth - 16) / safeColumns);
  final coverWidth = math.max(1.0, cellWidth - 8);
  final titleHeight = math.max(
    32.0,
    MediaQuery.textScalerOf(context).scale(12) * 1.25 * 2 + 1,
  );
  final cellHeight =
      8 + coverWidth / bookshelfCoverAspectRatio + 6 + titleHeight;
  return cellWidth / cellHeight;
}
