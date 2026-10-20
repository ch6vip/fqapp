import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 仿真卷页：直折线 + 镜像翻页 + 折线两侧渐变阴影。
///
/// 参考了 Legado `SimulationPageDelegate` 的卷页形态（折线从页角划过、翻起的
/// 部分是“纸背”、折线两侧有阴影），但实现是 fqapp 自己的：Legado 把页面
/// 截图成位图再在 Canvas 上画贝塞尔折线，fqapp 的页面是 widget 树，截图
/// 代价大，这里用裁剪 + 镜像变换做同样的视觉效果：
///
/// - 去页被折线切成两部分：未卷部分原样显示，已卷部分镜像翻回折线另一侧
///   当作纸背，并叠一层暗色模拟纸背。
/// - 折线两侧各一道渐变阴影：去页侧（纸背侧）与来页侧（露出侧）都在折线处
///   最暗、向外淡出。
/// - 折线带一点倾斜：正向翻页从右下角卷起，折线顶端落后于底端；反向对称。
///   倾斜随进度呈正弦变化，起止时折线竖直，不会出现折线越界。
///
/// [progress] 0 表示尚未翻页，1 表示翻完；[forward] 为 true 时从右向左翻。
class ReaderPageCurl extends StatelessWidget {
  final Widget outgoing;
  final Widget incoming;
  final double progress;
  final bool forward;
  final Color backgroundColor;

  const ReaderPageCurl({
    super.key,
    required this.outgoing,
    required this.incoming,
    required this.progress,
    required this.forward,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    if (progress <= 0.001) return outgoing;
    if (progress >= 0.999) return incoming;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isEmpty) return outgoing;
        final geo = ReaderPageCurlGeometry(
          size: size,
          progress: progress,
          forward: forward,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: backgroundColor, child: incoming),
            ClipPath(
              clipper: _CurlPathClipper(geo.visiblePath),
              child: ColoredBox(color: backgroundColor, child: outgoing),
            ),
            Transform(
              transform: geo.reflection,
              child: ClipPath(
                clipper: _CurlPathClipper(geo.flapPath),
                child: ColoredBox(
                  color: backgroundColor,
                  child: Stack(
                    children: [
                      outgoing,
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Color.fromRGBO(0, 0, 0, 0.12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            CustomPaint(painter: _CurlShadowPainter(geo)),
          ],
        );
      },
    );
  }
}

/// 纯几何：折线、两块裁剪区域、镜像矩阵、两道阴影四边形。无 widget 依赖，
/// 可直接单测。
class ReaderPageCurlGeometry {
  final Size size;
  final double progress;
  final bool forward;

  ReaderPageCurlGeometry({
    required this.size,
    required double progress,
    required this.forward,
  }) : progress = progress.clamp(0.0, 1.0);

  double get _tilt =>
      size.height * 0.18 * math.sin(math.pi * progress);

  /// 折线顶端点。
  Offset get foldTop => forward
      ? Offset(size.width * (1 - progress) + _tilt, 0)
      : Offset(size.width * progress, 0);

  /// 折线底端点。
  Offset get foldBottom => forward
      ? Offset(size.width * (1 - progress), size.height)
      : Offset(size.width * progress - _tilt, size.height);

  /// 去页仍可见的区域：折线未卷过去的一侧。
  Path get visiblePath {
    final path = Path();
    if (forward) {
      path
        ..moveTo(0, 0)
        ..lineTo(foldTop.dx, 0)
        ..lineTo(foldBottom.dx, size.height)
        ..lineTo(0, size.height)
        ..close();
    } else {
      path
        ..moveTo(foldTop.dx, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(foldBottom.dx, size.height)
        ..close();
    }
    return path;
  }

  /// 去页被卷起的区域：镜像翻回折线另一侧当作纸背。
  Path get flapPath {
    final path = Path();
    if (forward) {
      path
        ..moveTo(foldTop.dx, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(foldBottom.dx, size.height)
        ..close();
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(foldTop.dx, 0)
        ..lineTo(foldBottom.dx, size.height)
        ..lineTo(0, size.height)
        ..close();
    }
    return path;
  }

  /// 沿折线做镜像的仿射矩阵：P' = (I - 2nnᵀ)P + 2(n·B)n，其中 n 是折线
  /// 的单位法向量，B 是折线上的任意一点（这里取底端点）。
  Matrix4 get reflection {
    final d = foldTop - foldBottom;
    final length = d.distance;
    if (length < 0.001) return Matrix4.identity();
    final nx = -d.dy / length;
    final ny = d.dx / length;
    final dot = nx * foldBottom.dx + ny * foldBottom.dy;
    final matrix = Matrix4.identity();
    matrix.setEntry(0, 0, 1 - 2 * nx * nx);
    matrix.setEntry(0, 1, -2 * nx * ny);
    matrix.setEntry(1, 0, -2 * nx * ny);
    matrix.setEntry(1, 1, 1 - 2 * ny * ny);
    matrix.setEntry(0, 3, 2 * dot * nx);
    matrix.setEntry(1, 3, 2 * dot * ny);
    return matrix;
  }

  /// 指向来页露出侧的折线单位法向量：取折线法向量中指向已知露出侧
  /// （正向是右边缘，反向是左边缘）的一支。
  Offset get _incomingNormal {
    final d = foldBottom - foldTop;
    final length = d.distance;
    if (length < 0.001) {
      return forward ? const Offset(1, 0) : const Offset(-1, 0);
    }
    var normal = Offset(-d.dy / length, d.dx / length);
    final mid = (foldTop + foldBottom) / 2;
    final sidePoint = forward
        ? Offset(size.width, size.height / 2)
        : Offset(0, size.height / 2);
    if ((sidePoint - mid).dx * normal.dx +
            (sidePoint - mid).dy * normal.dy <
        0) {
      normal = -normal;
    }
    return normal;
  }

  /// 来页侧阴影四边形：沿折线向外延伸 30px，折线处最暗。
  List<Offset> get incomingShadowQuad {
    final n = _incomingNormal * 30;
    return [
      foldTop,
      foldBottom,
      foldBottom + n,
      foldTop + n,
    ];
  }

  /// 纸背侧阴影四边形：沿折线向内延伸 30px，折线处最暗。
  List<Offset> get flapShadowQuad {
    final n = _incomingNormal * 30;
    return [
      foldTop,
      foldBottom,
      foldBottom - n,
      foldTop - n,
    ];
  }
}

class _CurlPathClipper extends CustomClipper<Path> {
  final Path path;

  const _CurlPathClipper(this.path);

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(covariant _CurlPathClipper oldClipper) => true;
}

class _CurlShadowPainter extends CustomPainter {
  final ReaderPageCurlGeometry geo;

  _CurlShadowPainter(this.geo);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _paintQuad(canvas, size, geo.incomingShadowQuad, 0.32);
    _paintQuad(canvas, size, geo.flapShadowQuad, 0.28);
  }

  void _paintQuad(
    Canvas canvas,
    Size size,
    List<Offset> quad,
    double alpha,
  ) {
    final foldMid = (quad[0] + quad[1]) / 2;
    final outerMid = (quad[2] + quad[3]) / 2;
    final gradient = LinearGradient(
      colors: [
        Colors.black.withValues(alpha: alpha),
        Colors.black.withValues(alpha: 0),
      ],
      begin: _align(foldMid, size),
      end: _align(outerMid, size),
    );
    final paint = Paint()
      ..shader = gradient.createShader(Offset.zero & size);
    canvas.drawPath(Path()..addPolygon(quad, true), paint);
  }

  Alignment _align(Offset point, Size size) => Alignment(
    2 * point.dx / size.width - 1,
    2 * point.dy / size.height - 1,
  );

  @override
  bool shouldRepaint(covariant _CurlShadowPainter oldDelegate) => true;
}
