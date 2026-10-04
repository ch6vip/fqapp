import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_detail.dart';
import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_media_card.dart';

/// Detail-page masthead: the cover sits on the left with the title, metadata
/// and origin badge stacked to its right, matching the official layout.
///
/// Only the tinted backdrop follows the scroll offset; the text does not
/// rebuild per frame. The title deliberately has no `maxLines` so it always
/// wraps in full rather than truncating.
class DetailHero extends StatelessWidget {
  final MediaItem item;
  final BookDetail? detail;
  final ScrollController scroll;

  const DetailHero({
    super.key,
    required this.item,
    required this.scroll,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final meta = detail?.metaParts ?? const <String>[];
    final title = detail?.title.isNotEmpty == true ? detail!.title : item.title;
    // A 3x accessibility scale cannot fit a cover beside the text on a narrow
    // phone, so the masthead stacks instead of squeezing both into one row.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 26;

    final cover = _CoverTile(item: item, detail: detail);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BookTitle(
          text: title,
          style: TextStyle(
            color: palette.ink,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.35,
            letterSpacing: -0.4,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            meta.join(' · '),
            key: const Key('detail_meta_line'),
            style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.4),
          ),
        ],
        if (detail?.original == true) ...[
          const SizedBox(height: 10),
          const _OriginBadge(),
        ],
      ],
    );

    return ClipRect(
      child: Stack(
        children: [
          // Tinted masthead wash. Kept to its own layer so scrolling repaints
          // only this gradient.
          Positioned.fill(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: scroll,
                  builder: (context, _) => CustomPaint(
                    painter: _MastheadWash(
                      palette: palette,
                      shift: scroll.hasClients ? scroll.offset : 0,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Smooth bottom blend gradient fading seamlessly to canvas
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 56,
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      palette.canvas.withValues(alpha: 0),
                      palette.canvas,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 22),
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: cover),
                      const SizedBox(height: 18),
                      info,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      cover,
                      const SizedBox(width: 18),
                      Expanded(child: info),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 3:4 cover with a soft shadow, tappable to open the zoomable viewer.
class _CoverTile extends StatelessWidget {
  final MediaItem item;
  final BookDetail? detail;

  const _CoverTile({required this.item, this.detail});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // The cover keeps its 3:4 ratio; it only grows a little with text scale so
    // the text column is never starved of width.
    final width = 104.0 + (scaler.scale(16) - 16).clamp(0.0, 10.0) * 1.2;
    return SizedBox(
      width: width,
      child: HomePressable(
        key: const Key('detail_cover_button'),
        semanticLabel: '查看《${item.title}》封面',
        onTap: () => showDetailCover(context, item),
        borderRadius: BorderRadius.circular(12),
        child: ExcludeSemantics(
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: palette.dark ? 0.46 : 0.16,
                    ),
                    blurRadius: 20,
                    spreadRadius: -4,
                    offset: const Offset(2, 9),
                  ),
                  BoxShadow(
                    color: HomePalette.accent.withValues(
                      alpha: palette.dark ? 0.10 : 0.05,
                    ),
                    blurRadius: 14,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    StoryCover(item: item, cacheWidth: 320),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 14,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withValues(alpha: 0.28),
                              Colors.white.withValues(alpha: 0.18),
                              Colors.transparent,
                            ],
                            stops: const [0, 0.32, 1],
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: palette.dark ? 0.16 : 0.28,
                            ),
                            width: 0.8,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `番茄原创` chip shown under the metadata line for original works.
class _OriginBadge extends StatelessWidget {
  const _OriginBadge();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: HomePalette.accent.withValues(alpha: palette.dark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: HomePalette.accent.withValues(alpha: palette.dark ? 0.32 : 0.22),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.sparkles,
            size: 11,
            color: palette.accentText,
          ),
          const SizedBox(width: 4),
          Text(
            '番茄原创',
            style: TextStyle(
              color: palette.accentText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Book title that always shows the complete name. A phrase boundary
/// (`，：`) is preferred over leaving one or two characters on their own line.
class _BookTitle extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _BookTitle({required this.text, required this.style});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
      final painter = TextPainter(
        textDirection: Directionality.of(context),
        textScaler: scaler,
      );
      void measure(String value, [double? width]) {
        painter.text = TextSpan(text: value, style: effectiveStyle);
        painter.layout(maxWidth: width ?? double.infinity);
      }

      measure(text);
      final naturalWidth = painter.width;
      var display = text;
      var width = constraints.maxWidth;
      if (naturalWidth > width &&
          naturalWidth < width * 2 &&
          scaler.scale(1) <= 1.6) {
        var difference = double.infinity;
        for (final match in RegExp('[，,：:]').allMatches(text)) {
          final head = text.substring(0, match.end);
          final tail = text.substring(match.end).trimLeft();
          if (tail.isEmpty) continue;
          measure(head);
          final headWidth = painter.width;
          measure(tail);
          final tailWidth = painter.width;
          final balance = (headWidth - tailWidth).abs();
          if (headWidth <= width &&
              tailWidth <= width &&
              headWidth > naturalWidth * 0.25 &&
              tailWidth > naturalWidth * 0.25 &&
              balance < difference) {
            display = '$head\n$tail';
            difference = balance;
          }
        }
      }
      painter.dispose();
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Text(
          display,
          key: const Key('detail_book_title'),
          semanticsLabel: text,
          style: style,
        ),
      );
    },
  );
}

/// Soft accent wash behind the masthead, fading into the page background.
/// It lifts slightly as the page scrolls, then stops.
class _MastheadWash extends CustomPainter {
  final HomePalette palette;
  final double shift;

  const _MastheadWash({required this.palette, required this.shift});

  @override
  void paint(Canvas canvas, Size size) {
    final lift = shift.clamp(0.0, 240.0) * 0.22;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          HomePalette.accent.withValues(alpha: palette.dark ? 0.17 : 0.10),
          HomePalette.accent.withValues(alpha: palette.dark ? 0.05 : 0.03),
          palette.canvas.withValues(alpha: 0),
        ],
        stops: const [0, 0.5, 1],
      ).createShader(rect.translate(0, -lift));
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_MastheadWash oldDelegate) =>
      oldDelegate.palette.dark != palette.dark || oldDelegate.shift != shift;
}

Future<void> showDetailCover(BuildContext context, MediaItem item) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭封面',
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: IconButton(
                    tooltip: '关闭封面',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x, color: Colors.white),
                  ),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  key: const Key('detail_cover_viewer'),
                  maxScale: 3,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: AspectRatio(
                          aspectRatio: 5 / 7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: StoryCover(item: item, cacheWidth: 1000),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
                child: Text(
                  item.title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
