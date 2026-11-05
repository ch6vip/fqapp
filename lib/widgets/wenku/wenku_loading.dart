// Ported from Wenku8_Flutter lib/loading_ui.dart (revision ebcd7f1).
//
// Mechanical substitutions for dependencies fqapp does not ship:
// - `app_language.dart` `AppText` -> `src/app_text.dart` `AppText`. Chinese
//   input is returned unchanged; the upstream locale lookup and OpenCC
//   conversion are intentionally absent.
// - `app_palette.dart` `AppTonalColors` -> `wenku_theme.dart`
//   `WenkuTonalColors`; the `milk` / `glassSurface` lookups are the same.
// - `archive_design.dart` -> `wenku_archive.dart` `ArchiveDesign`.
// - `archive_shelf_geometry.dart` -> private `_ArchiveShelfGeometry`, copied
//   verbatim for `ArchiveShelfSkeleton` and the library skeleton.
// - `archive_shelf_loading.dart` `archiveLoadingLift` -> private
//   `_archiveLoadingLift`, copied verbatim.
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
    required this.ink,
    required this.dark,
    required this.base,
  });
  final SkeletonLayout layout;
  final double top;
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
        _ArchiveShelfGeometry.maxViewportWidth,
      );
      final bankLeft = left + (content - bankWidth) / 2;
      final cover = _ArchiveShelfGeometry.coverFor(bankWidth);
      final rowHeight = _ArchiveShelfGeometry.rowHeight(
        cover,
        _ArchiveShelfGeometry.bodyHeight(cover),
      );
      canvas.save();
      canvas.translate(bankLeft, y);
      _ArchiveShelfSkeletonPainter(
        dark: dark,
        ink: ink,
        base: base,
      ).paint(canvas, Size(bankWidth, rowHeight));
      canvas.restore();
      y += rowHeight + 16;
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
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _ArchiveShelfGeometry.maxViewportWidth,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cover = _ArchiveShelfGeometry.coverFor(
                constraints.maxWidth,
              );
              final height = _ArchiveShelfGeometry.bodyHeight(cover);
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
                        height: _ArchiveShelfGeometry.rowHeight(cover, height),
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
    final g = _ArchiveShelfGeometry.coverFor(size.width);
    final h = _ArchiveShelfGeometry.bodyHeight(g);
    final spine = _ArchiveShelfGeometry.spineFor(size.width);
    final pitch = _ArchiveShelfGeometry.pitchFor(size.width);
    final centre =
        size.width / 2 -
        _ArchiveShelfGeometry.footprint(spine, g) / 2 +
        _ArchiveShelfGeometry.pullDistance(g) * _ArchiveShelfGeometry.depthX;
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
          _ArchiveShelfGeometry.origin(g, h, weight) +
          Offset(
            centre + i * pitch,
            _ArchiveShelfGeometry.railY(i.toDouble()) +
                (wave == null
                    ? 0
                    : _archiveLoadingLift(
                        i.toDouble(),
                        SchedulerBinding.instance.currentSystemFrameTimeStamp,
                        1,
                      )),
          );
      final front = Offset(spine, spine * .1);
      final depth = Offset(
        g * _ArchiveShelfGeometry.depthX,
        g * _ArchiveShelfGeometry.depthY,
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
              ..setEntry(0, 0, _ArchiveShelfGeometry.depthX)
              ..setEntry(1, 0, _ArchiveShelfGeometry.depthY)
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

/// Verbatim copy of upstream `archive_shelf_geometry.dart`, kept private
/// because the loaded archive shelf is outside this batch.
abstract final class _ArchiveShelfGeometry {
  // A physical bank, not a full-window banner. Keep the same projection and
  // book proportions on phones, tablets and retained browsing panes.
  static const maxViewportWidth = 520.0;
  static const depthX = .66, depthY = -.30, rowStep = 2.5;
  static double spineFor(double width) => (width * .043).clamp(14.0, 18.0);
  static double pitchFor(double width) => spineFor(width) + 11;
  static double coverFor(double width) => (width * .32).clamp(100.0, 128.0);
  static double bodyHeight(double cover) => (cover - 20) * 166 / 118 + 54;
  static double footprint(double spine, double cover) => spine + cover * depthX;
  static double pullDistance(double cover) => cover * .84;
  static double baseY(double cover, double height) =>
      -cover * depthY + height * .60 + 12;
  static double rowHeight(double cover, double height) =>
      baseY(cover, height) + height + 60;
  static double railY(double distance) {
    final d = distance.clamp(-7.0, 7.0);
    return d * rowStep + d * d * .45;
  }

  static Offset origin(double cover, double height, double weight) {
    final pull = pullDistance(cover) * weight * (1.24 - .24 * weight);
    final lift = weight * weight * (3 - 2 * weight);
    return Offset(
      -pull * depthX,
      baseY(cover, height) - pull * depthY - height * .60 * lift,
    );
  }
}

/// Verbatim copy of upstream `archive_shelf_loading.dart`'s wave function.
double _archiveLoadingLift(double lane, Duration frame, double remaining) {
  final phase = frame.inMicroseconds / 1700000 - lane * .075;
  final crest = (1 + math.sin(phase * math.pi * 2)) / 2;
  return -9 * crest * crest * remaining;
}
