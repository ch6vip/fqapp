import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shares only the unfiltered page input of a pair of separated scroll edges.
/// Masks and Gaussian outputs remain separate. This is deliberately not a
/// LiquidGlassBatch: controls must sample the already-frosted page, and equal
/// filter-result coalescing would apply dstIn to the destination page itself.
class LiquidGlassScrollEdgeGroup extends StatefulWidget {
  const LiquidGlassScrollEdgeGroup(
      {super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EdgeScope>() != null;
  @override
  State<LiquidGlassScrollEdgeGroup> createState() => _EdgeGroupState();
}

class _EdgeGroupState extends State<LiquidGlassScrollEdgeGroup> {
  final _group = _EdgeInput();
  @override
  Widget build(BuildContext context) =>
      _EdgeScope(group: widget.enabled ? _group : null, child: widget.child);
  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }
}

class _EdgeScope extends InheritedWidget {
  const _EdgeScope({required this.group, required super.child});
  final _EdgeInput? group;
  @override
  bool updateShouldNotify(_EdgeScope oldWidget) => group != oldWidget.group;
}

/// Internal blur host; the public scroll-edge widget still owns its optics.
class LiquidGlassEdgeBackdrop extends SingleChildRenderObjectWidget {
  const LiquidGlassEdgeBackdrop(
      {super.key,
      required this.filter,
      required this.sigma,
      required this.bottom,
      required super.child});
  final ui.ImageFilter filter;
  final double sigma;
  final bool bottom;
  _EdgeInput? _group(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EdgeScope>()?.group;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _EdgeRender(filter, sigma, bottom, _group(context));
  @override
  void updateRenderObject(
          BuildContext context, covariant RenderObject renderObject) =>
      (renderObject as _EdgeRender)
          .update(filter, sigma, bottom, _group(context));
}

class _EdgeRender extends RenderProxyBox {
  _EdgeRender(this.filter, this.sigma, this.bottom, this.group);
  ui.ImageFilter filter;
  double sigma;
  bool bottom;
  _EdgeInput? group;
  final _effect = LayerHandle<_EdgeLayer>();
  bool get debugSharesEdgeInput => _effect.layer?.backdropKey != null;
  Object? get debugEdgeInputKey => _effect.layer?.backdropKey;
  @override
  bool get alwaysNeedsCompositing => true;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    group?.members.add(this);
    group?.invalidate();
  }

  @override
  void detach() {
    group?.members.remove(this);
    group?.invalidate();
    super.detach();
  }

  void update(
      ui.ImageFilter value, double radius, bool fromBottom, _EdgeInput? next) {
    var changed = false;
    if (group != next) {
      if (attached) {
        group?.members.remove(this);
        next?.members.add(this);
      }
      group?.invalidate();
      next?.invalidate();
      group = next;
      changed = true;
    }
    if (filter != value || sigma != radius || bottom != fromBottom) {
      filter = value;
      sigma = radius;
      bottom = fromBottom;
      group?.invalidate();
      changed = true;
    }
    if (changed) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    context.pushLayer(_effect.layer ??= _EdgeLayer(this), super.paint, offset);
  }

  @override
  void dispose() {
    group?.members.remove(this);
    group?.invalidate();
    _effect.layer = null;
    super.dispose();
  }
}

class _EdgeInput {
  final members = <_EdgeRender>{};
  final key = BackdropKey();
  ui.SceneBuilder? _scene;
  Set<_EdgeRender> _pair = {};
  void invalidate() => _scene = null;
  BackdropKey? keyFor(_EdgeRender render, ui.SceneBuilder scene) {
    if (!identical(_scene, scene)) {
      _scene = scene;
      _pair = {};
      final visible = <_EdgeRender, Rect>{};
      for (final member in members) {
        if (!member.attached || !member.hasSize || member.size.isEmpty) {
          continue;
        }
        var hidden = false;
        for (RenderObject? node = member.parent;
            node != null;
            node = node.parent) {
          if (node is RenderOffstage && node.offstage ||
              node is RenderOpacity && node.opacity != 1 ||
              node is RenderAnimatedOpacity && node.opacity.value != 1) {
            hidden = true;
            break;
          }
        }
        if (hidden) continue;
        final transform = member.getTransformTo(null);
        if (transform.storage[1].abs() > .000001 ||
            transform.storage[4].abs() > .000001 ||
            transform.storage[3].abs() > .000001 ||
            transform.storage[7].abs() > .000001) {
          continue;
        }
        final rect =
            MatrixUtils.transformRect(transform, Offset.zero & member.size);
        // Separation includes the Gaussian input halo, not just visible bands.
        final halo = 3 * member.sigma * transform.getMaxScaleOnAxis() + 1;
        visible[member] = rect.inflate(halo);
      }
      // A nested page owns a fresh group. Ambiguous additional edges, a compact
      // overlapping viewport or a fading route use the original isolated path.
      if (visible.length == 2) {
        final a = visible.keys.first, b = visible.keys.last;
        if (a.bottom != b.bottom &&
            a.filter != b.filter &&
            !visible[a]!.overlaps(visible[b]!)) {
          _pair = {a, b};
        }
      }
    }
    return _pair.contains(render) ? key : null;
  }

  void dispose() {
    members.clear();
    _pair.clear();
    _scene = null;
  }
}

class _EdgeLayer extends BackdropFilterLayer {
  _EdgeLayer(this.render) : super(filter: render.filter);
  final _EdgeRender render;
  @override
  bool get alwaysNeedsAddToScene => true;
  @override
  void markNeedsAddToScene() {
    // Filter/key are resolved every scene, including retained transforms.
  }
  @override
  void addToScene(ui.SceneBuilder builder) {
    filter = render.filter;
    backdropKey = render.group?.keyFor(render, builder);
    super.addToScene(builder);
  }
}
