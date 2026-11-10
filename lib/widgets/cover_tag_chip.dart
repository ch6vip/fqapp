import 'package:flutter/material.dart';

import 'wenku/src/app_text.dart';

/// Small chip overlaid on a cover.
///
/// Used for the card's kind label and for the optional corner tag the upstream
/// attaches to some cards (`上新`, `爆款`). Without [colors] it paints the
/// neutral dark scrim the kind label has always used; with them it paints the
/// upstream gradient, because the colours differ per label.
class CoverTagChip extends StatelessWidget {
  final String label;
  final List<String> colors;

  const CoverTagChip({super.key, required this.label, this.colors = const []});

  @override
  Widget build(BuildContext context) {
    final stops = <Color>[
      for (final hex in colors)
        if (hexColor(hex) case final Color color) color,
    ];
    final BoxDecoration decoration;
    if (stops.isEmpty) {
      decoration = BoxDecoration(
        color: const Color(0xFF1C1B1A).withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(5),
      );
    } else {
      decoration = BoxDecoration(
        // A single stop is repeated so it still reads as a solid fill.
        gradient: LinearGradient(
          colors: stops.length == 1 ? [stops.first, stops.first] : stops,
        ),
        borderRadius: BorderRadius.circular(5),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: decoration,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 9, height: 1.2),
      ),
    );
  }
}

/// A small cover badge (更新 / 缓存 / source). [inverse] flips it to an ink
/// plate for light artwork.
///
/// This is the one badge both bookshelf themes use. It and the Wenku8
/// `BookSourceBadge` were the same upstream widget ported twice — once per
/// theme — and the two copies had drifted into separate files with identical
/// styling. They now share this implementation.
class ShelfCoverBadge extends StatelessWidget {
  const ShelfCoverBadge({super.key, required this.text, this.inverse = false});
  final String text;
  final bool inverse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: inverse
            ? scheme.onSurface
            : scheme.surface.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: AppText(
          text,
          maxLines: 1,
          style: TextStyle(
            color: inverse ? scheme.surface : scheme.onSurface,
            fontSize: 9,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// `#RRGGBB` to an opaque colour; null when the string is not that shape.
Color? hexColor(String hex) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
}
