// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/book_collection_layout.dart -> BookCollectionLayout,
//                                      BookCollectionSliver,
//                                      BookCollectionView
//   lib/book_collection_mode.dart   -> BookCollectionMode
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `library_reflow.dart`: fqapp has no reflow controller. The upstream
//   LibraryReflowPart wrapper is omitted (the built item is returned
//   directly), `LibraryReflowScope.clipOf(context)` becomes
//   `Clip.hardEdge`, and the row-glass "reflow active" guard becomes the
//   constant `true` (batch enabled). The wrapper only added relocation and a
//   RepaintBoundary; it never changed layout or spacing.
// - `native_effects.dart` NativeGlassGroup: replaced by the vendored
//   liquid_glass_easy LiquidGlassBatch, exactly as fqapp's ADAPTATIONS.md maps
//   NativeGlassGroup (default constructor = a fresh, non-inherited batch;
//   `preserveMemberClip` and `enabled` are forwarded; `GLASS_BATCH` keeps the
//   upstream env gate).
// - `book_grid_density.dart`: BookGridSize, BookGridDensity,
//   BookGridViewport, BookGridGeometry and BookGridScope are ported verbatim
//   below; fqapp has no equivalent file. Their breakpoints, gaps and sizing
//   math are unchanged.
// - `BookCollectionMode` is carried; `AppStartPage` in the same upstream file
//   is an app-start preference unrelated to the collection layout, so it is
//   not ported.
// - `BookCollectionView` takes an optional `controller` so a host can keep
//   paging when the first page does not fill the viewport.
// - Flutter 3.47 deprecated `CustomScrollView.cacheExtent`; the same pixel
//   value is passed through the replacement `scrollCacheExtent:
//   ScrollCacheExtent.pixels(...)`.
// The widgets stay data agnostic: every cell comes from the caller's
// IndexedWidgetBuilder, so no Novel (or other) model type is referenced.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

/// A collection's presentation is independent from its current device budget.
/// Keep the requested mode when the runtime temporarily suppresses 3D effects.
enum BookCollectionMode {
  list,
  shelfList,
  shelfGrid,
  grid;

  bool get hasShelf => this == shelfList || this == shelfGrid;
  bool get isGrid => this == shelfGrid || this == grid;

  /// `shelf` is the existing persisted contract for shelf with a list below it.
  String get storageValue => this == shelfList ? 'shelf' : name;

  String get label => switch (this) {
    list => '纯列表',
    shelfList => '立体书架 + 列表',
    shelfGrid => '立体书架 + 宫格',
    grid => '纯宫格',
  };

  static BookCollectionMode? tryParse(Object? value) => switch (value) {
    'list' => list,
    'shelf' || 'shelfList' => shelfList,
    'shelfGrid' => shelfGrid,
    'grid' => grid,
    _ => null,
  };

  static BookCollectionMode parseOrDefault(Object? value) =>
      tryParse(value) ?? shelfList;
}

enum BookGridSize { small, medium, large }

/// A single atomic preference. Rows describe a viewport target, not pagination.
@immutable
class BookGridDensity {
  const BookGridDensity.auto() : columns = 0, rows = 0, size = null;
  const BookGridDensity.sized(this.size) : columns = 0, rows = 0;
  const BookGridDensity(this.columns, this.rows)
    : size = null,
      assert(columns >= 1 && columns <= 8),
      assert(rows >= 1 && rows <= 10);

  final int columns, rows;
  final BookGridSize? size;
  bool get automatic => columns == 0 && size == null;
  String get value => size?.name ?? (automatic ? 'auto' : '${columns}x$rows');
  String get label => switch (size) {
    BookGridSize.small => '小',
    BookGridSize.medium => '中',
    BookGridSize.large => '大',
    null => automatic ? '自动' : '$columns × $rows',
  };

  static BookGridDensity? tryParse(Object? value) {
    if (value == 'auto') return const BookGridDensity.auto();
    for (final size in BookGridSize.values) {
      if (value == size.name) return BookGridDensity.sized(size);
    }
    if (value is! String) return null;
    final match = RegExp(r'^([1-8])x([1-9]|10)$').firstMatch(value);
    return match == null
        ? null
        : BookGridDensity(int.parse(match[1]!), int.parse(match[2]!));
  }

  static BookGridDensity parseOrAuto(Object? value) {
    final parsed = tryParse(value) ?? const BookGridDensity.auto();
    if (parsed.automatic || parsed.size != null) return parsed;
    return BookGridDensity.sized(
      parsed.columns >= 4
          ? BookGridSize.small
          : parsed.columns == 3
          ? BookGridSize.medium
          : BookGridSize.large,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BookGridDensity && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

/// Stable scrollport geometry: excludes leading controls and protected dock.
/// Text is budgeted at its actual scaled size; it is never shrunk to fit a grid.
@immutable
class BookGridViewport {
  BookGridViewport({
    required this.width,
    required this.height,
    required TextScaler textScaler,
  }) : titleHeight = textScaler.scale(14) * 1.4 * 2,
       authorHeight = textScaler.scale(12) * 1.4,
       progressHeight = textScaler.scale(12) * 1.4,
       minimumCellWidth = math.max(56.0, textScaler.scale(14) * 4),
       retryHeight = math.max(48.0, textScaler.scale(12) * 1.4 + 16),
       statusHeight = textScaler.scale(12) * 1.4 * 2 + 8;

  static const gap = 16.0, coverAspectRatio = 30 / 41;
  // Cover artwork and the metadata action lane have separate hit areas.
  static const minimumCoverWidth = 48.0;
  final double width, height;
  final double titleHeight, authorHeight, progressHeight, minimumCellWidth;
  final double retryHeight, statusHeight;
  double get footerHeight => math.max(48.0, authorHeight + 4 + progressHeight);
  double get metadataHeight => math.max(
    10 + titleHeight + 4 + footerHeight,
    10 + titleHeight + 4 + retryHeight,
  );
  double get minimumRowHeight =>
      metadataHeight + minimumCoverWidth / coverAspectRatio;
  int get maximumColumns => math
      .max(0, ((width + gap) / (minimumCellWidth + gap)).floor())
      .clamp(0, 8);
  int get maximumRows => math
      .max(
        0,
        ((height - statusHeight + gap) / (minimumRowHeight + gap)).floor(),
      )
      .clamp(0, 10);
  bool canFit(BookGridDensity density) =>
      density.automatic ||
      density.size != null ||
      (density.columns <= maximumColumns && density.rows <= maximumRows);

  BookGridGeometry resolve(BookGridDensity requested) {
    if (requested.size case final size?) {
      final target = switch (size) {
        BookGridSize.small => 92.0,
        BookGridSize.medium => 140.0,
        BookGridSize.large => 196.0,
      };
      final maximum = ((width + gap) / (minimumCellWidth + gap)).floor().clamp(
        1,
        12,
      );
      // Compact phones can have less than 308dp after page padding. Small
      // still means three columns there; wider panes keep adding columns.
      // Large text retains the readable-width limit rather than shrinking.
      final columns = math
          .max(
            size == BookGridSize.small ? 3 : 1,
            ((width + gap) / (target + gap)).floor(),
          )
          .clamp(1, maximum);
      return BookGridGeometry._(this, requested, null, columns);
    }
    if (requested.automatic || maximumColumns == 0 || maximumRows == 0) {
      return BookGridGeometry._(this, requested, null);
    }
    return BookGridGeometry._(
      this,
      requested,
      BookGridDensity(
        math.min(requested.columns, maximumColumns),
        math.min(requested.rows, maximumRows),
      ),
    );
  }

  Object get layoutKey =>
      (width, height, titleHeight, authorHeight, retryHeight);
}

@immutable
class BookGridGeometry {
  const BookGridGeometry._(
    this.viewport,
    this.requested,
    this.effective, [
    this.responsiveColumns,
  ]);
  final BookGridViewport viewport;
  final BookGridDensity requested;
  final BookGridDensity? effective;
  final int? responsiveColumns;
  int? get columns => responsiveColumns ?? effective?.columns;
  bool get fixed => effective != null || responsiveColumns != null;
  bool get adjusted =>
      requested.size == null && !requested.automatic && requested != effective;
  double get cellWidth =>
      (viewport.width - (columns! - 1) * BookGridViewport.gap) / columns!;
  double get rowHeight => responsiveColumns != null
      ? viewport.metadataHeight + cellWidth / BookGridViewport.coverAspectRatio
      : (viewport.height -
                viewport.statusHeight -
                (effective!.rows - 1) * BookGridViewport.gap) /
            effective!.rows;
  double get coverWidth => math.min(
    cellWidth,
    (rowHeight - viewport.metadataHeight) * BookGridViewport.coverAspectRatio,
  );
  double get coverHeight => coverWidth / BookGridViewport.coverAspectRatio;
  Object get layoutKey => (
    viewport.layoutKey,
    requested.value,
    effective?.value,
    responsiveColumns,
  );
  String get status => requested.size != null
      ? '${requested.label}封面'
      : adjusted
      ? effective == null
            ? '已设 ${requested.label}；当前自动布局（窗口或字号限制）'
            : '已设 ${requested.label}；当前 ${effective!.label}（窗口或字号限制）'
      : '每屏 ${effective!.columns} 列 × ${effective!.rows} 行';
}

class BookGridScope extends InheritedWidget {
  const BookGridScope({
    super.key,
    required this.geometry,
    required super.child,
  });
  final BookGridGeometry geometry;
  static BookGridGeometry? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BookGridScope>()?.geometry;
  @override
  bool updateShouldNotify(BookGridScope oldWidget) =>
      geometry.layoutKey != oldWidget.geometry.layoutKey;
}

/// Keep a book's cover, metadata and actions together. Wider panes add columns,
/// not wider covers or fixed-height tiles that clip larger text.
abstract final class BookCollectionLayout {
  static const gap = 24.0;
  static const gridGap = 16.0;
  static const gridCoverAspectRatio = 30 / 41;
  // Experimental: pixel parity passed, but matched device runs have not shown
  // a repeatable frame-time benefit. Keep ordinary builds on independent inputs.
  static const rowGlassSharingEnabled = bool.fromEnvironment('GLASS_ROW_BATCH');
  static int columnsFor(double width) =>
      ((width + gap) / (272 + gap)).floor().clamp(1, 3);
  static int gridColumnsFor(double width) =>
      ((width + gridGap) / (100 + gridGap)).floor().clamp(1, 6);
  // Preserve visible books and network prefetch. A wider list must not also
  // multiply its speculative offscreen widget/image work by its column count.
  static double cacheExtentFor(
    double width, {
    double base = 500,
    bool grid = false,
  }) => (base / (grid ? gridColumnsFor(width) : columnsFor(width))).clamp(
    grid ? 64.0 : 128.0,
    base,
  );
}

class BookCollectionSliver extends StatefulWidget {
  const BookCollectionSliver({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.shareRowGlass = false,
    this.grid = false,
    this.gridDensity = const BookGridDensity.auto(),
    this.gridBottomInset = 0,
    this.onGridViewport,
  });
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final bool grid;
  final BookGridDensity gridDensity;
  final double gridBottomInset;
  final ValueChanged<BookGridViewport>? onGridViewport;

  /// Opt in only for clear controls in empty, separated row trailing lanes.
  /// Headings/featured content belong outside this input-sharing scope.
  final bool shareRowGlass;

  @override
  State<BookCollectionSliver> createState() => _BookCollectionSliverState();
}

class _BookCollectionSliverState extends State<BookCollectionSliver> {
  Widget? _rows;
  int? _columns;
  Object? _gridLayoutKey, _viewportKey;
  BookGridGeometry? _geometry;

  @override
  void didUpdateWidget(BookCollectionSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rows = null;
  }

  Widget _item(BuildContext context, int index) {
    final item = widget.itemBuilder(context, index);
    return widget.grid
        ? Padding(
            padding: EdgeInsets.only(
              bottom: _geometry?.fixed == true
                  ? BookCollectionLayout.gridGap
                  : BookCollectionLayout.gap,
            ),
            child: item,
          )
        : item;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _buildRows();
    if (!widget.shareRowGlass || !BookCollectionLayout.rowGlassSharingEnabled) {
      return rows;
    }
    // Upstream wraps this in NativeGlassGroup(inherit: false, ...). The
    // vendored batch's default constructor is the same fresh, non-inherited
    // group; reflow is not ported, so its active guard is always true here.
    return easy.LiquidGlassBatch(
      enabled: const bool.fromEnvironment('GLASS_BATCH', defaultValue: true),
      preserveMemberClip: true,
      child: rows,
    );
  }

  Widget _buildRows() => SliverLayoutBuilder(
    builder: (context, constraints) {
      if (widget.grid) {
        final viewport = BookGridViewport(
          width: constraints.crossAxisExtent,
          height:
              (constraints.viewportMainAxisExtent -
                      constraints.precedingScrollExtent -
                      widget.gridBottomInset)
                  .clamp(0.0, double.infinity),
          textScaler: MediaQuery.textScalerOf(context),
        );
        _geometry = viewport.resolve(widget.gridDensity);
        if (_viewportKey != viewport.layoutKey) {
          _viewportKey = viewport.layoutKey;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onGridViewport?.call(viewport);
          });
        }
      } else {
        _geometry = null;
      }
      final columns = widget.grid
          ? _geometry?.columns ??
                BookCollectionLayout.gridColumnsFor(constraints.crossAxisExtent)
          : BookCollectionLayout.columnsFor(constraints.crossAxisExtent);
      final gap = widget.grid
          ? BookCollectionLayout.gridGap
          : BookCollectionLayout.gap;
      // SliverConstraints include scrollOffset, so this builder is called on
      // every fling frame. Replacing the delegate here rebuilds all mounted
      // book rows, including covers and glass. Only a new data builder or a
      // column-count or density-geometry change needs a new delegate.
      final gridLayoutKey = _geometry?.layoutKey;
      if (_rows != null &&
          _columns == columns &&
          _gridLayoutKey == gridLayoutKey) {
        return _rows!;
      }
      _columns = columns;
      _gridLayoutKey = gridLayoutKey;
      final Widget rows;
      if (columns == 1) {
        rows = SliverList.builder(
          itemCount: widget.itemCount,
          itemBuilder: _item,
        );
      } else {
        rows = SliverList.builder(
          itemCount: (widget.itemCount / columns).ceil(),
          itemBuilder: (context, row) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < columns; column++) ...[
                if (column != 0) SizedBox(width: gap),
                Expanded(
                  child: row * columns + column < widget.itemCount
                      ? _item(context, row * columns + column)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        );
      }
      if (widget.grid && !widget.gridDensity.automatic) {
        return _rows = BookGridScope(
          geometry: _geometry!,
          child: widget.gridDensity.size != null
              ? rows
              : SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: _geometry!.viewport.statusHeight,
                        child: Text(
                          _geometry!.status,
                          key: const ValueKey('grid-density-status'),
                          maxLines: 2,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    rows,
                  ],
                ),
        );
      }
      return _rows = rows;
    },
  );
}

/// Full-width headings/featured books, followed by a lazy responsive collection.
class BookCollectionView extends StatelessWidget {
  const BookCollectionView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.leadingCount = 0,
    this.trailingCount = 0,
    this.padding = EdgeInsets.zero,
    this.physics,
    this.controller,
    this.shareRowGlass = false,
    this.grid = false,
    this.gridDensity = const BookGridDensity.auto(),
    this.onGridViewport,
  }) : assert(itemCount >= leadingCount + trailingCount);
  final int itemCount, leadingCount, trailingCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;
  final ScrollPhysics? physics;

  /// fqapp addition: lets a host fill a short viewport with further pages.
  final ScrollController? controller;
  final bool grid;
  final BookGridDensity gridDensity;
  final ValueChanged<BookGridViewport>? onGridViewport;

  /// Share backdrop input only across the ordinary collection's row controls.
  final bool shareRowGlass;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CustomScrollView(
      controller: controller,
      physics: physics,
      // Upstream: LibraryReflowScope.clipOf(context). No reflow scope exists
      // in fqapp, so the inactive-scope value applies.
      clipBehavior: Clip.hardEdge,
      scrollCacheExtent: ScrollCacheExtent.pixels(
        BookCollectionLayout.cacheExtentFor(
          constraints.maxWidth - padding.horizontal,
          base: 250,
          grid: grid,
        ),
      ),
      slivers: [
        SliverPadding(
          padding: padding,
          sliver: SliverMainAxisGroup(
            slivers: [
              if (leadingCount > 0)
                SliverList.builder(
                  itemCount: leadingCount,
                  itemBuilder: itemBuilder,
                ),
              BookCollectionSliver(
                shareRowGlass: shareRowGlass,
                grid: grid,
                gridDensity: gridDensity,
                gridBottomInset: padding.bottom,
                onGridViewport: onGridViewport,
                itemCount: itemCount - leadingCount - trailingCount,
                itemBuilder: (context, index) =>
                    itemBuilder(context, index + leadingCount),
              ),
              if (trailingCount > 0)
                SliverList.builder(
                  itemCount: trailingCount,
                  itemBuilder: (context, index) =>
                      itemBuilder(context, itemCount - trailingCount + index),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
