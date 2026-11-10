// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/pages.dart:1785-1866          -> ShelfNovelRow (NovelRow)
//   lib/book_collection_grid.dart:12-171  -> ShelfBookGridTile (BookGridTile)
//   lib/book_collection_grid.dart:174-267 -> ShelfBookGridFailure
//   lib/archive_wave.dart selection mark  -> ShelfSelectionMark
//   lib/book_source_badge.dart            -> ShelfCoverBadge
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `Novel` -> `MediaItem`; `NovelCover` -> `ShelfCoverImage` (fqapp's single
//   poster cache, file/svg covers and e-ink grayscale).
// - `LocalLibraryPreferences.authorName` -> the row's `meta` string, which the
//   page already composes; the tile never invents author text.
// - `app_ui.dart` AppText -> `src/app_text.dart`; ArchiveCode/ArchiveIcon ->
//   `wenku_archive.dart`/`wenku_icons.dart`; JellyTapSurface -> `wenku_glass.dart`.
// - `ArchiveDesign.fileCode` (WK-xxxxx) -> fqapp's FQ-/SQ- convention, matching
//   the search result tiles.
//
// fqapp additions:
// - `onLongPress` enters the page's edit mode (the upstream row has no long
//   press); the recognizer wraps the tap surface instead of replacing it.
// - `editing`/`selected` draw the shared selection mark and hide cover badges.
// - `cached`/`fanqieImported`/`badge`/`progress`/`meta` carry the page's
//   existing row facts without a service dependency.
// - `coverHeroTag` is accepted for parity; fqapp does not fly a Hero.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../models/shuqi_book.dart';
import '../../services/app_style_tokens.dart';
import '../cover_tag_chip.dart';
import '../media_card.dart';
import '../wenku/book_collection_layout.dart';
import '../wenku/src/app_text.dart';
import '../wenku/wenku_archive.dart';
import '../wenku/wenku_glass.dart';
import '../wenku/wenku_icons.dart';
import 'shelf_cover_image.dart';

/// FQ-/SQ- archive file code, matching the search result tiles.
///
/// The optional flags append the same markers the row can show, so a caller
/// that only has the code line still sees why the row is marked.
String archiveFileCode(
  MediaItem item, {
  bool cached = false,
  bool fanqieImported = false,
}) {
  final prefix = isShuqiItem(item) ? 'SQ' : 'FQ';
  final numeric = int.tryParse(item.id);
  final id = item.id.trim();
  final code = numeric != null
      ? '$prefix-${numeric.toString().padLeft(5, '0')}'
      : id.isEmpty
      ? '$prefix-UNFILED'
      : '$prefix-$id';
  final marks = [if (cached) '缓存', if (fanqieImported) '番茄导入'];
  return marks.isEmpty ? code : '$code · ${marks.join(' · ')}';
}

/// The shared selected-state check drawn over a cover.
class ShelfSelectionMark extends StatelessWidget {
  const ShelfSelectionMark({super.key, required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Semantics(
        selected: selected,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.black.withValues(alpha: .18),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.white.withValues(alpha: .9),
              width: 1.4,
            ),
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 13,
                  color: Theme.of(context).colorScheme.surface,
                )
              : null,
        ),
      ),
    ),
  );
}

/// The archive list row: cover, file code, title and one metadata line.
class ShelfNovelRow extends StatelessWidget {
  const ShelfNovelRow({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    this.badge,
    this.progress,
    this.meta,
    this.cached = false,
    this.fanqieImported = false,
    this.editing = false,
    this.selected = false,
    this.coverHeroTag,
  });
  final MediaItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final String? badge, progress, meta;
  final bool cached, fanqieImported, editing, selected;
  final Object? coverHeroTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = AppStyleTokens.of(context);
    final metaText = joinMetaSegments([
      shuqiMarker(item, isClassic: style.isClassic) ?? '',
      if (cached) '缓存',
      if (meta != null && meta!.isNotEmpty) meta!,
      if (fanqieImported) '番茄导入',
    ]);
    return Semantics(
      button: true,
      selected: editing ? selected : null,
      child: GestureDetector(
        onLongPress: onLongPress,
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
                Stack(
                  children: [
                    Semantics(
                      label: item.title,
                      image: true,
                      child: ShelfCoverImage(
                        item: item,
                        width: 56,
                        height: 76,
                        radius: style.coverRadius,
                        decodeWidth: shelfCoverDecodeWidth(
                          56,
                          MediaQuery.devicePixelRatioOf(context),
                        ),
                      ),
                    ),
                    if (!editing && badge != null && badge!.isNotEmpty)
                      Positioned(
                        top: 3,
                        right: 3,
                        child: ShelfCoverBadge(text: badge!),
                      ),
                    if (editing)
                      Positioned.fill(
                        child: ShelfSelectionMark(selected: selected),
                      ),
                  ],
                ),
                SizedBox(width: style.isClassic ? style.panelPadding : 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (style.showDecorativeCodes) ...[
                        ArchiveCode(archiveFileCode(item)),
                        const SizedBox(height: 4),
                      ],
                      AppText(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          height: 1.4,
                        ),
                      ),
                      if (metaText.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        AppText(
                          metaText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (progress != null && progress!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        AppText(
                          progress!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                trailing ??
                    const ArchiveIcon(CupertinoIcons.chevron_right, size: 15),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The archive grid tile: cover, title and a metadata/action footer.
class ShelfBookGridTile extends StatelessWidget {
  const ShelfBookGridTile({
    super.key,
    required this.item,
    required this.onTap,
    this.trailing,
    this.onLongPress,
    this.badge,
    this.progress,
    this.meta,
    this.cached = false,
    this.fanqieImported = false,
    this.editing = false,
    this.selected = false,
    this.coverHeroTag,
  });
  final MediaItem item;
  final VoidCallback onTap;
  final Widget? trailing;
  final VoidCallback? onLongPress;
  final String? badge, progress, meta;
  final bool cached, fanqieImported, editing, selected;
  final Object? coverHeroTag;

  Widget _cover(BuildContext context, double width, double height) => SizedBox(
    height: height,
    child: Center(
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              label: item.title,
              image: true,
              child: ShelfCoverImage(
                item: item,
                width: width,
                height: height,
                radius: AppStyleTokens.of(context).coverRadius,
                decodeWidth: shelfCoverDecodeWidth(
                  width,
                  MediaQuery.devicePixelRatioOf(context),
                ),
              ),
            ),
            if (!editing && badge != null && badge!.isNotEmpty)
              Positioned(
                top: 4,
                right: 4,
                child: ShelfCoverBadge(text: badge!),
              ),
            if (editing) ShelfSelectionMark(selected: selected),
          ],
        ),
      ),
    ),
  );

  Widget _metadata(BuildContext context, {double? height}) {
    // The grid footer carries the same facts as the list row's meta line, so
    // the 番茄导入 marker never disappears when the user switches to a grid.
    final style = AppStyleTokens.of(context);
    final metaText = joinMetaSegments([
      shuqiMarker(item, isClassic: style.isClassic) ?? '',
      if (cached) '缓存',
      if (meta != null && meta!.isNotEmpty) meta!,
      if (fanqieImported) '番茄导入',
    ]);
    return SizedBox(
      key: ValueKey('grid-metadata-${item.id}'),
      height: height,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onLongPress: onLongPress,
              child: JellyTapSurface(
                onTap: onTap,
                child: SizedBox(
                  height: height,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (metaText.isNotEmpty)
                        AppText(
                          metaText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (progress != null && progress!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        AppText(
                          progress!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // This sibling is never inside the cover's open-book gesture target.
          trailing ?? const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required double coverWidth,
    required double coverHeight,
    BookGridGeometry? geometry,
  }) => SizedBox(
    height: geometry?.rowHeight,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onLongPress: onLongPress,
          child: JellyTapSurface(
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _cover(context, coverWidth, coverHeight),
                const SizedBox(height: 10),
                SizedBox(
                  height: geometry?.viewport.titleHeight,
                  child: AppText(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        _metadata(context, height: geometry?.viewport.footerHeight),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final geometry = BookGridScope.of(context);
    if (geometry?.fixed == true) {
      return _tile(
        context,
        coverWidth: geometry!.coverWidth,
        coverHeight: geometry.coverHeight,
        geometry: geometry,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => _tile(
        context,
        coverWidth: constraints.maxWidth,
        coverHeight:
            constraints.maxWidth / BookCollectionLayout.gridCoverAspectRatio,
      ),
    );
  }
}

/// Metadata recovery keeps a cover-sized retry target and a separate menu.
class ShelfBookGridFailure extends StatelessWidget {
  const ShelfBookGridFailure({
    super.key,
    required this.title,
    required this.onRetry,
    this.trailing,
  });
  final String title;
  final VoidCallback onRetry;
  final Widget? trailing;

  Widget _cover(BuildContext context, double width, double height) => Center(
    child: SizedBox(
      width: width,
      height: height,
      child: Semantics(
        button: true,
        label: '重新载入 $title',
        child: JellyTapSurface(
          onTap: onRetry,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .04),
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(
                AppStyleTokens.of(context).coverRadius,
              ),
            ),
            child: const Center(
              child: AppText(
                '重试',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _tile(
    BuildContext context, {
    required double coverWidth,
    required double coverHeight,
    BookGridGeometry? geometry,
  }) => SizedBox(
    height: geometry?.rowHeight,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _cover(context, coverWidth, coverHeight),
        const SizedBox(height: 10),
        SizedBox(
          height: geometry?.viewport.titleHeight,
          child: AppText(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: geometry?.viewport.footerHeight,
          child: Align(alignment: Alignment.centerRight, child: trailing),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final geometry = BookGridScope.of(context);
    if (geometry?.fixed == true) {
      return _tile(
        context,
        coverWidth: geometry!.coverWidth,
        coverHeight: geometry.coverHeight,
        geometry: geometry,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => _tile(
        context,
        coverWidth: constraints.maxWidth,
        coverHeight:
            constraints.maxWidth / BookCollectionLayout.gridCoverAspectRatio,
      ),
    );
  }
}
