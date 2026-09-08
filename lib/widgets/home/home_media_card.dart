import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../media_card.dart' show kindLabels;

/// Lucide glyph per media kind, shared by the featured card, grid cards and
/// the marquee strip.
const kindIcons = {
  'book': LucideIcons.book_open,
  'video': LucideIcons.clapperboard,
  'manga': LucideIcons.image,
  'audio': LucideIcons.headphones,
};

/// Scale-on-press wrapper that gives every tappable card a physical,
/// spring-like response.
class PressableCard extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const PressableCard({super.key, required this.onTap, required this.child});

  @override
  State<PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<PressableCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (value != _pressed && mounted) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.965 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// Lazy entrance used by grid cells: fade plus a short rise, staggered by
/// position so the feed cascades in as it scrolls into view.
class StaggeredEntrance extends StatelessWidget {
  final int index;
  final Widget child;

  const StaggeredEntrance({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + (index % 8) * 60),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 22 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Large editorial showcase for the first item of the feed.
class FeaturedMediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  const FeaturedMediaCard({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final width = MediaQuery.sizeOf(context).width - 40;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: PressableCard(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 240,
            child: Stack(
              fit: StackFit.expand,
              children: [
                item.cover.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: item.cover,
                        fit: BoxFit.cover,
                        memCacheWidth: (width * pixelRatio).round(),
                        placeholder: (context, url) =>
                            ColoredBox(color: scheme.surfaceContainerHighest),
                        errorWidget: (context, url, error) =>
                            _CoverFallback(scheme: scheme, kind: item.kind),
                      )
                    : _CoverFallback(scheme: scheme, kind: item.kind),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color(0x14000000),
                        Color(0xD9000000),
                      ],
                      stops: [0.35, 0.62, 1],
                    ),
                  ),
                ),
                Positioned(
                  top: 14,
                  left: 14,
                  child: _KindChip(kind: item.kind, bright: true),
                ),
                if (item.ep.isNotEmpty)
                  Positioned(top: 14, right: 14, child: _EpPill(ep: item.ep)),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (item.author.isNotEmpty)
                            Flexible(
                              child: Text(
                                item.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.75),
                                ),
                              ),
                            ),
                          const Spacer(),
                          Text(
                            '开始探索',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              LucideIcons.arrow_up_right,
                              size: 16,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Grid cell for the home feed: 5:7 cover, floating kind chip, two-line
/// title and a single meta line. Sizing matches [mediaGridDelegateFor].
class HomeMediaCard extends StatelessWidget {
  final MediaItem item;
  final int index;
  final VoidCallback onTap;

  const HomeMediaCard({
    super.key,
    required this.item,
    required this.index,
    required this.onTap,
  });

  static const _coverAspectRatio = 5 / 7;
  static const _titleHeight = 32.0;
  static const _authorHeight = 14.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    final scaledTitleHeight = scaler.scale(13) * 1.2 * 2 + 1;
    final scaledAuthorHeight = scaler.scale(11) * 1.2 + 1;
    final titleHeight = scaledTitleHeight > _titleHeight
        ? scaledTitleHeight
        : _titleHeight;
    final authorHeight = scaledAuthorHeight > _authorHeight
        ? scaledAuthorHeight
        : _authorHeight;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (140 * pixelRatio).round();
    final cacheHeight = (196 * pixelRatio).round();
    return PressableCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: _coverAspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: item.cover.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: item.cover,
                          fit: BoxFit.cover,
                          memCacheWidth: cacheWidth,
                          memCacheHeight: cacheHeight,
                          placeholder: (context, url) =>
                              ColoredBox(color: scheme.surfaceContainerHighest),
                          errorWidget: (context, url, error) =>
                              _CoverFallback(scheme: scheme, kind: item.kind),
                        )
                      : _CoverFallback(scheme: scheme, kind: item.kind),
                ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: _KindChip(kind: item.kind, bright: true, small: true),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: titleHeight,
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 3),
          SizedBox(
            height: authorHeight,
            child: Text(
              item.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  final ColorScheme scheme;
  final String kind;

  const _CoverFallback({required this.scheme, required this.kind});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: scheme.surfaceContainerHighest,
      child: Icon(
        kindIcons[kind] ?? LucideIcons.book_open,
        size: 40,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Frosted pill showing the media kind, readable over any cover art.
class _KindChip extends StatelessWidget {
  final String kind;
  final bool bright;
  final bool small;

  const _KindChip({required this.kind, this.bright = false, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 7 : 9,
        vertical: small ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            kindIcons[kind] ?? LucideIcons.book_open,
            size: small ? 10 : 12,
            color: Colors.white,
          ),
          SizedBox(width: small ? 4 : 5),
          Text(
            kindLabels[kind] ?? kind,
            style: TextStyle(
              fontSize: small ? 9 : 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _EpPill extends StatelessWidget {
  final String ep;

  const _EpPill({required this.ep});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.play, size: 10, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            ep,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
