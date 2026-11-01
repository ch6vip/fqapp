import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Applies chapter-window changes in the viewport's layout retry, before paint.
/// Unlike jumpTo, a sliver correction preserves an ongoing drag or fling.
class ReaderScrollAnchor extends SingleChildRenderObjectWidget {
  const ReaderScrollAnchor({
    super.key,
    required this.takeCorrection,
    required Widget sliver,
  }) : super(child: sliver);

  final double Function() takeCorrection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReaderScrollAnchor(takeCorrection);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    final anchor = renderObject as _RenderReaderScrollAnchor;
    anchor.takeCorrection = takeCorrection;
    anchor.markNeedsLayout();
  }
}

class _RenderReaderScrollAnchor extends RenderProxySliver {
  _RenderReaderScrollAnchor(this.takeCorrection);

  double Function() takeCorrection;

  @override
  void performLayout() {
    final correction = takeCorrection();
    if (correction != 0) {
      geometry = SliverGeometry(scrollOffsetCorrection: correction);
      return;
    }
    super.performLayout();
  }
}
