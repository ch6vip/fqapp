import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A route/batch lends its finite clock to foreground labels and rules. Parts
/// never start their own ticker, and newly scrolled-in content stays static.
class ArchiveMotionScope extends InheritedWidget {
  const ArchiveMotionScope({
    super.key,
    required this.animation,
    required super.child,
    this.enabled = true,
  });

  final Animation<double> animation;
  final bool enabled;

  static ArchiveMotionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArchiveMotionScope>();

  @override
  bool updateShouldNotify(ArchiveMotionScope oldWidget) =>
      animation != oldWidget.animation || enabled != oldWidget.enabled;
}

enum ArchiveRevealAxis { horizontal, vertical }

/// Crisp terminal assembly: the rule opens first, followed by its address and
/// heading. The material behind it is not faded, filtered or re-laid out.
class ArchivePart extends StatelessWidget {
  const ArchivePart({
    super.key,
    required this.child,
    this.start = .08,
    this.end = .72,
    this.axis = ArchiveRevealAxis.horizontal,
    this.travel = Offset.zero,
  });

  final Widget child;
  final double start;
  final double end;
  final ArchiveRevealAxis axis;
  final Offset travel;

  @override
  Widget build(BuildContext context) {
    final scope = ArchiveMotionScope.maybeOf(context);
    if (scope == null ||
        !scope.enabled ||
        scope.animation.value == 1 ||
        MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return ArchiveReveal(
      animation: scope.animation,
      start: start,
      end: end,
      axis: axis,
      travel: travel,
      child: child,
    );
  }
}

/// A paint-only rectangular reveal. The static child owns one retained layer;
/// an entire loaded batch shares a clock rather than rebuilding every row.
class ArchiveReveal extends SingleChildRenderObjectWidget {
  ArchiveReveal({
    super.key,
    required this.animation,
    required Widget child,
    this.start = 0,
    this.end = 1,
    this.axis = ArchiveRevealAxis.vertical,
    this.travel = const Offset(-8, -6),
  }) : assert(start >= 0 && start < end && end <= 1),
       super(child: RepaintBoundary(child: child));

  final Animation<double> animation;
  final double start;
  final double end;
  final ArchiveRevealAxis axis;
  final Offset travel;

  @override
  ArchiveRevealRender createRenderObject(BuildContext context) =>
      ArchiveRevealRender(animation, start, end, axis, travel);

  @override
  void updateRenderObject(
    BuildContext context,
    ArchiveRevealRender renderObject,
  ) => renderObject.update(animation, start, end, axis, travel);
}

abstract class _ArchiveAnimatedRender extends RenderProxyBox {
  _ArchiveAnimatedRender(this._animation);

  Animation<double> _animation;
  Animation<double> get animation => _animation;
  int debugLayoutCount = 0;
  int debugPaintCount = 0;

  void tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  void updateAnimation(Animation<double> value) {
    if (_animation == value) return;
    if (attached) _animation.removeListener(tick);
    _animation = value;
    if (attached) _animation.addListener(tick);
  }

  void recordPaint() {
    assert(() {
      debugPaintCount++;
      return true;
    }());
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(tick);
  }

  @override
  void detach() {
    _animation.removeListener(tick);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    assert(() {
      debugLayoutCount++;
      return true;
    }());
  }
}

class ArchiveRevealRender extends _ArchiveAnimatedRender {
  ArchiveRevealRender(
    super.animation,
    this._start,
    this._end,
    this._axis,
    this._travel,
  );

  double _start;
  double _end;
  ArchiveRevealAxis _axis;
  Offset _travel;
  final _clipLayer = LayerHandle<ClipRectLayer>();
  final _transformLayer = LayerHandle<TransformLayer>();
  double? _observedProgress;

  @override
  void tick() {
    final next = progress;
    final previous = _observedProgress;
    if (previous == next) return;
    _observedProgress = next;
    markNeedsPaint();
    // A batch clock continues after its early rows have landed. Those rows
    // need neither another paint nor a fresh accessibility tree every frame.
    // Keep listening: reversing the shared clock must reveal the same path.
    if (previous == null || (previous >= .05) != (next >= .05)) {
      markNeedsSemanticsUpdate();
    }
  }

  double get progress => Interval(
    _start,
    _end,
    curve: Curves.easeOutCubic,
  ).transform(animation.value.clamp(0.0, 1.0));

  Offset get displacement => _travel * (1 - progress);

  Rect get viewport => Rect.fromLTWH(
    0,
    0,
    size.width * (_axis == ArchiveRevealAxis.horizontal ? progress : 1),
    size.height * (_axis == ArchiveRevealAxis.vertical ? progress : 1),
  );

  Matrix4 get _transform =>
      Matrix4.translationValues(displacement.dx, displacement.dy, 0);

  void update(
    Animation<double> value,
    double start,
    double end,
    ArchiveRevealAxis axis,
    Offset travel,
  ) {
    updateAnimation(value);
    _start = start;
    _end = end;
    _axis = axis;
    _travel = travel;
    _observedProgress = progress;
    super.tick();
  }

  @override
  Rect get paintBounds => (Offset.zero & size).inflate(_travel.distance);

  @override
  void paint(PaintingContext context, Offset offset) {
    recordPaint();
    if (child == null || size.isEmpty || progress == 0) return;
    if (progress == 1) {
      _clipLayer.layer = null;
      _transformLayer.layer = null;
      super.paint(context, offset);
      return;
    }
    _transformLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) {
        _clipLayer.layer = context.pushClipRect(
          needsCompositing,
          offset,
          viewport,
          super.paint,
          clipBehavior: Clip.hardEdge,
          oldLayer: _clipLayer.layer,
        );
      },
      oldLayer: _transformLayer.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (progress < .05 || !viewport.shift(displacement).contains(position)) {
      return false;
    }
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => super.hitTest(result, position: position),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (progress >= .05) super.visitChildrenForSemantics(visitor);
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    _transformLayer.layer = null;
    super.dispose();
  }
}

enum ArchivePlaneKind { incoming, outgoing, sheet }

/// Archive sheets exchange on a shallow diagonal. Unlike a page-wide fade,
/// opaque text stays crisp and the previous sheet remains under the reveal.
/// No perspective/scale is applied to live glass or its hit-test coordinates.
class ArchivePlaneTransition extends SingleChildRenderObjectWidget {
  const ArchivePlaneTransition({
    super.key,
    required this.animation,
    required super.child,
    this.kind = ArchivePlaneKind.incoming,
    this.direction = 1,
    this.bottomClearance = 24,
  });

  final Animation<double> animation;
  final ArchivePlaneKind kind;
  final double direction;
  final double bottomClearance;

  @override
  ArchivePlaneRender createRenderObject(BuildContext context) =>
      ArchivePlaneRender(animation, kind, direction, bottomClearance);

  @override
  void updateRenderObject(
    BuildContext context,
    ArchivePlaneRender renderObject,
  ) => renderObject.update(animation, kind, direction, bottomClearance);
}

class ArchivePlaneRender extends _ArchiveAnimatedRender {
  ArchivePlaneRender(
    super.animation,
    this._kind,
    this._direction,
    this._bottomClearance,
  );

  ArchivePlaneKind _kind;
  double _direction;
  double _bottomClearance;
  final _clipLayer = LayerHandle<ClipPathLayer>();
  final _transformLayer = LayerHandle<TransformLayer>();

  // The same path is used when reversed midway: no status-dependent jump.
  double get progress =>
      const Cubic(.18, .72, .18, 1).transform(animation.value.clamp(0.0, 1.0));

  Offset get displacement => switch (_kind) {
    ArchivePlaneKind.incoming => Offset(
      -24 * _direction * (1 - progress),
      12 * (1 - progress),
    ),
    ArchivePlaneKind.outgoing => Offset(
      10 * _direction * progress,
      -4 * progress,
    ),
    ArchivePlaneKind.sheet => Offset(
      -18 * (1 - progress),
      (size.height + _bottomClearance) * (1 - progress),
    ),
  };

  Path get viewport {
    final slant = math.min(180.0, size.width * .46);
    final edge = (size.width + slant) * progress;
    double x(double value) => _direction >= 0 ? value : size.width - value;
    return Path()
      ..moveTo(x(0), 0)
      ..lineTo(x(edge), 0)
      ..lineTo(x(edge - slant), size.height)
      ..lineTo(x(0), size.height)
      ..close();
  }

  Matrix4 get _transform =>
      Matrix4.translationValues(displacement.dx, displacement.dy, 0);

  void update(
    Animation<double> value,
    ArchivePlaneKind kind,
    double direction,
    double bottomClearance,
  ) {
    updateAnimation(value);
    _kind = kind;
    _direction = direction;
    _bottomClearance = bottomClearance;
    tick();
  }

  @override
  Rect get paintBounds => (Offset.zero & size).expandToInclude(
    (Offset.zero & size).shift(displacement),
  );

  void _paintPlane(PaintingContext context, Offset offset) {
    _transformLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      super.paint,
      oldLayer: _transformLayer.layer,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    recordPaint();
    if (child == null || size.isEmpty) return;
    if (_kind != ArchivePlaneKind.outgoing && progress == 0) return;
    if (_kind != ArchivePlaneKind.outgoing && progress == 1) {
      _clipLayer.layer = null;
      _transformLayer.layer = null;
      super.paint(context, offset);
    } else if (_kind == ArchivePlaneKind.incoming) {
      _clipLayer.layer = context.pushClipPath(
        needsCompositing,
        offset,
        Offset.zero & size,
        viewport,
        _paintPlane,
        clipBehavior: Clip.hardEdge,
        oldLayer: _clipLayer.layer,
      );
    } else {
      _clipLayer.layer = null;
      _paintPlane(context, offset);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_kind == ArchivePlaneKind.incoming &&
        (progress < .05 || (progress < 1 && !viewport.contains(position)))) {
      return false;
    }
    if (_kind == ArchivePlaneKind.sheet && progress < .05) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => super.hitTest(result, position: position),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (progress >= .05 || _kind == ArchivePlaneKind.outgoing) {
      super.visitChildrenForSemantics(visitor);
    }
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    _transformLayer.layer = null;
    super.dispose();
  }
}
