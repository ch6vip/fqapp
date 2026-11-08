// Upstream source: Wenku8_Flutter `lib/pages.dart`, revision
// ebcd7f1891b54a92fc045c372974d70ec829f10a:
//   `_DetailPageState._identity`, `_identityText`, `_tags`, `_resumeInformation`,
//   `_synopsis`, `_directory`, `_directoryHeading`, `_volumeRow`, `_chapterRow`,
//   `_footerActions`, `_directoryCountLabel`.
//
// Mechanical substitutions (same convention as
// `lib/widgets/wenku/ADAPTATIONS.md`):
// - `Novel`/`NovelChapter` -> fqapp `MediaItem` + `BookDetail`/`Chapter`.
// - `NovelCover` -> fqapp `StoryCover` (the vendored bytes/legacy cover cache is
//   not ported) clipped to `ArchiveDesign.coverRadius`; tapping it keeps
//   fqapp's `showDetailCover` viewer.
// - `AppText`, `ArchiveIcon`, `ArchiveSection`, `ArchiveCode`, `GlassTextButton`,
//   `GlassPillButton`, `JellyTapSurface`, `LoadingSkeleton` come from the
//   shared `lib/widgets/wenku` layer unchanged.
// - `NovelMotion` -> `WenkuMotion`; `showJellySheet` is not ported, so the
//   chapter-cache entry stays on fqapp's existing bottom sheet.
// - `NovelVolume.of` -> `detailArchiveVolumes` below, grouping fqapp chapters by
//   their `volumeName` (empty names render no volume header, as upstream).
// - `OfflineNovelRepository` cache checks -> fqapp `ChapterCache` ids passed by
//   the page; a missing set simply hides the marks.
// - Upstream's `BookCommunityActions` and `OfflineBookStatus` are intentionally
//   absent (upstream account/write surfaces are outside fqapp's product
//   boundary); fqapp's own 书评 and 下载 sheet stay.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/book_detail.dart';
import '../../models/media_item.dart';
import '../../services/app_style_tokens.dart';
import '../home/home_media_card.dart';
import '../wenku/src/easy_glass.dart';
import '../wenku/wenku_ui.dart';
import 'detail_cover_tile.dart' show showDetailCover;
import 'detail_style.dart' show detailNumericFeatures;

/// `WK-00123` — upstream `ArchiveDesign.fileCode`, kept string-safe because
/// fqapp book ids are longer than a 32-bit int.
String detailArchiveFileCode(String id) {
  final digits = id.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty || digits.length > 18) return 'WK-$id';
  return 'WK-${digits.padLeft(5, '0')}';
}

/// Upstream `_identity`: a 118 (150 from 650dp) wide cover with the title,
/// author, meta, rating/rank lines and the archive code beside it.
class DetailArchiveIdentity extends StatelessWidget {
  const DetailArchiveIdentity({
    super.key,
    required this.item,
    this.detail,
    this.onOpenAuthor,
    this.lastChapterTitle,
    this.sourceLabel,
  });

  final MediaItem item;
  final BookDetail? detail;

  /// Opens the author's works page; null when the payload carried no author id.
  final VoidCallback? onOpenAuthor;

  /// Newest chapter for the `更新于 …` line.
  final String? lastChapterTitle;

  /// Where this work comes from. Supplied by the page (书旗 uses 书旗小说);
  /// null hides the segment instead of guessing a source.
  final String? sourceLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final wide = constraints.maxWidth >= 650;
        final coverWidth = wide ? 150.0 : 118.0;
        final cover = _cover(context, coverWidth);
        final metadata = _metadata(context, wide: wide);
        if (scale >= 1.45 && !wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [cover, const SizedBox(height: 22), metadata],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            SizedBox(width: wide ? 28 : 20),
            Expanded(child: metadata),
          ],
        );
      },
    );
  }

  Widget _cover(BuildContext context, double width) {
    final height = width * 1.4;
    final fallback = ColoredBox(
      key: const ValueKey('detail-cover-placeholder'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
    return Semantics(
      button: true,
      label: '查看小说封面',
      child: GestureDetector(
        key: const Key('detail_cover_button'),
        // fqapp's viewer also shows the generated fallback artwork, so the
        // cover stays tappable even when the payload has no image URL.
        onTap: () => showDetailCover(context, item),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            AppStyleTokens.of(context).coverRadius,
          ),
          child: SizedBox(
            width: width,
            height: height,
            child: item.cover.isEmpty
                ? fallback
                : StoryCover(
                    item: item,
                    cacheWidth: (width * 3).round().clamp(1, 1200),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _metadata(BuildContext context, {required bool wide}) {
    final scheme = Theme.of(context).colorScheme;
    final title = detail?.title.isNotEmpty == true ? detail!.title : item.title;
    final author = detail?.author.name.isNotEmpty == true
        ? detail!.author.name
        : item.author.trim();
    final authorId = detail?.author.id ?? '';
    final canOpenAuthor = author.isNotEmpty && authorId.isNotEmpty;
    final meta = _metaParts();
    final updated = _updateLabel;
    final rating = _ratingLine(context);
    final rank = detail?.rankLabel ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          title,
          key: const Key('detail_book_title'),
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: wide ? 28 : 24,
            height: 1.25,
            letterSpacing: -.5,
          ),
        ),
        const SizedBox(height: 8),
        if (author.isNotEmpty)
          Semantics(
            button: canOpenAuthor && onOpenAuthor != null,
            label: canOpenAuthor ? '查看$author的作品' : null,
            child: JellyTapSurface(
              key: const Key('detail_author_works'),
              onTap: canOpenAuthor ? onOpenAuthor : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: AppText(
                        author,
                        key: const Key('detail_author_name'),
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (canOpenAuthor) ...[
                      const SizedBox(width: 5),
                      const ArchiveIcon(CupertinoIcons.chevron_right, size: 12),
                    ],
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 13),
        if (meta.isNotEmpty)
          AppText(
            meta,
            key: const Key('detail_meta_line'),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.55,
            ),
          ),
        if (updated != null) ...[
          const SizedBox(height: 4),
          AppText(
            updated,
            key: const Key('detail_update_line'),
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (rating != null) ...[const SizedBox(height: 10), rating],
        if (rank.isNotEmpty) ...[
          const SizedBox(height: 8),
          _RankLabel(label: rank),
        ],
        if (AppStyleTokens.of(context).showDecorativeCodes) ...[
          const SizedBox(height: 12),
          ArchiveCode(detailArchiveFileCode(item.id), inverse: true),
        ],
      ],
    );
  }

  /// `分类 · 连载中 · 128万字 · 番茄小说`, each part only when present.
  String _metaParts() {
    final info = detail;
    final source = sourceLabel?.trim() ?? '';
    final parts = <String>[
      if (info != null && info.category.isNotEmpty) info.category,
      if (info != null && info.statusLabel.isNotEmpty) info.statusLabel,
      if (info != null && info.wordLabel.isNotEmpty) info.wordLabel,
      if (source.isNotEmpty) source,
    ];
    return parts.join(' · ');
  }

  String? get _updateLabel {
    final info = detail;
    if (info == null) return null;
    final latest = lastChapterTitle?.trim() ?? '';
    if (info.creationStatus == 1 && latest.isNotEmpty) {
      return '更新至 $latest';
    }
    return null;
  }

  /// `★ 8.7 · 12.4万人在读`; the star follows the archive ink on e-ink.
  Widget? _ratingLine(BuildContext context) {
    final info = detail;
    if (info == null) return null;
    final score = info.score.trim();
    final readers = info.readLabel.trim();
    if (score.isEmpty && readers.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    final eink = WenkuTheme.isEinkOf(context);
    final readLabel = readers.isEmpty
        ? ''
        : (readers.endsWith('在读') ? readers : '$readers人在读');
    return Row(
      key: const Key('detail_rating_line'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (score.isNotEmpty) ...[
          Text(
            '★',
            style: TextStyle(
              color: eink ? Colors.black : const Color(0xFFF2A93B),
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            score,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.5,
              fontFeatures: detailNumericFeatures,
            ),
          ),
        ],
        if (score.isNotEmpty && readLabel.isNotEmpty)
          Text(' · ', style: TextStyle(color: scheme.onSurfaceVariant)),
        if (readLabel.isNotEmpty)
          Flexible(
            child: Text(
              readLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

/// Upstream `_tags`: hairline outlined archive tags, not filled pills.
class DetailArchiveTags extends StatelessWidget {
  const DetailArchiveTags({super.key, required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      key: const Key('detail_hero_tags'),
      spacing: 7,
      runSpacing: 7,
      children: [
        for (final tag in tags)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .7),
                width: .7,
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              child: AppText(
                tag,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.25,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Upstream `_synopsis`: `01 / SYNOPSIS`, three clamped lines and the
/// `展开全部` toggle. Keeps fqapp's `detail_description_*` keys.
class DetailArchiveSynopsis extends StatefulWidget {
  const DetailArchiveSynopsis({super.key, required this.text});

  final String text;

  @override
  State<DetailArchiveSynopsis> createState() => _DetailArchiveSynopsisState();
}

class _DetailArchiveSynopsisState extends State<DetailArchiveSynopsis> {
  bool _expanded = false;

  @override
  void didUpdateWidget(DetailArchiveSynopsis oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    const style = TextStyle(fontSize: 15, height: 1.8);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            text: appText(context, widget.text),
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          maxLines: 3,
          ellipsis: '…',
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final expandable = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionHeader(context, '简介', ''),
            const SizedBox(height: 14),
            AnimatedSize(
              duration: reduceMotion ? Duration.zero : WenkuMotion.enter,
              reverseDuration: reduceMotion ? Duration.zero : WenkuMotion.exit,
              alignment: Alignment.topLeft,
              curve: WenkuMotion.ease,
              child: AppText(
                widget.text,
                key: const Key('detail_description_text'),
                maxLines: _expanded ? null : 3,
                overflow: _expanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (expandable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: JellyTapSurface(
                  key: const Key('detail_description_toggle'),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppText(
                          _expanded ? '收起' : '展开全部',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 7),
                        AnimatedRotation(
                          turns: _expanded ? .5 : 0,
                          duration: reduceMotion
                              ? Duration.zero
                              : WenkuMotion.enter,
                          curve: WenkuMotion.ease,
                          child: const ArchiveIcon(
                            CupertinoIcons.chevron_down,
                            size: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One row of the inline catalogue: either a volume header or a chapter.
class DetailContentsEntry {
  const DetailContentsEntry.volume(this.volume) : chapterIndex = null;
  const DetailContentsEntry.chapter(int this.chapterIndex) : volume = null;

  final DetailVolumeGroup? volume;
  final int? chapterIndex;
}

/// Consecutive chapters sharing a non-empty `volumeName` form one volume.
class DetailVolumeGroup {
  const DetailVolumeGroup({
    required this.title,
    required this.start,
    required this.length,
  });

  final String title;
  final int start;
  final int length;

  String get key => '$title#$start';

  Iterable<int> get indexes => Iterable<int>.generate(length, (i) => start + i);
}

List<DetailVolumeGroup> detailArchiveVolumes(List<Chapter> chapters) {
  final groups = <DetailVolumeGroup>[];
  for (var i = 0; i < chapters.length; i++) {
    final name = chapters[i].volumeName.trim();
    final current = groups.isEmpty ? null : groups.last;
    // A name change starts a new volume; non-consecutive repeats stay apart,
    // matching upstream's directory order.
    final continues =
        current != null &&
        current.start + current.length == i &&
        current.title == name;
    if (!continues) {
      groups.add(DetailVolumeGroup(title: name, start: i, length: 1));
    } else {
      groups[groups.length - 1] = DetailVolumeGroup(
        title: name,
        start: current.start,
        length: current.length + 1,
      );
    }
  }
  return groups;
}

/// Upstream `_directory` flattening: volume headers followed by the chapters
/// of every expanded volume; `reversed` flips both levels.
List<DetailContentsEntry> detailArchiveContents({
  required List<Chapter> chapters,
  required List<DetailVolumeGroup> volumes,
  required Set<String> expandedVolumes,
  required bool reversed,
}) {
  final ordered = reversed ? volumes.reversed : volumes;
  final entries = <DetailContentsEntry>[];
  for (final volume in ordered) {
    if (volume.title.isNotEmpty) {
      entries.add(DetailContentsEntry.volume(volume));
    }
    final indexes = volume.indexes.toList(growable: false);
    if (reversed) indexes.setAll(0, indexes.reversed.toList(growable: false));
    if (volume.title.isEmpty || expandedVolumes.contains(volume.key)) {
      for (final index in indexes) {
        entries.add(DetailContentsEntry.chapter(index));
      }
    }
  }
  return entries;
}

/// Volume containing [index], or null when the index is out of range.
DetailVolumeGroup? detailArchiveVolumeFor(
  List<DetailVolumeGroup> volumes,
  int? index,
) {
  if (index == null) return null;
  for (final volume in volumes) {
    if (index >= volume.start && index < volume.start + volume.length) {
      return volume;
    }
  }
  return null;
}

/// Upstream `_directoryHeading`: the archive section plus the order toggle.
class DetailArchiveContentsHeading extends StatelessWidget {
  const DetailArchiveContentsHeading({
    super.key,
    required this.countLabel,
    required this.reversed,
    this.onToggleOrder,
    this.onOpenSheet,
    this.orderSaving = false,
    this.progress,
  });

  final String countLabel;
  final bool reversed;
  final VoidCallback? onToggleOrder;

  /// fqapp's searchable/sortable directory sheet stays one tap away.
  final VoidCallback? onOpenSheet;
  final bool orderSaving;

  /// `已读 16% · 3 天前` block; null when the reader has no saved place.
  final Widget? progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ArchiveSection(
                title: '目录',
                code: '02 / CONTENTS',
                subtitle: countLabel,
              ),
            ),
            if (onOpenSheet != null)
              GlassTextButton(
                key: const Key('detail_directory_button'),
                compact: true,
                onPressed: onOpenSheet,
                child: const AppText('全部'),
              ),
            const SizedBox(width: 4),
            GlassTextButton(
              key: const Key('detail-catalogue-order'),
              compact: true,
              selected: reversed,
              onPressed: orderSaving ? null : onToggleOrder,
              child: AppText(reversed ? '倒序' : '正序'),
            ),
          ],
        ),
        if (progress != null) ...[const SizedBox(height: 12), progress!],
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Upstream `_volumeRow` with the signed-in cache marks.
class DetailArchiveVolumeRow extends StatelessWidget {
  const DetailArchiveVolumeRow({
    super.key,
    required this.volume,
    required this.expanded,
    required this.chapterCount,
    required this.cacheLabel,
    required this.onTap,
  });

  final DetailVolumeGroup volume;
  final bool expanded;
  final int chapterCount;
  final String? cacheLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      expanded: expanded,
      button: true,
      child: JellyTapSurface(
        key: ValueKey('detail-volume-${volume.key}'),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor,
                width: .7,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      volume.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 5),
                    AppText(
                      '$chapterCount 章${cacheLabel == null ? '' : ' · $cacheLabel'}',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (cacheLabel == '已缓存') ...[
                const SizedBox(width: 12),
                ArchiveIcon(
                  CupertinoIcons.check_mark,
                  key: ValueKey('detail-volume-cached-${volume.key}'),
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
              ],
              const SizedBox(width: 14),
              AnimatedRotation(
                turns: expanded ? .25 : 0,
                duration: reduceMotion ? Duration.zero : WenkuMotion.enter,
                curve: WenkuMotion.ease,
                child: ArchiveIcon(
                  CupertinoIcons.chevron_right,
                  size: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Upstream `_chapterRow`: ordinal, title, `上次阅读` and the cache check.
class DetailArchiveChapterRow extends StatelessWidget {
  const DetailArchiveChapterRow({
    super.key,
    required this.index,
    required this.title,
    required this.current,
    required this.cached,
    required this.onTap,
  });

  /// Zero-based global ordinal; null when only a standalone video is known.
  final int? index;
  final String title;
  final bool current;
  final bool cached;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return JellyTapSurface(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor,
              width: .7,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 36,
              child: AppText(
                index == null ? '--' : (index! + 1).toString().padLeft(2, '0'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  if (current) ...[
                    const SizedBox(height: 4),
                    AppText(
                      '上次阅读',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (cached) ...[
              const SizedBox(width: 10),
              ArchiveIcon(
                CupertinoIcons.check_mark,
                key: ValueKey('detail-chapter-cached-$index'),
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
            const SizedBox(width: 12),
            const ArchiveIcon(CupertinoIcons.chevron_right, size: 13),
          ],
        ),
      ),
    );
  }
}

/// fqapp's catalogue progress strip (the app predates the upstream port and
/// keeps its `23 / 146` + `已读 16%` readout).
class DetailArchiveProgress extends StatelessWidget {
  const DetailArchiveProgress({
    super.key,
    required this.number,
    required this.total,
    required this.percent,
    required this.label,
  });

  final int number;
  final int total;
  final int percent;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final eink = WenkuTheme.isEinkOf(context);
    final style = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: 12,
      height: 1.5,
      fontFeatures: detailNumericFeatures,
    );
    final radius = BorderRadius.circular(99);
    final track = scheme.onSurface.withValues(alpha: .12);
    final fill = scheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          key: const Key('detail_progress_line'),
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$number / $total',
              key: const Key('detail_progress_count'),
              style: style,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          key: const Key('detail_progress_bar'),
          height: eink ? 5 : 4,
          decoration: BoxDecoration(
            color: track,
            borderRadius: radius,
            border: eink ? Border.all(color: scheme.onSurface) : null,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (percent / 100).clamp(0.0, 1.0),
                heightFactor: 1,
                child: ColoredBox(
                  key: const Key('detail_progress_fill'),
                  color: fill,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Bottom dock: upstream `_footerActions` (two glass pills) over the same
/// scroll-edge underlay the shell dock uses.
class DetailArchiveDock extends StatelessWidget {
  const DetailArchiveDock({
    super.key,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.onPrimary,
    this.secondaryLabel,
    this.secondaryIcon,
    this.onSecondary,
    this.primaryLoading = false,
  });

  final String primaryLabel;
  final IconData primaryIcon;
  final VoidCallback? onPrimary;

  /// Read-only sources (书旗) have no shelf entry; the dock then shows the
  /// primary action alone.
  final String? secondaryLabel;
  final IconData? secondaryIcon;
  final VoidCallback? onSecondary;

  final bool primaryLoading;

  @override
  Widget build(BuildContext context) {
    final secondaryLabel = this.secondaryLabel;
    final geometry = glassActionDockGeometry(
      context,
      primary: primaryLabel,
      secondary: secondaryLabel ?? '',
    );
    final primary = GlassPillButton(
      key: const Key('detail_read_button'),
      icon: primaryIcon,
      label: primaryLabel,
      onPressed: onPrimary,
      loading: primaryLoading,
      height: DockLayout.heightOf(context),
      iconSize: DockLayout.iconSize,
      fontSize: DockLayout.labelFontSize,
    );
    final secondary = secondaryLabel == null
        ? null
        : GlassPillButton(
            key: const Key('detail_shelf_button'),
            icon: secondaryIcon ?? CupertinoIcons.bookmark,
            label: secondaryLabel,
            onPressed: onSecondary,
            height: DockLayout.heightOf(context),
            iconSize: DockLayout.iconSize,
            fontSize: DockLayout.labelFontSize,
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: geometry.height,
          child: secondary == null
              ? primary
              : geometry.stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    primary,
                    const SizedBox(height: DockLayout.actionGap),
                    secondary,
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: 5, child: secondary),
                    const SizedBox(width: DockLayout.actionGap),
                    Expanded(flex: 7, child: primary),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Scroll-edge blur and black falloff behind the [DetailArchiveDock].
class DetailArchiveDockUnderlay extends StatelessWidget {
  const DetailArchiveDockUnderlay({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final plain =
        WenkuTheme.isEinkOf(context) ||
        media.highContrast ||
        !PerformanceScope.of(context).edgeBlur;
    final plateau = DockLayout.bottomPaddingOf(context, viewPadding: true);
    return SizedBox(
      height: height,
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!plain)
              EasyScrollEdge(
                blur: GlassAppearance.of(context).blur,
                plateau: plateau,
                fromBottom: true,
                child: const SizedBox.expand(),
              ),
            if (!plain && DockLayout.edgeShadeOpacity > 0)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(
                        alpha: DockLayout.edgeShadeOpacity,
                      ),
                      Colors.black.withValues(
                        alpha: DockLayout.edgeShadeOpacity,
                      ),
                      Colors.transparent,
                    ],
                    stops: [0, (plateau / height).clamp(0.0, 1.0), 1],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RankLabel extends StatelessWidget {
  const _RankLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final eink = WenkuTheme.isEinkOf(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const Key('detail_rank_pill'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: eink
              ? Colors.transparent
              : scheme.onSurface.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: .7),
            width: .7,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
