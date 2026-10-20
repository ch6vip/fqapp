import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/poster_cache.dart';
import '../models/book_detail.dart' show formatWordCount;
import '../models/media_item.dart';
import 'cover_tag_chip.dart';

const kindLabels = {
  'book': '小说',
  'video': '短剧',
  'manju': '漫剧',
  'manga': '漫画',
  'audio': '听书',
};
const kindColors = {
  'book': Color(0xFF4A90D9),
  'video': Color(0xFFE8532D),
  'manju': Color(0xFFAA5A92),
  'manga': Color(0xFF34A853),
  'audio': Color(0xFF9C6ADE),
};

/// Compact length caption for a search card: 「共93集」 for dramas/manju,
/// 「216万字」 for novels. Empty when the card carries neither, so callers can
/// drop the segment instead of rendering a dangling separator.
///
/// Search responses ship the length inside the nested card record: novels put
/// `word_number` on `book_data`, dramas put `episode_cnt` on `video_data`.
/// Both are real values in the captured payloads, not guesses — see
/// docs/validation/issue90-search-length-and-score-20261020.md.
String mediaLengthLabel(MediaItem item) {
  switch (item.kind) {
    case 'book':
      final words = formatWordCount(item.wordNumber);
      if (words.isNotEmpty) return words;
    case 'video':
    case 'manju':
      final episodes = int.tryParse(item.ep.trim());
      if (episodes != null && episodes > 0) return '共$episodes集';
  }
  return '';
}

/// Baseline grid used by tests and callers without a BuildContext. A maximum
/// tile width makes it naturally expand from two columns on narrow windows to
/// more columns on tablets/desktop.
const mediaGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 140,
  // 5:7 cover plus two title lines and one author line.
  childAspectRatio: 0.50,
  crossAxisSpacing: 10,
  mainAxisSpacing: 10,
);

/// Adaptive production grid. The extra height tracks accessibility text
/// scaling so card metadata cannot overflow while cover proportions remain
/// fixed.
SliverGridDelegate mediaGridDelegateFor(BuildContext context) {
  final scaled = MediaQuery.textScalerOf(context).scale(13) / 13;
  final textScale = scaled.clamp(1.0, 3.0);
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 140,
    childAspectRatio: 0.50 / (1 + (textScale - 1) * 0.19),
    crossAxisSpacing: 10,
    mainAxisSpacing: 10,
  );
}

const _coverAspectRatio = 5 / 7;
const _titleHeight = 32.0;
const _authorHeight = 14.0;

class MediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;
  final bool showScore;

  const MediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.showScore = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    final scaledTitleHeight = scaler.scale(13) * 1.2 * 2 + 1;
    final scaledAuthorHeight = scaler.scale(11) * 1.2 + 1;
    final titleHeight = scaledTitleHeight > _titleHeight
        ? scaledTitleHeight
        : _titleHeight;
    final authorHeight = scaledAuthorHeight > _authorHeight
        ? scaledAuthorHeight
        : _authorHeight;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (140 * pixelRatio).round();
    final cacheHeight = (196 * pixelRatio).round();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: _coverAspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                      width: 0.6,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9.5),
                    child: item.cover.isNotEmpty
                        ? CachedNetworkImage(
                            cacheManager: PosterCache.instance,
                            imageUrl: item.cover,
                            fit: BoxFit.cover,
                            memCacheWidth: cacheWidth,
                            memCacheHeight: cacheHeight,
                            placeholder: (context, url) => ColoredBox(
                              color: scheme.surfaceContainerHighest,
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: scheme.surfaceContainerHighest,
                              child: Icon(
                                LucideIcons.book_open,
                                size: 40,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : Container(
                            color: scheme.surfaceContainerHighest,
                            child: Icon(
                              LucideIcons.book_open,
                              size: 40,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: (kindColors[item.kind] ?? Colors.grey).withValues(
                        alpha: 0.92,
                      ),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Text(
                      kindLabels[item.kind] ?? item.kind,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                // The upstream corner badge (上新 / 热门 / 爆款). Search results
                // carry it too, so showing it here keeps the same work labelled
                // the same way wherever it appears. Only coloured tags render:
                // search's tag field also carries the kind label, which this
                // card already shows on the right.
                if (item.tag case final MediaTag tag when tag.hasColors)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: CoverTagChip(
                        key: const Key('media_card_tag'),
                        label: tag.text,
                        colors: tag.colorsFor(
                          dark: Theme.of(context).brightness == Brightness.dark,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: titleHeight,
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: authorHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    // Author and length share one line: the tile is narrow, and
                    // a second caption row would push the grid taller.
                    [
                      if (item.author.isNotEmpty) item.author,
                      if (mediaLengthLabel(item).isNotEmpty)
                        mediaLengthLabel(item),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (showScore && item.score != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    '${item.score!.toStringAsFixed(1)}分',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
