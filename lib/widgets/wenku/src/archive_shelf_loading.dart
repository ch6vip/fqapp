// Ported from Wenku8_Flutter lib/archive_shelf_loading.dart (revision ebcd7f1).
// Verbatim copy; no substitutions.

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A travelling lift of actual book solids. The frame timestamp is shared by
/// the waiting bank and arriving files, so handing off never resets the wave.
double archiveLoadingLift(double lane, Duration frame, double remaining) {
  final phase = frame.inMicroseconds / 1700000 - lane * .075;
  final crest = (1 + math.sin(phase * math.pi * 2)) / 2;
  return -9 * crest * crest * remaining;
}

/// Ink arrives on each retained solid, not as a second animated shelf plane.
/// Only paint follows the clock; faces and their hit-test geometry stay put.
class ArchiveShelfInk extends SingleChildRenderObjectWidget {
  const ArchiveShelfInk({
    super.key,
    required this.animation,
    required this.start,
    required this.end,
    required this.base,
    required this.ink,
    required super.child,
    this.spine = false,
  });
  final Animation<double> animation;
  final double start, end;
  final Color base, ink;
  final bool spine;

  @override
  ArchiveShelfInkRender createRenderObject(BuildContext context) =>
      ArchiveShelfInkRender(this);

  @override
  void updateRenderObject(
    BuildContext context,
    ArchiveShelfInkRender renderObject,
  ) => renderObject.update(this);
}

class ArchiveShelfInkRender extends RenderProxyBox {
  ArchiveShelfInkRender(this.config);
  ArchiveShelfInk config;
  final _alpha = LayerHandle<OpacityLayer>();
  double get progress => Interval(
    config.start,
    config.end,
    curve: Curves.easeOutCubic,
  ).transform(config.animation.value.clamp(0.0, 1.0));

  void _tick() => markNeedsPaint();

  void update(ArchiveShelfInk next) {
    if (attached && config.animation != next.animation) {
      config.animation.removeListener(_tick);
      next.animation.addListener(_tick);
    }
    config = next;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    config.animation.addListener(_tick);
  }

  @override
  void detach() {
    config.animation.removeListener(_tick);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    final t = progress;
    if (t < 1) {
      final canvas = context.canvas;
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      canvas.drawRect(Offset.zero & size, Paint()..color = config.base);
      final bone = Paint()
        ..color = config.ink.withValues(alpha: .075 * (1 - t));
      if (config.spine) {
        canvas.drawRect(Rect.fromLTWH(4, 13, size.width - 8, 5), bone);
        canvas.drawRect(
          Rect.fromLTWH(
            5,
            size.height * .32,
            size.width - 10,
            size.height * .34,
          ),
          bone,
        );
      } else {
        canvas.drawRect(
          Rect.fromLTWH(10, 10, size.width - 20, size.height - 54),
          bone,
        );
        canvas.drawRect(
          Rect.fromLTWH(10, size.height - 31, (size.width - 20) * .7, 5),
          bone,
        );
        canvas.drawRect(
          Rect.fromLTWH(10, size.height - 18, (size.width - 20) * .45, 4),
          bone,
        );
      }
      canvas.restore();
    }
    if (child == null || t <= 0) return;
    if (t >= 1) {
      super.paint(context, offset);
    } else {
      _alpha.layer = context.pushOpacity(
        offset,
        (255 * t).round(),
        super.paint,
        oldLayer: _alpha.layer,
      );
    }
  }

  @override
  void dispose() {
    _alpha.layer = null;
    super.dispose();
  }
}
