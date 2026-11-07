// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/library_toolbar.dart            -> ShelfToolbar (LibraryToolbar)
//   lib/book_collection_region_toolbar.dart -> ShelfRegionToolbar
//   lib/pages.dart (today-reading pill) -> ShelfTodayReadingPill
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `native_effects.dart` NativeGlassGroup -> the vendored
//   `liquid_glass_easy` LiquidGlassBatch (same fresh, non-inherited batch;
//   `preserveMemberClip` and `enabled` forwarded). This is the same mapping
//   already used by `book_collection_layout.dart`.
// - `CompactMainPageControls` -> constant false (fqapp has no compact
//   main-page scope). The narrow/large-text count wrap is kept as a plain
//   width+text-scale rule so the toolbar still never overflows.
// - `app_ui.dart` AppText -> `src/app_text.dart`; ArchiveIcon/ArchiveCode ->
//   `wenku_archive.dart`/`wenku_icons.dart`; GlassTextButton/GlassIconButton ->
//   `wenku_glass.dart` (same APIs).
// - `package:flutter/cupertino.dart` -> `package:flutter/material.dart` plus
//   `CupertinoIcons`; these widgets only use members both libraries expose.
//
// fqapp additions:
// - `ShelfToolbar.leading` hosts the page's today-reading pill without
//   changing the upstream category/count/filter/view lanes.
// - `ShelfRegionToolbar.trailing`/`below` replace the upstream `onLayout`
//   button; the page owns whatever extra action it needs.
// - `ShelfTodayReadingPill` is the archive-styled replacement for the page's
//   old HomeChip pill (same text, e-ink keeps a black outline).

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import 'src/app_text.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_icons.dart';
import 'wenku_loading.dart';
import 'wenku_theme.dart';

/// A single quiet line shared by the shelf, history and collection tabs.
///
/// The category button owns the left lane, the count sits beside it, and the
/// filter/view icon actions keep their own 46dp hit areas. At very narrow
/// widths with large text the count drops to a second line instead of
/// squeezing the category label.
class ShelfToolbar extends StatelessWidget {
  const ShelfToolbar({
    super.key,
    required this.category,
    required this.count,
    this.onCategory,
    this.onFilter,
    this.onView,
    this.categoryKey,
    this.filterKey,
    this.viewKey,
    this.activeFilters = 0,
    this.loading = false,
    this.showCategory = true,
    this.showFilter = true,
    this.showView = true,
    this.leading,
  });
  final String category;
  final int count, activeFilters;
  final VoidCallback? onCategory, onFilter, onView;
  final Key? categoryKey, filterKey, viewKey;
  final bool loading, showCategory, showFilter, showView;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final countLabel = loading
        ? const InlineSkeleton(width: 38, height: 18)
        : AppText(
            '${activeFilters == 0 ? '' : '筛选 · '}$count 本',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
    // These clear controls occupy separate lanes over the same completed row
    // background. Share its input while keeping each original outline clip.
    // The group is local: pushed sheets keep their own backdrop and sizing.
    return easy.LiquidGlassBatch(
      enabled: const bool.fromEnvironment('GLASS_BATCH', defaultValue: true),
      preserveMemberClip: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final separateCount =
              constraints.maxWidth < 340 && textScaler.scale(14) > 17;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 10)],
                  if (showCategory)
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: GlassTextButton(
                          key: categoryKey,
                          compact: true,
                          onPressed: onCategory,
                          // fqapp has no compact main-page scope, so the
                          // upstream `!compact || width >= 100` guard is
                          // always true: the folder glyph stays visible.
                          child: Row(
                            children: [
                              const ArchiveIcon(
                                CupertinoIcons.folder,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: AppText(
                                  category,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.4,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              const ArchiveIcon(
                                CupertinoIcons.chevron_down,
                                size: 11,
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (!separateCount) ...[
                    const SizedBox(width: 12),
                    countLabel,
                  ],
                  if (showFilter) ...[
                    const SizedBox(width: 8),
                    Semantics(
                      value: activeFilters == 0 ? '未筛选' : '$activeFilters 项筛选',
                      child: GlassIconButton(
                        key: filterKey,
                        icon: CupertinoIcons.line_horizontal_3_decrease,
                        label: '筛选',
                        onPressed: onFilter,
                      ),
                    ),
                  ],
                  if (showView) ...[
                    const SizedBox(width: 4),
                    GlassIconButton(
                      key: viewKey,
                      icon: CupertinoIcons.rectangle_grid_1x2,
                      label: '视图',
                      onPressed: onView,
                    ),
                  ],
                ],
              ),
              if (separateCount)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: countLabel,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A region's controls stay beside the books they affect, using the same
/// category, filter and view hit areas as the shelf toolbar.
class ShelfRegionToolbar extends StatelessWidget {
  const ShelfRegionToolbar({
    super.key,
    required this.title,
    required this.category,
    required this.count,
    this.onCategory,
    this.onFilter,
    this.onView,
    this.code = 'COLLECTION / REGION',
    this.subtitle = '',
    this.activeFilters = 0,
    this.categoryKey,
    this.filterKey,
    this.viewKey,
    this.trailing,
    this.below,
    this.loading = false,
    this.showCategory = true,
    this.showFilter = true,
    this.showView = true,
  });
  final String title, code, subtitle, category;
  final int count, activeFilters;
  final VoidCallback? onCategory, onFilter, onView;
  final Key? categoryKey, filterKey, viewKey;
  final Widget? trailing, below;
  final bool loading, showCategory, showFilter, showView;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: ArchiveSection(title: title, code: code, subtitle: subtitle),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
      const SizedBox(height: 12),
      ShelfToolbar(
        category: category,
        count: count,
        onCategory: onCategory,
        onFilter: onFilter,
        onView: onView,
        categoryKey: categoryKey,
        filterKey: filterKey,
        viewKey: viewKey,
        loading: loading,
        activeFilters: activeFilters,
        showCategory: showCategory,
        showFilter: showFilter,
        showView: showView,
      ),
      if (below != null) ...[const SizedBox(height: 10), below!],
    ],
  );
}

/// The archive-styled "今日已读 N 分钟" pill.
///
/// The text is unchanged from the old HomeChip pill. Regular appearance has no
/// outline; e-ink draws a black hairline so the white capsule stays visible on
/// the white canvas.
class ShelfTodayReadingPill extends StatelessWidget {
  const ShelfTodayReadingPill({super.key, required this.minutes});
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final eink = WenkuTheme.isEinkOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: eink ? Border.all(color: Colors.black) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArchiveIcon(
            CupertinoIcons.clock,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          AppText(
            '今日已读$minutes分钟',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
