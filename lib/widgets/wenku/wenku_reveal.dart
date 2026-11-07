// Ported from Wenku8_Flutter lib/motion_ui.dart (revision ebcd7f1).
//
// Scope: `LoadedContentSequence`, `LoadedContentItem`, `AnimatedOptionSection`
// and `RevealFromTop`. `PaperCover*`, `GlassMenu*` and
// `GlassOverlayTransition` are intentionally not ported.
//
// Mechanical substitutions for dependencies fqapp does not ship:
// - `NovelMotion` -> `WenkuMotion` (wenku_theme.dart). Upstream
//   `NovelMotion.reveal` is an alias of `enter`, which WenkuMotion already
//   carries, so private `_reveal` preserves the exact duration.
// - `loading_ui.dart` -> `wenku_loading.dart` (`LoadingSkeleton`,
//   `SkeletonLayout`).
// - `archive_motion.dart` -> `src/archive_motion.dart` (`ArchiveReveal`,
//   `ArchiveRevealAxis`).
// - `loading_handoff.dart` has no separate fqapp file. `LoadingHandoff` and
//   its private remainder render object are copied below. The class is public
//   so the archive carousel's caption can use the upstream `crossfade` branch;
//   `RevealFromTop` keeps the skeleton-remainder branch.
// - `SizeTransition.axisAlignment` is deprecated in this Flutter SDK;
//   `axisAlignment: -1` (its vertical default) is expressed as
//   `alignment: AlignmentDirectional.topStart`, the same directional value.
// - The upstream `export 'archive_motion.dart'` / `export 'loading_handoff.dart'`
//   lines are not carried over; import `src/archive_motion.dart` directly for
//   the reveal primitives.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/archive_motion.dart';
import 'wenku_loading.dart';
import 'wenku_theme.dart';

/// Upstream `NovelMotion.reveal` is an alias of `enter`; WenkuMotion keeps the
/// latter, so this private constant preserves the exact duration.
const _reveal = WenkuMotion.enter;

/// One short clock per accepted batch, kept outside the loading/loaded branch.
/// Only the changed batch is revealed. Scroll rebuilds, failures and cached
/// route returns neither create a new clock nor replay the sequence.
class LoadedContentSequence extends StatefulWidget {
  const LoadedContentSequence({
    super.key,
    required this.generation,
    required this.child,
    this.firstIndex = 0,
  });
  final Object? generation;
  final int firstIndex;
  final Widget child;

  @override
  State<LoadedContentSequence> createState() => _LoadedContentSequenceState();
}

class _LoadedContentSequenceState extends State<LoadedContentSequence>
    with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(
    vsync: this,
    duration: _reveal,
    value: 1,
  )..addStatusListener(_completed);

  void _completed(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() {});
  }

  bool get _static =>
      MediaQuery.disableAnimationsOf(context) ||
      !TickerMode.valuesOf(context).enabled;

  @override
  void didUpdateWidget(LoadedContentSequence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.generation == oldWidget.generation) return;
    if (widget.generation == null || _static) {
      _clock.value = 1;
    } else {
      _clock.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_static) _clock.value = 1;
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LoadedSequenceScope(
    animation: _clock.isCompleted ? const AlwaysStoppedAnimation(1) : _clock,
    generation: widget.generation,
    firstIndex: widget.firstIndex,
    child: widget.child,
  );
}

class _LoadedSequenceScope extends InheritedWidget {
  const _LoadedSequenceScope({
    required this.animation,
    required this.generation,
    required this.firstIndex,
    required super.child,
  });
  final Animation<double> animation;
  final Object? generation;
  final int firstIndex;

  @override
  bool updateShouldNotify(_LoadedSequenceScope oldWidget) =>
      animation != oldWidget.animation ||
      generation != oldWidget.generation ||
      firstIndex != oldWidget.firstIndex;
}

/// Shares the existing top-down motion vocabulary. Delay is bounded to eight
/// bands, so long lists stay lazy and never wait seconds for offscreen rows.
class LoadedContentItem extends StatelessWidget {
  const LoadedContentItem({
    super.key,
    required this.index,
    required this.child,
    this.animation,
    this.placeholder = const LoadingSkeleton(layout: SkeletonLayout.actions),
  });
  final int index;
  final Widget child;
  final Animation<double>? animation;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final scope = animation == null
        ? context.dependOnInheritedWidgetOfExactType<_LoadedSequenceScope>()
        : null;
    final order = index - (scope?.firstIndex ?? 0);
    final clock = animation ?? scope?.animation;
    // Appending a page makes the previous batch static. Keep its element
    // ancestry intact so in-flight image decodes/arrivals are not remounted.
    final active = clock != null && order >= 0;
    final start = active ? order.clamp(0, 8) * .055 : 0.0;
    return RevealFromTop(
      animation: active ? clock : const AlwaysStoppedAnimation<double>(1),
      start: start,
      end: start + .52,
      placeholder: placeholder,
      child: child,
    );
  }
}

/// Small dependent controls expand in place, borrowing the page's finite
/// cut-in vocabulary. Live glass is clipped, never faded in an opacity layer.
class AnimatedOptionSection extends StatefulWidget {
  const AnimatedOptionSection({
    super.key,
    required this.expanded,
    required this.child,
  });
  final bool expanded;
  final Widget child;
  @override
  State<AnimatedOptionSection> createState() => _AnimatedOptionSectionState();
}

class _AnimatedOptionSectionState extends State<AnimatedOptionSection>
    with SingleTickerProviderStateMixin {
  late final _clock =
      AnimationController(
        vsync: this,
        duration: WenkuMotion.enter,
        reverseDuration: WenkuMotion.exit,
        value: widget.expanded ? 1 : 0,
      )..addStatusListener((_) {
        if (mounted) setState(() {});
      });
  late final _size = _clock.drive(CurveTween(curve: WenkuMotion.ease));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _clock.value = widget.expanded ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(AnimatedOptionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _clock.value = widget.expanded ? 1 : 0;
    } else {
      widget.expanded ? _clock.forward() : _clock.reverse();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_clock.isAnimating && _clock.value == 0
      ? const SizedBox.shrink()
      : IgnorePointer(
          ignoring: !widget.expanded,
          child: ExcludeSemantics(
            excluding: !widget.expanded,
            child: SizeTransition(
              sizeFactor: _size,
              alignment: AlignmentDirectional.topStart,
              child: RevealFromTop(animation: _clock, child: widget.child),
            ),
          ),
        );
}

class RevealFromTop extends StatelessWidget {
  const RevealFromTop({
    super.key,
    required this.animation,
    required this.child,
    this.start = 0,
    this.end = 1,
    this.axis = ArchiveRevealAxis.vertical,
    this.placeholder,
  });
  final Animation<double> animation;
  final Widget child;
  final double start;
  final double end;
  final ArchiveRevealAxis axis;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final revealed = ArchiveReveal(
      animation: animation,
      start: start,
      end: end,
      axis: axis,
      travel: axis == ArchiveRevealAxis.horizontal
          ? const Offset(-10, 0)
          : const Offset(-8, -6),
      child: child,
    );
    return placeholder == null
        ? revealed
        : LoadingHandoff(
            animation: animation,
            start: start,
            end: end,
            axis: axis == ArchiveRevealAxis.vertical
                ? Axis.vertical
                : Axis.horizontal,
            travel: axis == ArchiveRevealAxis.horizontal
                ? const Offset(-10, 0)
                : const Offset(-8, -6),
            placeholder: placeholder!,
            child: revealed,
          );
  }
}

/// Copy of upstream `loading_handoff.dart` `LoadingHandoff`. The arriving
/// content owns layout. Its static skeleton remains below the unrevealed
/// portion, so a delayed cut-in never exposes an empty page. With
/// [crossfade] the placeholder already owns the final geometry and is replaced
/// in place by an opacity handoff instead of the clipped remainder.
class LoadingHandoff extends StatefulWidget {
  const LoadingHandoff({
    super.key,
    required this.animation,
    required this.placeholder,
    required this.child,
    this.start = 0,
    this.end = 1,
    this.axis = Axis.vertical,
    this.travel = Offset.zero,
    this.crossfade = false,
  });
  final Animation<double> animation;
  final Widget placeholder, child;
  final double start, end;
  final Axis axis;
  final Offset travel;

  /// Replace ink in place when the placeholder already has the final geometry.
  final bool crossfade;

  @override
  State<LoadingHandoff> createState() => _LoadingHandoffState();
}

class _LoadingHandoffState extends State<LoadingHandoff> {
  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.forward) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(LoadingHandoff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_status);
      widget.animation.addStatusListener(_status);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    final opacity = widget.animation.drive(
      CurveTween(
        curve: Interval(widget.start, widget.end, curve: Curves.easeOutCubic),
      ),
    );
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (widget.animation.value < widget.end &&
            !MediaQuery.disableAnimationsOf(context))
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: widget.crossfade
                    ? FadeTransition(
                        opacity: ReverseAnimation(opacity),
                        child: RepaintBoundary(child: widget.placeholder),
                      )
                    : _SkeletonRemainder(
                        animation: widget.animation,
                        start: widget.start,
                        end: widget.end,
                        axis: widget.axis,
                        travel: widget.travel,
                        child: RepaintBoundary(child: widget.placeholder),
                      ),
              ),
            ),
          ),
        widget.crossfade
            ? FadeTransition(opacity: opacity, child: widget.child)
            : widget.child,
      ],
    );
  }
}

class _SkeletonRemainder extends SingleChildRenderObjectWidget {
  const _SkeletonRemainder({
    required this.animation,
    required this.start,
    required this.end,
    required this.axis,
    required this.travel,
    required super.child,
  });
  final Animation<double> animation;
  final double start, end;
  final Axis axis;
  final Offset travel;
  @override
  _SkeletonRemainderRender createRenderObject(BuildContext context) =>
      _SkeletonRemainderRender(animation, start, end, axis, travel);
  @override
  void updateRenderObject(
    BuildContext context,
    _SkeletonRemainderRender render,
  ) => render.update(animation, start, end, axis, travel);
}

class _SkeletonRemainderRender extends RenderProxyBox {
  _SkeletonRemainderRender(
    this.animation,
    this.start,
    this.end,
    this.axis,
    this.travel,
  );
  Animation<double> animation;
  double start, end;
  Axis axis;
  Offset travel;
  final _clip = LayerHandle<ClipPathLayer>();
  void _tick() => markNeedsPaint();
  void update(
    Animation<double> value,
    double from,
    double to,
    Axis direction,
    Offset displacement,
  ) {
    if (animation != value) {
      if (attached) animation.removeListener(_tick);
      animation = value;
      if (attached) animation.addListener(_tick);
    }
    start = from;
    end = to;
    axis = direction;
    travel = displacement;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    animation.addListener(_tick);
  }

  @override
  void detach() {
    animation.removeListener(_tick);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final progress = Interval(
      start,
      end,
      curve: Curves.easeOutCubic,
    ).transform(animation.value.clamp(0.0, 1.0));
    if (progress == 1 || child == null || size.isEmpty) return;
    if (progress == 0) {
      super.paint(context, offset);
      return;
    }
    final bounds = Offset.zero & size;
    final revealed = Rect.fromLTWH(
      0,
      0,
      size.width * (axis == Axis.horizontal ? progress : 1),
      size.height * (axis == Axis.vertical ? progress : 1),
    ).shift(travel * (1 - progress)).intersect(bounds);
    final remainder = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addRect(revealed);
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      bounds,
      remainder,
      super.paint,
      clipBehavior: Clip.hardEdge,
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
