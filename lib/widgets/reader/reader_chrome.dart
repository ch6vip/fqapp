// Ported from Wenku8_Flutter@ebcd7f1, lib/reader_chrome.dart.
// ReaderChromeLayer retains paint-only translation/scale (no opacity saveLayer).
// NativeGlassGroup / NativeScrollEdgeGroup are replaced by the already-vendored
// LiquidGlassBatch and EasyScrollEdge. fqapp retains its text viewport geometry.
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import '../wenku/src/easy_glass.dart';
import '../wenku/wenku_ui.dart';

class ReaderChromeLayer extends StatelessWidget {
  const ReaderChromeLayer({
    super.key,
    required this.animation,
    required this.child,
    this.slide = Offset.zero,
    this.paintPadding = EdgeInsets.zero,
    this.curve = Curves.easeOutCubic,
    this.scaleFrom = 1,
    this.clip = true,
    this.maintainSize = false,
    this.interactionThreshold = .95,
  }) : assert(interactionThreshold >= 0 && interactionThreshold <= 1);

  final Animation<double> animation;
  final Widget child;
  final Offset slide;
  final EdgeInsets paintPadding;
  final Curve curve;
  final double scaleFrom;
  final bool clip;
  final bool maintainSize;
  final double interactionThreshold;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final inactive =
          animation.value == 0 || animation.value < interactionThreshold;
      final progress = curve.transform(animation.value.clamp(0.0, 1.0));
      final layer = IgnorePointer(
        ignoring: inactive,
        child: ExcludeSemantics(
          excluding: inactive,
          child: easy.LiquidGlassBatch.inherit(
            enabled: false,
            child: ClipRect(
              clipBehavior: clip ? Clip.hardEdge : Clip.none,
              child: FractionalTranslation(
                translation: slide * (1 - progress),
                child: Transform.scale(
                  scale: scaleFrom + (1 - scaleFrom) * progress,
                  child: Padding(padding: paintPadding, child: child),
                ),
              ),
            ),
          ),
        ),
      );
      if (!maintainSize) {
        return Offstage(offstage: animation.value == 0, child: layer);
      }
      return Visibility(
        visible: animation.value != 0,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: TickerMode(enabled: animation.value != 0, child: layer),
      );
    },
  );
}

/// The reader's paper stays untouched; only the visible controls own live edges.
class ReaderEdgeBlur extends StatelessWidget {
  const ReaderEdgeBlur({
    super.key,
    required this.animation,
    this.headerExtent = 66,
    this.bottomExtent = 140,
  });

  final Animation<double> animation;
  final double headerExtent;
  final double bottomExtent;

  @override
  Widget build(BuildContext context) {
    final effects = PerformanceScope.of(context);
    if (!effects.edgeBlur || MediaQuery.highContrastOf(context)) {
      return const SizedBox.shrink();
    }
    final safe = MediaQuery.viewPaddingOf(context);
    final blur = GlassAppearance.of(context).blur;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final strength = Curves.easeInOut.transform(animation.value);
        if (strength == 0) return const SizedBox.shrink();
        Widget edge({required bool bottom}) {
          final color = Colors.black.withValues(
            alpha:
                (bottom
                    ? DockLayout.edgeShadeOpacity
                    : DockLayout.topEdgeShadeOpacity) *
                strength,
          );
          return EasyScrollEdge(
            blur: blur * strength,
            plateau: bottom ? safe.bottom + 12 : safe.top + headerExtent,
            fromBottom: bottom,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: bottom ? Alignment.bottomCenter : Alignment.topCenter,
                  end: bottom ? Alignment.topCenter : Alignment.bottomCenter,
                  colors: [color, color.withValues(alpha: 0)],
                ),
              ),
            ),
          );
        }

        return IgnorePointer(
          child: easy.LiquidGlassScrollEdgeGroup(
            enabled: animation.value == 1,
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: safe.top + headerExtent + 48,
                  child: edge(bottom: false),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: safe.bottom + bottomExtent,
                  child: edge(bottom: true),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
