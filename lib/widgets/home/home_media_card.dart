import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/poster_cache.dart';
import '../cover_tag_chip.dart';
import 'home_design.dart';

String homeKindLabel(String kind) => switch (kind) {
  'video' => '短剧',
  'manju' => '漫剧',
  'manga' => '漫画',
  'audio' => '听书',
  _ => '小说',
};

IconData homeKindIcon(String kind) => switch (kind) {
  'video' => LucideIcons.clapperboard,
  'manju' => LucideIcons.film,
  'manga' => LucideIcons.image,
  'audio' => LucideIcons.headphones,
  _ => LucideIcons.book_open,
};

const double _homeCrossAxisSpacing = 16;

/// Two columns on phones give covers enough presence to be recognizable.
/// Adding a third column at 320–400dp was the main source of the previous
/// cramped first screen: every title was squeezed into a thumbnail-sized cell.
int _homeColumns(BuildContext context, double width) {
  if (width < 560) return 2;
  if (width < 820) return 3;
  return 4;
}

/// Laid-out width of one cover cell. [width] is the grid's content width, i.e.
/// the viewport width minus the page gutter on both sides.
double homeCardWidth(BuildContext context, double width) {
  final columns = _homeColumns(context, width);
  return (width - (columns - 1) * _homeCrossAxisSpacing) / columns;
}

SliverGridDelegate homeGridDelegate(BuildContext context, double width) {
  final scaler = MediaQuery.textScalerOf(context);
  final cardWidth = homeCardWidth(context, width);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: _homeColumns(context, width),
    crossAxisSpacing: _homeCrossAxisSpacing,
    mainAxisSpacing: 26,
    mainAxisExtent:
        cardWidth * 1.4 +
        10 +
        scaler.scale(15) * HomeType.cardLineHeight * 2 +
        7 +
        scaler.scale(12) * HomeType.metaLineHeight +
        2,
  );
}

class StoryCover extends StatelessWidget {
  final MediaItem item;
  final int cacheWidth;
  final Alignment alignment;

  const StoryCover({
    super.key,
    required this.item,
    required this.cacheWidth,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = CustomPaint(
      painter: _CoverArtwork(item.kind),
      child: Center(
        child: Icon(
          homeKindIcon(item.kind),
          color: Colors.white.withValues(alpha: 0.32),
          size: 38,
        ),
      ),
    );
    if (item.cover.isEmpty) return fallback;
    return CachedNetworkImage(
      cacheManager: PosterCache.instance,
      imageUrl: item.cover,
      fit: BoxFit.cover,
      alignment: alignment,
      memCacheWidth: cacheWidth.clamp(1, 1200),
      fadeInDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      placeholder: (_, _) => fallback,
      errorWidget: (_, _, _) => fallback,
    );
  }
}

/// Original geometric fallback artwork for failed or missing upstream covers.
class _CoverArtwork extends CustomPainter {
  final String kind;

  const _CoverArtwork(this.kind);

  @override
  void paint(Canvas canvas, Size size) {
    final colors = switch (kind) {
      'video' => [const Color(0xFF734740), const Color(0xFF242428)],
      'manju' => [const Color(0xFF8B557E), const Color(0xFF35283D)],
      'manga' => [const Color(0xFF6F6887), const Color(0xFF343349)],
      'audio' => [const Color(0xFF426C78), const Color(0xFF233B42)],
      _ => [const Color(0xFF6A7964), const Color(0xFF293C35)],
    };
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(Offset.zero & size),
    );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFFF2DFC3).withValues(alpha: 0.22);
    final center = Offset(size.width * 0.92, size.height * 0.30);
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(center, size.width * (0.27 + i * 0.14), line);
    }
    canvas.save();
    canvas.translate(size.width * 0.17, size.height * 0.74);
    canvas.rotate(-math.pi / 5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width * 1.1, size.height * 0.13),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFFE2C99A).withValues(alpha: 0.13),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CoverArtwork oldDelegate) => oldDelegate.kind != kind;
}

/// Standard feed card.
///
/// Covers are now left almost entirely to the artwork. A single optional
/// upstream gradient tag and the rating badge are the overlays; type and
/// author/update information live in one tidy metadata line below the title.
class HomeMediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  /// Laid-out cell width supplied by the feed to avoid a LayoutBuilder per card.
  final double? coverWidth;

  const HomeMediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.coverWidth,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    final tint = HomeKindTint.of(item.kind, eink: palette.eink);
    final detail = item.author.isNotEmpty
        ? item.author
        : item.ep.isNotEmpty
        ? item.ep
        : item.badge;

    return _CardWidth(
      width: coverWidth,
      builder: (width) => HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        semanticLabel:
            '${item.title}，${homeKindLabel(item.kind)}'
            '${item.score == null ? '' : '，评分 ${item.score!.toStringAsFixed(1)}'}',
        pressedScale: 0.98,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              key: const Key('home_card_cover'),
              aspectRatio: 5 / 7,
              child: RepaintBoundary(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      StoryCover(
                        item: item,
                        cacheWidth: (width * pixelRatio).ceil(),
                      ),
                      if (item.tag case final MediaTag tag when tag.hasColors)
                        Positioned(
                          left: 7,
                          top: 7,
                          right: 7,
                          child: Row(
                            children: [
                              Flexible(
                                child: CoverTagChip(
                                  key: const Key('home_card_tag'),
                                  label: tag.text,
                                  colors: tag.colorsFor(dark: palette.dark),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (item.score case final score?)
                        Positioned(
                          right: 7,
                          bottom: 7,
                          child: Container(
                            key: const Key('home_card_score'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: palette.eink
                                  ? Colors.white
                                  : const Color(
                                      0xFF1C1B1A,
                                    ).withValues(alpha: 0.76),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.24),
                                width: 0.6,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.star,
                                  size: 10,
                                  color: palette.eink
                                      ? Colors.black
                                      : const Color(0xFFF4C86A),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  score.toStringAsFixed(1),
                                  textScaler: TextScaler.noScaling,
                                  style: HomeType.figure.copyWith(
                                    fontSize: 10,
                                    color: palette.eink
                                        ? Colors.black
                                        : Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: palette.line.withValues(
                                  alpha: palette.dark ? 0.75 : 0.6,
                                ),
                                width: 0.7,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: scaler.scale(15) * HomeType.cardLineHeight * 2,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HomeType.card.copyWith(color: palette.primary),
              ),
            ),
            const SizedBox(height: 7),
            SizedBox(
              height: scaler.scale(12) * HomeType.metaLineHeight,
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                child: Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: palette.eink ? Colors.black : tint,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      homeKindLabel(item.kind),
                      maxLines: 1,
                      style: HomeType.meta.copyWith(
                        fontWeight: FontWeight.w600,
                        color: palette.secondary,
                      ),
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Text(
                        '·',
                        textScaler: TextScaler.noScaling,
                        style: HomeType.meta.copyWith(
                          fontSize: 10,
                          color: palette.tertiary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HomeType.meta.copyWith(
                            color: palette.tertiary,
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hands the child its available width, either measured here or supplied by a
/// caller that already knows it.
class _CardWidth extends StatelessWidget {
  final double? width;
  final Widget Function(double width) builder;

  const _CardWidth({required this.width, required this.builder});

  @override
  Widget build(BuildContext context) {
    final known = width;
    if (known != null) return builder(known);
    return LayoutBuilder(
      builder: (context, constraints) => builder(constraints.maxWidth),
    );
  }
}
