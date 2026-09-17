import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
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

/// Fixed cover proportions, with a measured text allowance for large fonts.
int _homeColumns(BuildContext context, double width) {
  final scaler = MediaQuery.textScalerOf(context);
  final largeType = scaler.scale(14) > 21;
  return largeType && width < 560
      ? 2
      : width < 300
      ? 2
      : width < 560
      ? 3
      : width < 740
      ? 4
      : 5;
}

/// The laid-out width of one cover cell. Shared with the cards so the decoded
/// cover size matches the cell exactly, which lets a card skip a
/// [LayoutBuilder] of its own.
double homeCardWidth(BuildContext context, double width) {
  final columns = _homeColumns(context, width);
  return (width - (columns - 1) * 14) / columns;
}

SliverGridDelegate homeGridDelegate(BuildContext context, double width) {
  final scaler = MediaQuery.textScalerOf(context);
  final cardWidth = homeCardWidth(context, width);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: _homeColumns(context, width),
    crossAxisSpacing: 14,
    mainAxisSpacing: 22,
    mainAxisExtent:
        cardWidth * 1.4 +
        8 +
        scaler.scale(14) * 1.35 * 2 +
        5 +
        scaler.scale(11) * 1.3 +
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

/// An original geometric cover is useful even when an upstream image fails.
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

class HomeMediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  /// Laid-out cell width. The feed already knows it (it sized the grid
  /// delegate with it), and passing it in avoids a [LayoutBuilder] per card.
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
    return _CardWidth(
      width: coverWidth,
      builder: (width) => HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
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
                      Positioned(
                        left: 7,
                        top: 7,
                        right: 7,
                        child: Row(
                          children: [
                            CoverTagChip(label: homeKindLabel(item.kind)),
                            // Only coloured tags are badges; see MediaTag.hasColors.
                            if (item.tag case final MediaTag tag
                                when tag.hasColors) ...[
                              const SizedBox(width: 4),
                              // Flexible so a long upstream label ellipsizes
                              // instead of overflowing the cover.
                              Flexible(
                                child: CoverTagChip(
                                  key: const Key('home_card_tag'),
                                  label: tag.text,
                                  colors: tag.colorsFor(dark: palette.dark),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (item.ep.isNotEmpty)
                        Positioned(
                          left: 7,
                          right: 7,
                          bottom: 7,
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF1C1B1A,
                                ).withValues(alpha: 0.68),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                item.ep,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  height: 1.2,
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
            const SizedBox(height: 8),
            SizedBox(
              height: scaler.scale(14) * 1.35 * 2,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              item.author.isNotEmpty
                  ? item.author
                  : item.badge.isNotEmpty
                  ? item.badge
                  : homeKindLabel(item.kind),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, height: 1.3, color: palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeSectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const HomeSectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 19,
                decoration: BoxDecoration(
                  color: HomePalette.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 22,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    color: palette.ink,
                  ),
                ),
              ),
              Icon(
                LucideIcons.arrow_down_right,
                size: 21,
                color: palette.muted,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, height: 1.4, color: palette.muted),
          ),
        ],
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
