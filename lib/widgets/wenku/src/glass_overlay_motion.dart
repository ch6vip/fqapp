// Ported from Wenku8_Flutter (revision ebcd7f1), `lib/motion_ui.dart`
// (`GlassOverlayKind`, `GlassMenuStretch`, `GlassMenuContents`,
// `GlassOverlayTransition`).
//
// Mechanical substitutions:
// - `NovelMotion` -> `WenkuMotion`.
// - The upstream file's surrounding mesh/plane helpers are omitted; every
//   render object below is copied verbatim.
//
// fqapp additions: none. The desktop keyboard affordances live on
// `GlassMenuItem` in `../wenku_overlay.dart`.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../wenku_theme.dart';
import 'archive_motion.dart';

enum GlassOverlayKind { menu, sheet }

/// One live glass plane grows out of the original control. Layout and widget
/// construction stay at the final size; only the retained paint transform
/// moves.
class GlassMenuStretch extends SingleChildRenderObjectWidget {
  const GlassMenuStretch({
    super.key,
    required this.animation,
    required this.anchor,
    required super.child,
    this.coordinateSpace,
  });

  final Animation<double> animation;
  final Rect anchor;
  final RenderBox? coordinateSpace;

  @override
  GlassMenuStretchRender createRenderObject(BuildContext context) =>
      GlassMenuStretchRender(animation, anchor, coordinateSpace);

  @override
  void updateRenderObject(
    BuildContext context,
    GlassMenuStretchRender renderObject,
  ) => renderObject.update(animation, anchor, coordinateSpace);
}

class GlassMenuStretchRender extends RenderProxyBox {
  GlassMenuStretchRender(this._animation, this._anchor, this._coordinateSpace);

  Animation<double> _animation;
  Rect _anchor;
  RenderBox? _coordinateSpace;
  final _transformLayer = LayerHandle<TransformLayer>();
  int debugLayoutCount = 0;
  int debugPaintCount = 0;

  double get progress => Curves.easeOutCubic.transform(_animation.value);

  Rect get anchor => _anchor;

  Rect get targetRect => MatrixUtils.transformRect(
    getTransformTo(_coordinateSpace),
    Offset.zero & size,
  );

  Rect get localCurrentRect {
    final inverse = Matrix4.tryInvert(getTransformTo(_coordinateSpace));
    return inverse == null
        ? Offset.zero & size
        : MatrixUtils.transformRect(inverse, currentRect);
  }

  Offset sourceOffset(Size sourceSize) {
    final inverse = Matrix4.tryInvert(getTransformTo(_coordinateSpace));
    final center = inverse == null
        ? _anchor.center
        : MatrixUtils.transformPoint(inverse, _anchor.center);
    return center -
        localCurrentRect.topLeft -
        Offset(sourceSize.width / 2, sourceSize.height / 2);
  }

  Rect get currentRect {
    final target = targetRect;
    final rect = Rect.lerp(_anchor, target, progress)!;
    // The bubble opens promptly, width first, with one small elastic settle.
    // This clock is direction-independent, so reversing a partly open menu
    // follows the same continuous path rather than jumping to another curve.
    final widthProgress = const Cubic(
      .18,
      1.10,
      .30,
      1,
    ).transform(_animation.value);
    final heightProgress = const Cubic(
      .22,
      1.04,
      .32,
      1,
    ).transform(_animation.value);
    final width = ui.lerpDouble(_anchor.width, target.width, widthProgress)!;
    final height = ui.lerpDouble(
      _anchor.height,
      target.height,
      heightProgress,
    )!;
    final growsDown = target.center.dy >= _anchor.center.dy;
    return Rect.fromLTWH(
      rect.right - width,
      growsDown ? rect.top : rect.bottom - height,
      width,
      height,
    );
  }

  Matrix4 get _paintTransform {
    // Convert back before painting: deltas in view/Overlay coordinates are
    // not local deltas when a Navigator is translated or scaled.
    final current = localCurrentRect;
    return Matrix4.identity()
      ..translateByDouble(current.left, current.top, 0, 1)
      ..scaleByDouble(
        current.width / size.width,
        current.height / size.height,
        1,
        1,
      );
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  void update(
    Animation<double> animation,
    Rect anchor,
    RenderBox? coordinateSpace,
  ) {
    if (_animation != animation) {
      if (attached) _animation.removeListener(_tick);
      _animation = animation;
      if (attached) _animation.addListener(_tick);
    }
    _anchor = anchor;
    _coordinateSpace = coordinateSpace;
    _tick();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(_tick);
  }

  @override
  void detach() {
    _animation.removeListener(_tick);
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

  @override
  Rect get paintBounds => (Offset.zero & size).inflate(24);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty || child == null) return;
    assert(() {
      debugPaintCount++;
      return true;
    }());
    _transformLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _paintTransform,
      super.paint,
      oldLayer: _transformLayer.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_paintTransform);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.isEmpty || progress < .15) return false;
    return result.addWithPaintTransform(
      transform: _paintTransform,
      position: position,
      hitTest: (result, position) => super.hitTest(result, position: position),
    );
  }

  @override
  void dispose() {
    _transformLayer.layer = null;
    super.dispose();
  }
}

/// The glass changes shape, but its contents are not squeezed into that shape.
/// Retained foreground layers move with the bubble and are revealed
/// by its rounded viewport. A source glyph occupies the initial button frame.
class GlassMenuContents extends MultiChildRenderObjectWidget {
  GlassMenuContents({
    super.key,
    required this.animation,
    required this.sourceSize,
    required this.sourceRadius,
    required Widget child,
    Widget source = const SizedBox.shrink(),
    this.radius = 28,
  }) : super(
         children: [
           RepaintBoundary(child: child),
           ExcludeSemantics(child: RepaintBoundary(child: source)),
         ],
       );

  final Animation<double> animation;
  final Size sourceSize;
  final double sourceRadius;
  final double radius;

  @override
  GlassMenuContentsRender createRenderObject(BuildContext context) =>
      GlassMenuContentsRender(animation, sourceSize, sourceRadius, radius);

  @override
  void updateRenderObject(
    BuildContext context,
    GlassMenuContentsRender renderObject,
  ) => renderObject.update(animation, sourceSize, sourceRadius, radius);
}

class _GlassMenuParentData extends ContainerBoxParentData<RenderBox> {}

class GlassMenuContentsRender extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GlassMenuParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GlassMenuParentData> {
  GlassMenuContentsRender(
    this._animation,
    this._sourceSize,
    this._sourceRadius,
    this._radius,
  );

  Animation<double> _animation;
  Size _sourceSize;
  double _sourceRadius;
  double _radius;
  GlassMenuStretchRender? _stretch;
  final _viewportLayer = LayerHandle<TransformLayer>();
  final _clipLayer = LayerHandle<ClipRRectLayer>();
  final _menuLayer = LayerHandle<TransformLayer>();
  final _sourceLayer = LayerHandle<TransformLayer>();
  final _menuOpacity = LayerHandle<OpacityLayer>();
  final _sourceOpacity = LayerHandle<OpacityLayer>();
  int debugLayoutCount = 0;

  double get _phase => _animation.value.clamp(0.0, 1.0);
  Size get _viewport => _stretch?.localCurrentRect.size ?? size;
  Offset get _menuOffset => Offset(
    // Keep leading labels inside the growing material. Centring a full-width
    // menu here would clip the first characters of every row until it settles.
    0,
    (_viewport.height - size.height) / 2,
  );
  Offset get _sourceOffset =>
      _stretch?.sourceOffset(_sourceSize) ?? Offset.zero;

  double get debugMenuOpacity =>
      const Interval(.06, .34, curve: Curves.easeOut).transform(_phase);
  double get debugSourceOpacity =>
      1 - const Interval(0, .22, curve: Curves.easeInOut).transform(_phase);

  Matrix4 get _unscale => Matrix4.diagonal3Values(
    size.width / _viewport.width,
    size.height / _viewport.height,
    1,
  );

  Matrix4 _foregroundTransform(Offset offset) =>
      _unscale..translateByDouble(offset.dx, offset.dy, 0, 1);

  RRect get _viewportClip => RRect.fromRectAndRadius(
    Offset.zero & _viewport,
    Radius.circular(
      math.min(
        _viewport.shortestSide / 2,
        ui.lerpDouble(
          _sourceRadius,
          _radius,
          Curves.easeOutCubic.transform(_phase),
        )!,
      ),
    ),
  );

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  void update(
    Animation<double> animation,
    Size sourceSize,
    double sourceRadius,
    double radius,
  ) {
    if (_animation != animation) {
      if (attached) _animation.removeListener(_tick);
      _animation = animation;
      if (attached) _animation.addListener(_tick);
    }
    if (_sourceSize != sourceSize) {
      _sourceSize = sourceSize;
      markNeedsLayout();
    }
    _sourceRadius = sourceRadius;
    _radius = radius;
    _tick();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GlassMenuParentData) {
      child.parentData = _GlassMenuParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    while (ancestor != null && ancestor is! GlassMenuStretchRender) {
      ancestor = ancestor.parent;
    }
    _stretch = ancestor as GlassMenuStretchRender?;
    _animation.addListener(_tick);
  }

  @override
  void detach() {
    _animation.removeListener(_tick);
    _stretch = null;
    super.detach();
  }

  @override
  void performLayout() {
    firstChild!.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(firstChild!.size);
    lastChild!.layout(BoxConstraints.tight(_sourceSize));
    assert(() {
      debugLayoutCount++;
      return true;
    }());
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(firstChild!.getDryLayout(constraints));

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty || _viewport.isEmpty) return;
    _viewportLayer.layer = context.pushTransform(true, offset, _unscale, (
      context,
      offset,
    ) {
      _clipLayer.layer = context.pushClipRRect(
        true,
        offset,
        Offset.zero & _viewport,
        _viewportClip,
        (context, offset) {
          void foreground(
            RenderBox child,
            double opacity,
            Offset translation,
            LayerHandle<OpacityLayer> opacityLayer,
            LayerHandle<TransformLayer> transformLayer,
          ) {
            final alpha = (opacity * 255).round();
            if (alpha == 0) return;
            opacityLayer.layer = context.pushOpacity(offset, alpha, (
              context,
              offset,
            ) {
              transformLayer.layer = context.pushTransform(
                true,
                offset,
                Matrix4.translationValues(translation.dx, translation.dy, 0),
                (context, offset) => context.paintChild(child, offset),
                oldLayer: transformLayer.layer,
              );
            }, oldLayer: opacityLayer.layer);
          }

          foreground(
            firstChild!,
            debugMenuOpacity,
            _menuOffset,
            _menuOpacity,
            _menuLayer,
          );
          foreground(
            lastChild!,
            debugSourceOpacity,
            _sourceOffset,
            _sourceOpacity,
            _sourceLayer,
          );
        },
        oldLayer: _clipLayer.layer,
      );
    }, oldLayer: _viewportLayer.layer);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(
        _foregroundTransform(child == firstChild ? _menuOffset : _sourceOffset),
      );

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.isEmpty || _phase < .34) return false;
    final visiblePosition = Offset(
      position.dx * _viewport.width / size.width,
      position.dy * _viewport.height / size.height,
    );
    if (!_viewportClip.contains(visiblePosition)) return false;
    return result.addWithPaintTransform(
      transform: _foregroundTransform(_menuOffset),
      position: position,
      hitTest: (result, position) =>
          firstChild!.hitTest(result, position: position),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_phase >= .34) visitor(firstChild!);
  }

  @override
  void dispose() {
    _viewportLayer.layer = null;
    _clipLayer.layer = null;
    _menuLayer.layer = null;
    _sourceLayer.layer = null;
    _menuOpacity.layer = null;
    _sourceOpacity.layer = null;
    super.dispose();
  }
}

/// Menus morph their live material; sheets retain their existing entrance.
class GlassOverlayTransition extends StatelessWidget {
  const GlassOverlayTransition({
    super.key,
    required this.animation,
    required this.kind,
    required this.child,
    this.reduceMotion = false,
    this.anchor,
    this.coordinateSpace,
  });
  final Animation<double> animation;
  final GlassOverlayKind kind;
  final Widget child;
  final bool reduceMotion;
  final Rect? anchor;
  final RenderBox? coordinateSpace;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion || MediaQuery.disableAnimationsOf(context)) return child;
    if (kind == GlassOverlayKind.menu) {
      assert(anchor != null);
      return GlassMenuStretch(
        key: const ValueKey('glass-menu-transition'),
        animation: animation,
        anchor: anchor!,
        coordinateSpace: coordinateSpace,
        // Retain the labels/selection paint, not a bitmap of the backdrop.
        // The live lens still resolves the scene on every frame.
        child: RepaintBoundary(child: child),
      );
    }
    if (anchor != null) {
      return SizeTransition(
        sizeFactor: animation.drive(CurveTween(curve: WenkuMotion.ease)),
        // Upstream `axisAlignment: 1` on a vertical transition maps to
        // `AlignmentDirectional(-1, 1)` (bottom-left), not centred.
        alignment: const AlignmentDirectional(-1, 1),
        child: RepaintBoundary(child: child),
      );
    }
    return ArchivePlaneTransition(
      key: ValueKey('glass-${kind.name}-transition'),
      animation: animation,
      kind: ArchivePlaneKind.sheet,
      bottomClearance: MediaQuery.viewPaddingOf(context).bottom + 24,
      // Move the retained sheet display list. Its lens still samples the
      // current scene; only unchanged foreground paint is retained.
      child: RepaintBoundary(child: child),
    );
  }
}
