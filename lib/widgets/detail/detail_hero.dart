import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_media_card.dart';

/// The cover stays a real, cached book image. Only this small stage follows
/// scrolling; the text and the rest of the detail page do not rebuild per frame.
class DetailHero extends StatelessWidget {
  final MediaItem item;
  final ScrollController scroll;
  final int? chapterCount;
  final String chapterUnit;

  const DetailHero({
    super.key,
    required this.item,
    required this.scroll,
    required this.chapterCount,
    required this.chapterUnit,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 620 &&
            MediaQuery.textScalerOf(context).scale(16) < 29;
        final title = Padding(
          padding: EdgeInsets.fromLTRB(wide ? 8 : 24, 4, 24, 28),
          child: Column(
            crossAxisAlignment: wide
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              _BookTitle(
                text: item.title,
                alignment: wide ? TextAlign.start : TextAlign.center,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: wide ? 30 : 25,
                  fontWeight: FontWeight.w800,
                  height: 1.4,
                  letterSpacing: -0.6,
                ),
              ),
              if (item.author.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  item.author,
                  textAlign: wide ? TextAlign.start : TextAlign.center,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: wide ? WrapAlignment.start : WrapAlignment.center,
                children: [
                  _DetailTag(
                    text: item.badge.isEmpty
                        ? homeKindLabel(item.kind)
                        : item.badge,
                    accent: true,
                  ),
                  if (chapterCount != null && chapterCount! > 0)
                    _DetailTag(text: '共 $chapterCount $chapterUnit'),
                ],
              ),
            ],
          ),
        );
        final stage = _CoverStage(item: item, scroll: scroll);
        return HomeEntrance(
          child: wide
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 8, 8),
                  child: Row(
                    children: [
                      SizedBox(width: 285, child: stage),
                      Expanded(child: title),
                    ],
                  ),
                )
              : Column(children: [stage, title]),
        );
      },
    );
  }
}

class _BookTitle extends StatelessWidget {
  final String text;
  final TextStyle style;
  final TextAlign alignment;

  const _BookTitle({
    required this.text,
    required this.style,
    required this.alignment,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
      final painter = TextPainter(
        textDirection: Directionality.of(context),
        textScaler: scaler,
      );
      double measure(String value) {
        painter.text = TextSpan(text: value, style: effectiveStyle);
        painter.layout();
        return painter.width;
      }

      final naturalWidth = measure(text);
      var display = text;
      var width = constraints.maxWidth;
      // Prefer a phrase boundary over leaving one or two characters alone.
      // No content is truncated, and assistive technology gets the source title.
      if (naturalWidth > width &&
          naturalWidth < width * 2 &&
          scaler.scale(1) <= 1.6) {
        var difference = double.infinity;
        for (final match in RegExp('[，,：:]').allMatches(text)) {
          final head = text.substring(0, match.end);
          final tail = text.substring(match.end).trimLeft();
          final headWidth = measure(head);
          final tailWidth = measure(tail);
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
        if (display == text && alignment == TextAlign.center) {
          final balancedWidth = (naturalWidth / 2 + scaler.scale(20)).clamp(
            width * 0.6,
            width,
          );
          painter.text = TextSpan(text: text, style: effectiveStyle);
          painter.layout(maxWidth: balancedWidth);
          if (painter.computeLineMetrics().length == 2) width = balancedWidth;
        }
      }
      painter.dispose();
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Text(
          display,
          key: const Key('detail_book_title'),
          semanticsLabel: text,
          textAlign: alignment,
          style: style,
        ),
      );
    },
  );
}

class _DetailTag extends StatelessWidget {
  final String text;
  final bool accent;

  const _DetailTag({required this.text, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: accent
            ? HomePalette.accent.withValues(alpha: palette.dark ? 0.13 : 0.08)
            : palette.soft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: accent ? palette.accentText : palette.muted,
          fontSize: 11,
          fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
          height: 1.4,
        ),
      ),
    );
  }
}

class _CoverStage extends StatelessWidget {
  final MediaItem item;
  final ScrollController scroll;

  const _CoverStage({required this.item, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      width: double.infinity,
      height: 228,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (item.cover.isNotEmpty)
                        Center(
                          child: Opacity(
                            opacity: palette.dark ? 0.19 : 0.13,
                            child: ImageFiltered(
                              imageFilter: ui.ImageFilter.blur(
                                sigmaX: 35,
                                sigmaY: 35,
                              ),
                              child: SizedBox(
                                width: 240,
                                height: 150,
                                child: StoryCover(item: item, cacheWidth: 96),
                              ),
                            ),
                          ),
                        ),
                      CustomPaint(painter: _StageLines(palette)),
                      Align(
                        alignment: const Alignment(0, 0.14),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'STORY',
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              color: palette.ink.withValues(alpha: 0.045),
                              fontSize: 84,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 12,
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
          AnimatedBuilder(
            animation: scroll,
            child: HomePressable(
              key: const Key('detail_cover_button'),
              semanticLabel: '查看《${item.title}》封面',
              onTap: () => showDetailCover(context, item),
              borderRadius: BorderRadius.circular(10),
              child: ExcludeSemantics(
                child: Container(
                  width: 142,
                  height: 199,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: palette.dark ? 0.38 : 0.21,
                        ),
                        blurRadius: 25,
                        spreadRadius: -6,
                        offset: const Offset(6, 18),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        StoryCover(item: item, cacheWidth: 426),
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: 15,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.black.withValues(alpha: 0.28),
                                  Colors.white.withValues(alpha: 0.18),
                                  Colors.transparent,
                                ],
                                stops: const [0, 0.3, 1],
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.22),
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
            builder: (context, child) {
              final offset = !reducedMotion && scroll.hasClients
                  ? scroll.offset.clamp(-70.0, 320.0)
                  : 0.0;
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..translateByDouble(0, offset * 0.12, 0, 1)
                  ..rotateY(-0.08)
                  ..rotateZ(-0.045),
                child: child,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StageLines extends CustomPainter {
  final HomePalette palette;

  const _StageLines(this.palette);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = palette.ink.withValues(alpha: 0.055);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height * 0.70),
        width: size.width * 0.89,
        height: 98,
      ),
      line,
    );
    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 0.87),
      Offset(size.width * 0.92, size.height * 0.87),
      line,
    );
  }

  @override
  bool shouldRepaint(_StageLines oldDelegate) =>
      palette.dark != oldDelegate.palette.dark;
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
