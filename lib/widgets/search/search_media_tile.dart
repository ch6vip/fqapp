import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../models/shuqi_book.dart';
import '../../services/app_style_tokens.dart';
import '../home/home_media_card.dart';
import '../media_card.dart';
import '../wenku/wenku_archive.dart';
import '../wenku/wenku_glass.dart';
import '../wenku/wenku_icons.dart';

String _fileCode(MediaItem item) {
  final prefix = isShuqiItem(item) ? 'SQ' : 'FQ';
  final numeric = int.tryParse(item.id);
  if (numeric != null) {
    return '$prefix-${numeric.toString().padLeft(5, '0')}';
  }
  final id = item.id.trim();
  return id.isEmpty ? '$prefix-UNFILED' : '$prefix-$id';
}

String searchMediaMeta(MediaItem item) => joinMetaSegments([
  if (item.author.isNotEmpty) item.author,
  kindLabels[item.kind] ?? item.kind,
  mediaLengthLabel(item),
  if (item.score != null)
    '${item.score!.toStringAsFixed(1)}分'
  else if (!isShuqiItem(item))
    '暂无评分',
]);

/// MediaItem adapter for the upstream `NovelRow` result grammar.
class SearchNovelRow extends StatelessWidget {
  const SearchNovelRow({super.key, required this.item, required this.onTap});

  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = AppStyleTokens.of(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      button: true,
      label: item.title,
      child: JellyTapSurface(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            vertical: style.isClassic ? style.entryGap : 13,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(style.coverRadius),
                child: SizedBox(
                  width: 56,
                  height: 76,
                  child: StoryCover(
                    item: item,
                    cacheWidth: math.max(1, (56 * pixelRatio).ceil()),
                  ),
                ),
              ),
              SizedBox(width: style.isClassic ? style.panelPadding : 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (style.showDecorativeCodes) ...[
                      ArchiveCode(_fileCode(item)),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      joinMetaSegments([
                        shuqiMarker(item, isClassic: style.isClassic) ?? '',
                        searchMediaMeta(item),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const ArchiveIcon(CupertinoIcons.chevron_right, size: 15),
            ],
          ),
        ),
      ),
    );
  }
}

/// MediaItem adapter for the upstream `BookGridTile` result grammar.
class SearchBookGridTile extends StatelessWidget {
  const SearchBookGridTile({
    super.key,
    required this.item,
    required this.onTap,
  });

  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = AppStyleTokens.of(context);
    return Semantics(
      button: true,
      label: item.title,
      child: JellyTapSurface(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final coverHeight = width / (30 / 41);
            final pixelRatio = MediaQuery.devicePixelRatioOf(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(style.coverRadius),
                  child: SizedBox(
                    height: coverHeight,
                    child: StoryCover(
                      item: item,
                      cacheWidth: math.max(1, (width * pixelRatio).ceil()),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  joinMetaSegments([
                    shuqiMarker(item, isClassic: style.isClassic) ?? '',
                    searchMediaMeta(item),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
