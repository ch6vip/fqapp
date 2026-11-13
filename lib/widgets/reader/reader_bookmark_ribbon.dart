import 'package:material_ui/material_ui.dart';

/// Page-owned bookmark ribbon, also used by the exposed pull-to-bookmark area.
/// Place directly in a Stack: the page transform then carries the mark with it.
class ReaderBookmarkRibbon extends StatelessWidget {
  const ReaderBookmarkRibbon({
    super.key,
    required this.color,
    this.height = 72,
    this.textInset = 20,
    this.semanticLabel = '当前页已添加书签',
  });

  final Color color;
  final double height;

  /// Actual horizontal text margin of this page. Narrow user margins reduce
  /// the ribbon width instead of painting over text or repaginating the book.
  final double textInset;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final margin = textInset.clamp(0.0, double.infinity);
    final rightGap = (margin / 4).clamp(0.0, 4.0);
    final width = (margin - rightGap - 2).clamp(0.0, 10.0);
    return Positioned(
      top: 0,
      right: rightGap,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Semantics(
          label: semanticLabel,
          child: ClipPath(
            clipper: const _RibbonClipper(),
            child: ColoredBox(color: color),
          ),
        ),
      ),
    );
  }
}

class _RibbonClipper extends CustomClipper<Path> {
  const _RibbonClipper();

  @override
  Path getClip(Size size) => Path()
    ..lineTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(size.width / 2, (size.height - 4).clamp(0, size.height))
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(_RibbonClipper oldClipper) => false;
}
