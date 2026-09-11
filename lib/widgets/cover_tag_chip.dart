import 'package:flutter/material.dart';

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

/// `#RRGGBB` to an opaque colour; null when the string is not that shape.
Color? hexColor(String hex) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
}
