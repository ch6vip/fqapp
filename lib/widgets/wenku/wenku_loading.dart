// Ported from Wenku8_Flutter lib/loading_ui.dart (revision ebcd7f1).
//
// Mechanical substitutions for dependencies fqapp does not ship:
// - `app_language.dart` `AppText` -> `src/app_text.dart` `AppText`. Chinese
//   input is returned unchanged; the upstream locale lookup and OpenCC
//   conversion are intentionally absent.
// - `app_palette.dart` `AppTonalColors` -> `wenku_theme.dart`
//   `WenkuTonalColors`; the `milk` / `glassSurface` lookups are the same.
// - `archive_design.dart` -> `wenku_archive.dart` `ArchiveDesign`.
// - `archive_shelf_geometry.dart` -> the public sibling port
//   `src/archive_shelf_geometry.dart` (U4 also uses it for the loaded bank).
// - `archive_shelf_loading.dart` `archiveLoadingLift` -> the public sibling
//   port `src/archive_shelf_loading.dart`.
// - `book_collection_layout.dart` -> the sibling fqapp port
//   `book_collection_layout.dart`. That port also carries the upstream
//   `book_grid_density.dart` types (`BookGridDensity`, `BookGridViewport`,
//   `BookGridGeometry`, `BookGridScope`), so the fixed-density paths below
//   are unchanged.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'book_collection_layout.dart';
import 'src/app_text.dart';
import 'src/archive_shelf_geometry.dart';
import 'src/archive_shelf_loading.dart';
import 'src/performance_preferences.dart';
import 'wenku_archive.dart';
import 'wenku_theme.dart';

enum SkeletonLayout {
  library,
  search,
  detail,
  reader,
  readerVertical,
  bookRow,
  review,
  reviewThread,
  history,
  actions,
  inline,
  button,
  cover,
}

/// Feedback for an existing page being updated, not a substitute for its data.
class RefreshProgress extends StatelessWidget {
  const RefreshProgress({super.key, this.label = '正在刷新'});
  final String label;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: label,
      liveRegion: true,
      child: IgnorePointer(
        child: Center(
          child: RepaintBoundary(
            child: LinearProgressIndicator(
              value: MediaQuery.disableAnimationsOf(context) ? .5 : null,
              minHeight: 2,
              borderRadius: BorderRadius.circular(2),
              color: ink.withValues(alpha: .45),
              backgroundColor: ink.withValues(alpha: .06),
            ),
          ),
        ),
      ),
    );
  }
}

/// Static placeholders: no shimmer, repeating ticker, filter or loading mascot.
/// Decorative shapes have one accessible loading label, not separate controls.
class LoadingSkeleton extends StatelessWidget {
  const LoadingSkeleton({
    super.key,
    required this.layout,
    this.topInset = 0,
    this.label = '正在加载',
  });
  final SkeletonLayout layout;
  final double topInset;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: ClipRect(
          child: RepaintBoundary(
            child: CustomPaint(
              key: ValueKey('skeleton-${layout.name}'),
              painter: _SkeletonPainter(
                layout: layout,
                top: topInset,
                shelf3d: PerformanceScope.of(context).shelf3d,
                ink: Theme.of(context).colorScheme.onSurface,
                dark: Theme.of(context).brightness == Brightness.dark,
                base: Theme.of(context).brightness == Brightness.dark
                    ? Theme.of(
                            context,
                          ).extension<WenkuTonalColors>()?.glassSurface ??
                          ArchiveDesign.darkSurface
                    : Theme.of(context).extension<WenkuTonalColors>()?.milk ??
                          ArchiveDesign.milk,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SkeletonPainter extends CustomPainter {
  const _SkeletonPainter({
    required this.layout,
    required this.top,
    required this.shelf3d,
    required this.ink,
    required this.dark,
    required this.base,
  });
  final SkeletonLayout layout;
  final double top;
  final bool shelf3d;
  final Color ink;
  final bool dark;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = ink.withValues(alpha: dark ? .0825 : .0625);
    void block(double x, double y, double w, double h, [double radius = 2]) {
      if (w <= 0 || h <= 0) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, h),
          Radius.circular(radius),
        ),
        fill,
      );
    }

    if (layout == SkeletonLayout.bookRow) {
      block(0, 13, 56, 76, ArchiveDesign.coverRadius);
      block(71, 20, 65, 7);
      block(71, 35, (size.width - 93) * .87, 15);
      block(71, 64, (size.width - 93) * .55, 10);
      return;
    }
    if (layout == SkeletonLayout.review ||
        layout == SkeletonLayout.reviewThread) {
      final thread = layout == SkeletonLayout.reviewThread;
      block(0, 4, size.width * .76, 15);
      if (thread) {
        final lines = math.max(1, ((size.height - 72) / 24).floor());
        for (var line = 0; line < lines; line++) {
          block(
            0,
            36 + line * 24,
            size.width * (line == lines - 1 ? .62 : .96),
            10,
          );
        }
      } else {
        block(0, 35, size.width * .92, 10);
      }
      block(0, math.max(56, size.height - 32), size.width * .44, 8);
      if (!thread) block(0, size.height - 8, size.width * .58, 8);
      return;
    }
    if (layout == SkeletonLayout.inline) {
      block(0, (size.height - 8) / 2, size.width * .78, 8);
      return;
    }
    if (layout == SkeletonLayout.button) {
      final y = (size.height - 12) / 2;
      block(0, y, 12, 12);
      block(22, y + 2, size.width - 22, 8);
      return;
    }
    if (layout == SkeletonLayout.cover) {
      final inset = size.width * .12;
      block(inset, inset, size.width - inset * 2, size.height * .52);
      block(inset, size.height * .74, size.width * .64, 5);
      block(inset, size.height * .83, size.width * .43, 4);
      return;
    }
    if (layout == SkeletonLayout.history || layout == SkeletonLayout.actions) {
      if (size.height < 40) {
        block(
          0,
          math.max(0, (size.height - 8) / 2),
          size.width * .72,
          math.min(8, size.height),
        );
        return;
      }
      if (size.height < 72) {
        block(0, 6, size.width * .78, 10);
        block(0, 28, size.width * .51, 8);
        return;
      }
      block(16, 19, (size.width - 32) * .78, 15);
      block(16, 48, (size.width - 32) * .51, 10);
      if (layout == SkeletonLayout.history) {
        block(16, 70, (size.width - 32) * .63, 10);
      }
      return;
    }
    if (layout == SkeletonLayout.detail) {
      block(0, 0, 54, 18);
      for (var i = 0; i < 4; i++) {
        block(0, 39 + i * 22, size.width * (i == 3 ? .68 : 1), 11);
      }
      block(0, 158, 54, 18);
      for (var i = 0; i < 3; i++) {
        final y = 198.0 + i * 45;
        block(0, y, 20, 11);
        block(42, y, size.width * (i == 1 ? .52 : .69), 12);
      }
      return;
    }
    if (layout == SkeletonLayout.readerVertical) {
      for (var column = 0; column * 28 < size.width - 10; column++) {
        final x = size.width - 11 - column * 28;
        final inset = column % 4 == 0 ? 24.0 : 0.0;
        block(
          x,
          inset,
          11,
          (size.height * (column % 4 == 3 ? .65 : .94) - inset).clamp(
            0,
            size.height,
          ),
        );
      }
      return;
    }
    if (layout == SkeletonLayout.reader) {
      for (var i = 0; i * 25 < size.height; i++) {
        block(
          i % 4 == 0 ? 24 : 0,
          i * 25,
          size.width * (i % 4 == 3 ? .64 : .94) - (i % 4 == 0 ? 24 : 0),
          11,
        );
      }
      return;
    }
    const left = 24.0;
    final content = size.width - 48;
    var y = top;
    if (layout == SkeletonLayout.library) {
      block(left, y, 66, 7);
      block(left, y + 19, 90, 18);
      y += 58;
      final bankWidth = math.min(
        content,
        ArchiveShelfGeometry.maxViewportWidth,
      );
      final bankLeft = left + (content - bankWidth) / 2;
      final cover = ArchiveShelfGeometry.coverFor(bankWidth);
      final rowHeight = ArchiveShelfGeometry.rowHeight(
        cover,
        ArchiveShelfGeometry.bodyHeight(cover),
      );
      if (shelf3d) {
        canvas.save();
        canvas.translate(bankLeft, y);
        _ArchiveShelfSkeletonPainter(
          dark: dark,
          ink: ink,
          base: base,
        ).paint(canvas, Size(bankWidth, rowHeight));
        canvas.restore();
        y += rowHeight + 16;
      } else {
        // Flat carousel: one centred cover face, no projected bank.
        final flatWidth = math.min(bankWidth, 440.0);
        final flatLeft = left + (content - flatWidth) / 2;
        final flatCover = flatWidth * .62;
        final flatHeight = flatCover * 166 / 118;
        block(
          flatLeft + (flatWidth - flatCover) / 2,
          y,
          flatCover,
          flatHeight,
          ArchiveDesign.coverRadius,
        );
        y += flatHeight + 16;
        block(flatLeft, y, flatWidth * .5, 15);
        block(flatLeft, y + 29, flatWidth * .34, 10);
        y += 60;
      }
      block(bankLeft, y, bankWidth * .65, 15);
      block(bankLeft, y + 29, bankWidth * .43, 10);
      block(bankLeft, y + 65, bankWidth * .5, 7);
      y += 104;
    }
    block(left, y, 66, 7);
    block(left, y + 19, 90, 18);
    y += 54;
    final columns = BookCollectionLayout.columnsFor(content);
    final cell = (content - (columns - 1) * BookCollectionLayout.gap) / columns;
    for (var i = 0; i < 6 && y < size.height - 74; i++) {
      for (var column = 0; column < columns; column++) {
        final x = left + column * (cell + BookCollectionLayout.gap);
        block(x, y, 56, 76, ArchiveDesign.coverRadius);
        block(x + 71, y + 7, 65, 7);
        block(x + 71, y + 22, (cell - 93) * .87, 15);
        block(x + 71, y + 51, (cell - 93) * .55, 10);
      }
      y += 101;
    }
  }

  @override
  bool shouldRepaint(_SkeletonPainter oldDelegate) =>
      layout != oldDelegate.layout ||
      top != oldDelegate.top ||
      shelf3d != oldDelegate.shelf3d ||
      ink != oldDelegate.ink ||
      base != oldDelegate.base ||
      dark != oldDelegate.dark;
}

/// Keeps the loading collection aligned with the selected library layout.
class LibrarySkeleton extends StatelessWidget {
  const LibrarySkeleton({
    super.key,
    this.header,
    this.featured = true,
    this.grid = false,
    this.gridDensity = const BookGridDensity.auto(),
  });
  final Widget? header;
  final bool featured, grid;
  final BookGridDensity gridDensity;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在翻开文库',
    liveRegion: true,
    container: true,
    explicitChildNodes: true,
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        MediaQuery.paddingOf(context).top + 76,
        24,
        MediaQuery.paddingOf(context).bottom + 120,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header ??
              const SizedBox(
                height: 44,
                child: LoadingSkeleton(layout: SkeletonLayout.actions),
              ),
          const SizedBox(height: 14),
          if (featured) const ArchiveShelfSkeleton(),
          const SizedBox(height: 32),
          const SizedBox(
            height: 44,
            child: LoadingSkeleton(layout: SkeletonLayout.actions),
          ),
          const SizedBox(height: 8),
          BookCollectionSkeleton(grid: grid, gridDensity: gridDensity),
        ],
      ),
    ),
  );
}

/// The loading wave uses the same solids and frame clock as the arriving bank.
/// Other skeletons stay static, and reduced-motion keeps this bank still too.
class ArchiveShelfSkeleton extends StatefulWidget {
  const ArchiveShelfSkeleton({super.key});
  @override
  State<ArchiveShelfSkeleton> createState() => _ArchiveShelfSkeletonState();
}

class _ArchiveShelfSkeletonState extends State<ArchiveShelfSkeleton>
    with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );
  bool _animated = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animated =
        !MediaQuery.disableAnimationsOf(context) &&
        PerformanceScope.of(context).motion &&
        PerformanceScope.of(context).shelf3d &&
        TickerMode.valuesOf(context).enabled;
    if (_animated && !_wave.isAnimating) _wave.repeat();
    if (!_animated) _wave.stop();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shelf3d = PerformanceScope.of(context).shelf3d;
    if (!shelf3d) {
      // The planar carousel replaces the projected bank. The loading placeholder
      // must switch with it, or the page would show 3D bones then a flat face.
      final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
      return IgnorePointer(
        child: ExcludeSemantics(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    key: const ValueKey('archive-shelf-skeleton'),
                    height: 300,
                    child: const LoadingSkeleton(layout: SkeletonLayout.cover),
                  ),
                  SizedBox(
                    height: 16 + 17 * 1.35 * 2 * scale + 12 * 1.4 * scale,
                    child: const LoadingSkeleton(
                      layout: SkeletonLayout.actions,
                    ),
                  ),
                  const SizedBox(
                    height: 40,
                    child: LoadingSkeleton(layout: SkeletonLayout.inline),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ArchiveShelfGeometry.maxViewportWidth,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cover = ArchiveShelfGeometry.coverFor(
                  constraints.maxWidth,
                );
                final height = ArchiveShelfGeometry.bodyHeight(cover);
                final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('archive-shelf-skeleton'),
                        painter: _ArchiveShelfSkeletonPainter(
                          wave: _animated ? _wave : null,
                          dark: Theme.of(context).brightness == Brightness.dark,
                          ink: Theme.of(context).colorScheme.onSurface,
                          base: Theme.of(context).brightness == Brightness.dark
                              ? Theme.of(context)
                                        .extension<WenkuTonalColors>()
                                        ?.glassSurface ??
                                    ArchiveDesign.darkSurface
                              : Theme.of(
                                      context,
                                    ).extension<WenkuTonalColors>()?.milk ??
                                    ArchiveDesign.milk,
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          height: ArchiveShelfGeometry.rowHeight(cover, height),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 16 + 17 * 1.35 * 2 * scale + 12 * 1.4 * scale,
                      child: const LoadingSkeleton(
                        layout: SkeletonLayout.actions,
                      ),
                    ),
                    const SizedBox(
                      height: 40,
                      child: LoadingSkeleton(layout: SkeletonLayout.inline),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ArchiveShelfSkeletonPainter extends CustomPainter {
  const _ArchiveShelfSkeletonPainter({
    required this.dark,
    required this.ink,
    required this.base,
    this.wave,
  }) : super(repaint: wave);
  final bool dark;
  final Color ink;
  final Color base;
  final Listenable? wave;
  @override
  void paint(Canvas canvas, Size size) {
    final g = ArchiveShelfGeometry.coverFor(size.width);
    final h = ArchiveShelfGeometry.bodyHeight(g);
    final spine = ArchiveShelfGeometry.spineFor(size.width);
    final pitch = ArchiveShelfGeometry.pitchFor(size.width);
    final centre =
        size.width / 2 -
        ArchiveShelfGeometry.footprint(spine, g) / 2 +
        ArchiveShelfGeometry.pullDistance(g) * ArchiveShelfGeometry.depthX;
    final edge = (size.width / pitch / 2).ceil() + 5;
    final rule = Paint()
      ..color = ink.withValues(alpha: .12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .4;
    final placeholder = Paint()
      ..color = ink.withValues(alpha: dark ? .0825 : .0625);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = -edge; i <= edge; i++) {
      final weight = i.abs() < 1.48
          ? math.pow(math.cos(i / 1.48 * math.pi / 2), 2).toDouble()
          : 0.0;
      final origin =
          ArchiveShelfGeometry.origin(g, h, weight) +
          Offset(
            centre + i * pitch,
            ArchiveShelfGeometry.railY(i.toDouble()) +
                (wave == null
                    ? 0
                    : archiveLoadingLift(
                        i.toDouble(),
                        SchedulerBinding.instance.currentSystemFrameTimeStamp,
                        1,
                      )),
          );
      final front = Offset(spine, spine * .1);
      final depth = Offset(
        g * ArchiveShelfGeometry.depthX,
        g * ArchiveShelfGeometry.depthY,
      );
      final side = Path()
        ..addPolygon([
          origin + front,
          origin + front + depth,
          origin + front + depth + Offset(0, h),
          origin + front + Offset(0, h),
        ], true);
      canvas.drawPath(side, Paint()..color = base);
      canvas.drawPath(side, rule);
      // Cover and two metadata bands are projected onto the same face, rather
      // than floating screen-space rectangles over neighbouring files.
      canvas.save();
      canvas.transform(
        (Matrix4.identity()
              ..setEntry(0, 0, ArchiveShelfGeometry.depthX)
              ..setEntry(1, 0, ArchiveShelfGeometry.depthY)
              ..setEntry(0, 3, origin.dx + spine)
              ..setEntry(1, 3, origin.dy + spine * .1))
            .storage,
      );
      canvas.drawRect(Rect.fromLTWH(10, 10, g - 20, h - 54), placeholder);
      canvas.drawRect(Rect.fromLTWH(10, h - 31, (g - 20) * .7, 5), placeholder);
      canvas.drawRect(
        Rect.fromLTWH(10, h - 18, (g - 20) * .45, 4),
        placeholder,
      );
      canvas.restore();
      final top = Path()
        ..addPolygon([
          origin,
          origin + front,
          origin + front + depth,
          origin + depth,
        ], true);
      canvas.drawPath(top, Paint()..color = Color.lerp(base, ink, .035)!);
      canvas.drawPath(top, rule);
      final face = Path()
        ..addPolygon([
          origin,
          origin + front,
          origin + front + Offset(0, h),
          origin + Offset(0, h),
        ], true);
      canvas.drawPath(face, Paint()..color = Color.lerp(base, ink, .065)!);
      canvas.drawPath(face, rule);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArchiveShelfSkeletonPainter oldDelegate) =>
      dark != oldDelegate.dark ||
      ink != oldDelegate.ink ||
      base != oldDelegate.base ||
      wave != oldDelegate.wave;
}

class SearchSkeleton extends StatelessWidget {
  const SearchSkeleton({super.key, this.status});
  final String? status;
  @override
  Widget build(BuildContext context) => Semantics(
    label: status ?? '正在找故事',
    liveRegion: true,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        maxHeight: double.infinity,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            22,
            MediaQuery.paddingOf(context).top + 76,
            22,
            0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status case final text?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: AppText(text),
                ),
              const SizedBox(
                height: 54,
                child: LoadingSkeleton(layout: SkeletonLayout.actions),
              ),
              const BookCollectionSkeleton(rows: 6),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Uses the arriving collection's cover geometry instead of an automatic grid.
class BookCollectionSkeleton extends StatelessWidget {
  const BookCollectionSkeleton({
    super.key,
    this.rows = 3,
    this.label = '正在载入书籍',
    this.grid = false,
    this.gridDensity = const BookGridDensity.auto(),
  });
  final int rows;
  final String label;
  final bool grid;
  final BookGridDensity gridDensity;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final geometry = grid && !gridDensity.automatic
          ? BookGridViewport(
              width: constraints.maxWidth,
              height: MediaQuery.sizeOf(context).height,
              textScaler: MediaQuery.textScalerOf(context),
            ).resolve(gridDensity)
          : null;
      final columns = grid
          ? geometry?.columns ??
                BookCollectionLayout.gridColumnsFor(constraints.maxWidth)
          : BookCollectionLayout.columnsFor(constraints.maxWidth);
      final gap = grid
          ? BookCollectionLayout.gridGap
          : BookCollectionLayout.gap;
      final collection = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < rows; row++)
            Padding(
              padding: EdgeInsets.only(
                bottom: !grid
                    ? 0
                    : geometry?.fixed == true
                    ? BookCollectionLayout.gridGap
                    : BookCollectionLayout.gap,
              ),
              child: Row(
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column != 0) SizedBox(width: gap),
                    Expanded(
                      child: grid
                          ? BookGridSkeleton(label: label)
                          : BookRowSkeleton(label: label),
                    ),
                  ],
                ],
              ),
            ),
        ],
      );
      return geometry?.fixed == true
          ? BookGridScope(geometry: geometry!, child: collection)
          : collection;
    },
  );
}

class DetailSkeleton extends StatelessWidget {
  const DetailSkeleton({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 310,
    width: double.infinity,
    child: LoadingSkeleton(layout: SkeletonLayout.detail, label: '正在打开这本书'),
  );
}

/// Reserve a real metadata line without showing an unconfirmed count or label.
class InlineSkeleton extends StatelessWidget {
  const InlineSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 18,
    this.label = '正在加载信息',
  });
  final double width;
  final double height;
  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: LoadingSkeleton(layout: SkeletonLayout.inline, label: label),
  );
}

class ReaderSkeleton extends StatelessWidget {
  const ReaderSkeleton({super.key, this.vertical = false, this.expand = false});
  final bool vertical, expand;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: expand ? double.infinity : 300,
    width: double.infinity,
    child: LoadingSkeleton(
      layout: vertical ? SkeletonLayout.readerVertical : SkeletonLayout.reader,
      label: '正在加载正文',
    ),
  );
}

class BookRowSkeleton extends StatelessWidget {
  const BookRowSkeleton({super.key, this.label = '正在载入书籍'});
  final String label;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 102,
    width: double.infinity,
    child: LoadingSkeleton(layout: SkeletonLayout.bookRow, label: label),
  );
}

class BookGridSkeleton extends StatelessWidget {
  const BookGridSkeleton({super.key, this.label = '正在载入书籍'});
  final String label;

  @override
  Widget build(BuildContext context) {
    final geometry = BookGridScope.of(context);
    if (geometry?.fixed == true) {
      return Semantics(
        label: label,
        child: ExcludeSemantics(
          child: SizedBox(
            height: geometry!.rowHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SizedBox(
                    width: geometry.coverWidth,
                    height: geometry.coverHeight,
                    child: const LoadingSkeleton(layout: SkeletonLayout.cover),
                  ),
                ),
                const SizedBox(height: 10),
                InlineSkeleton(height: geometry.viewport.titleHeight),
                const SizedBox(height: 4),
                InlineSkeleton(height: geometry.viewport.authorHeight),
                const SizedBox(height: 4),
                InlineSkeleton(height: geometry.viewport.progressHeight),
              ],
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverHeight =
            constraints.maxWidth / BookCollectionLayout.gridCoverAspectRatio;
        final captionHeight = constraints.maxHeight - coverHeight;
        return Semantics(
          label: label,
          liveRegion: true,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: coverHeight,
                  child: const LoadingSkeleton(layout: SkeletonLayout.cover),
                ),
                // Auto-layout cells reserve their own footer space. Keep the
                // cover ratio and only draw captions that fit the actual cell.
                if (captionHeight >= 28) ...[
                  const SizedBox(height: 10),
                  const InlineSkeleton(height: 18),
                ],
                if (captionHeight >= 48) ...[
                  const SizedBox(height: 6),
                  InlineSkeleton(width: constraints.maxWidth * .65, height: 14),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
