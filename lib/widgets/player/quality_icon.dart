import 'package:flutter/material.dart';

/// 官方旧栏 drawable/b2s.xml 的 28dp 清晰度图标：圆角框 + 「HD」字形。
/// 路径坐标与官方 vector 逐点一致（viewport 28×28）。浅色更多面板的
/// 清晰度行与旧底栏共用；[size] 按宿主缩放，[color] 官方为白色
/// （浅色面板传黑色日间前景）。
class QualityIconPainter extends CustomPainter {
  const QualityIconPainter({this.color = const Color(0xFFFFFFFF)});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 28, size.height / 28);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 圆角外框：x 3.747..24.253，y 5.958..22.042，圆角 2.7。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(3.747, 5.958, 24.253, 22.042),
        const Radius.circular(2.7),
      ),
      stroke,
    );
    // 「H」：一条横线加两条竖线。
    canvas.drawLine(
      const Offset(8.393, 13.918),
      const Offset(12.617, 13.918),
      stroke,
    );
    stroke.strokeCap = StrokeCap.butt;
    canvas.drawLine(const Offset(8.484, 11.193), const Offset(8.484, 16.959), stroke);
    canvas.drawLine(const Offset(12.783, 11.193), const Offset(12.783, 16.959), stroke);
    // 「D」字形是官方 pathData 的五段填充（上下衬线、外碗、内碗、竖笔），
    // 坐标原样搬运；winding 方向官方即 nonzero。
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawPath(_glyphPath(), fill);
    canvas.restore();
  }

  static Path _glyphPath() => Path()
    ..moveTo(15.721, 16.809)
    ..lineTo(14.921, 16.809)
    ..cubicTo(14.921, 17.212, 15.221, 17.552, 15.622, 17.602)
    ..lineTo(15.721, 16.809)
    ..close()
    ..moveTo(15.721, 11.178)
    ..lineTo(15.622, 10.384)
    ..cubicTo(15.221, 10.434, 14.921, 10.774, 14.921, 11.178)
    ..lineTo(15.721, 11.178)
    ..close()
    ..moveTo(19.944, 13.993)
    ..lineTo(19.144, 13.993)
    ..cubicTo(19.144, 14.528, 18.902, 15.087, 18.393, 15.487)
    ..cubicTo(17.889, 15.883, 17.06, 16.17, 15.82, 16.015)
    ..lineTo(15.721, 16.809)
    ..lineTo(15.622, 17.602)
    ..cubicTo(17.197, 17.799, 18.479, 17.455, 19.382, 16.745)
    ..cubicTo(20.281, 16.038, 20.744, 15.013, 20.744, 13.993)
    ..lineTo(19.944, 13.993)
    ..close()
    ..moveTo(15.721, 11.178)
    ..lineTo(15.82, 11.972)
    ..cubicTo(17.06, 11.817, 17.889, 12.103, 18.393, 12.499)
    ..cubicTo(18.902, 12.899, 19.144, 13.458, 19.144, 13.993)
    ..lineTo(19.944, 13.993)
    ..lineTo(20.744, 13.993)
    ..cubicTo(20.744, 12.973, 20.281, 11.948, 19.382, 11.241)
    ..cubicTo(18.479, 10.531, 17.197, 10.187, 15.622, 10.384)
    ..lineTo(15.721, 11.178)
    ..close()
    ..moveTo(15.721, 11.178)
    ..lineTo(14.921, 11.178)
    ..lineTo(14.921, 16.809)
    ..lineTo(15.721, 16.809)
    ..lineTo(16.521, 16.809)
    ..lineTo(16.521, 11.178)
    ..lineTo(15.721, 11.178)
    ..close();

  @override
  bool shouldRepaint(QualityIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
