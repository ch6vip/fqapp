import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放页右栏的「清屏」图标按钮。
///
/// 从 [VideoPlayerChrome] 里搬出来的纯展示件：只有一次点击回调，图标由
/// 下面的 painter 现画（没有对应切图）。清屏态下这一项由
/// `player-clear-screen` 的文字按钮接管，两者共用同一个 key 语义。
class PlayletClearScreenButton extends StatelessWidget {
  const PlayletClearScreenButton({
    super.key,
    this.onTap,
    this.color = Colors.white,
  });

  final VoidCallback? onTap;

  /// 图标颜色。默认白色只因为当前唯一落点是视频画面；换到浅色底要显式传。
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '清屏',
    button: true,
    child: GestureDetector(
      key: const ValueKey('player-clear-screen'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            key: const ValueKey('player-clear-icon'),
            width: 28,
            height: 28,
            child: Center(
              child: CustomPaint(
                size: const Size(20, 23),
                painter: _ClearScreenIconPainter(color),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ClearScreenIconPainter extends CustomPainter {
  const _ClearScreenIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(1, size.height / size.width);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * scale
      ..strokeCap = StrokeCap.round
      ..color = color;
    const badge = Offset(17.9, 17.6);
    final page = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3.2 * scale, 3.2 * scale, 16.3 * scale, 17.6 * scale),
          Radius.circular(4 * scale),
        ),
      );
    final center = Offset(badge.dx * scale, badge.dy * scale);
    final cut = Path()
      ..addOval(Rect.fromCircle(center: center, radius: 6.1 * scale));
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        cut,
      ),
    );
    canvas.drawPath(page, stroke);
    canvas.restore();
    canvas.drawLine(
      Offset(7.8 * scale, 9 * scale),
      Offset(16.4 * scale, 9 * scale),
      stroke..strokeWidth = 1.5 * scale,
    );
    canvas.drawLine(
      Offset(7.8 * scale, 13 * scale),
      Offset(15.2 * scale, 13 * scale),
      stroke,
    );
    final radius = 4.4 * scale;
    canvas.drawCircle(center, radius, stroke);
    final diagonal = radius / math.sqrt2;
    canvas.drawLine(
      Offset(center.dx - diagonal, center.dy + diagonal),
      Offset(center.dx + diagonal, center.dy - diagonal),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ClearScreenIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
