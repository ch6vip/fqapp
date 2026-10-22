import 'package:flutter/material.dart';

import 'home_design.dart';

/// How far the wash is allowed to travel over the whole feed. The contour
/// drifts at [_washDrift] of the scroll offset, so the maximum travel is
/// [_washScrollRange] * [_washDrift].
const double _washScrollRange = 900;
const double _washDrift = 0.08;

/// 暖光最多上移这么多。吸顶的频道条也要留同样的余量，
/// 否则平移后它的底部会露出一截没画的纯画布。
const double homeWashMaxTravel = _washScrollRange * _washDrift;

/// 暖光的圆心（页面坐标）。
Offset homeWashCenter(double width) => Offset(width * 0.98, 40);

/// 暖光的半径。
double homeWashRadius(double width) => width * 0.8;

/// 当前滚动带来的上移距离。吸顶的频道条要用同一段暖光铺底，
/// 所以两边必须用同一个位移，否则吸顶边上会错开。
double homeWashTravel(ScrollController scroll) {
  if (!scroll.hasClients) return 0;
  return scroll.offset.clamp(0.0, _washScrollRange) * _washDrift;
}

/// 吸顶条上那段暖光的几何，换到吸顶条自己的坐标系。
///
/// 背景层铺满整页，圆心贴着**页面**右上角；吸顶条却坐在居中的内容列里，
/// 平板横屏（1024 里 840 的列）和桌面窗口下宽度就不是一个数。所以圆要按
/// 页面宽度推，再减掉这一列的左边距和状态栏高度，段内才接得上背景层的
/// 下半段。[viewportWidth] 未知（0）时退回按吸顶条自己的宽度画。
({Offset center, double radius}) homePinnedWash({
  required double viewportWidth,
  required double barWidth,
  required double top,
}) {
  final width = viewportWidth > barWidth ? viewportWidth : barWidth;
  return (
    center: homeWashCenter(width) - Offset((width - barWidth) / 2, top),
    radius: homeWashRadius(width),
  );
}

final _lightWash = _washGradient(0.055);
final _darkWash = _washGradient(0.07);

// 纯黑画布上同样的 7% 只剩下 (17,6,4)，肉眼读不出红色，首页就成了唯一
// 没有暖光的一屏。OLED 补到 0.16（与详情页 masthead 深色的 0.17 同档），
// 在 #000 上约 (38,13,9)，与普通深色 7% 在 #151517 上的观感对齐。
final _oledWash = _washGradient(0.16);

RadialGradient _washGradient(double alpha) => RadialGradient(
  colors: [
    HomePalette.accent.withValues(alpha: alpha),
    HomePalette.accent.withValues(alpha: 0),
  ],
);

/// 当前外观下这层暖光的渐变。
RadialGradient homeWashGradient(HomePalette palette) {
  if (!palette.dark) return _lightWash;
  return palette.oled ? _oledWash : _darkWash;
}

/// A quiet wash of warm light. Scrolling moves the contour, not a ticker.
///
/// Both the light and the dark appearance paint it: on the dark canvas the
/// accent reads as a low, continuous glow along the top of the feed, which is
/// the reference the light paper follows. Only e-ink leaves it off -- that
/// screen wants a pure white canvas.
///
/// The wash is painted once into a layer of its own and then only *translated*
/// while the feed scrolls. Re-painting the gradient on every scroll frame
/// costs a full-viewport raster plus a fresh shader allocation per frame, for a
/// picture that never actually changes -- and the feed already repaints its own
/// layer, so the backdrop was doubling the work of every scroll frame.
///
/// The painted layer is grown past the bottom of the viewport so translating it
/// upwards can never expose an unpainted seam at the bottom edge. The page
/// background itself comes from the enclosing [Scaffold], which paints the same
/// [HomePalette.canvas] colour, so the grown area blends in exactly.
class AmbientBackdrop extends StatelessWidget {
  final ScrollController scroll;

  const AmbientBackdrop({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // 深色 / OLED 同样保留这层暖光：深色的红色渐变是浅色纸面的参照，删掉它
    // 反而让两种外观对不上。只有墨水屏要求纯白画布。
    if (palette.eink) return const SizedBox.shrink();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: -homeWashMaxTravel,
            // Outer boundary keeps the per-frame transform out of the feed's
            // own layer; the inner one is the cached wash the transform moves.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: scroll,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _PaperLightPainter(palette: palette),
                  ),
                ),
                builder: (context, child) => Transform.translate(
                  offset: Offset(
                    0,
                    reducedMotion ? 0 : -homeWashTravel(scroll),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaperLightPainter extends CustomPainter {
  final HomePalette palette;

  const _PaperLightPainter({required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    final radius = homeWashRadius(size.width);
    if (radius <= 0) return;
    final center = homeWashCenter(size.width);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = homeWashGradient(
          palette,
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_PaperLightPainter oldDelegate) =>
      palette.dark != oldDelegate.palette.dark ||
      palette.oled != oldDelegate.palette.oled;
}
