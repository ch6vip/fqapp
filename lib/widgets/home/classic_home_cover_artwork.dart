import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Original geometric fallback cover from f329399, used only by classic UI.
class ClassicHomeCoverArtwork extends CustomPainter {
  final String kind;

  const ClassicHomeCoverArtwork(this.kind);

  @override
  void paint(Canvas canvas, Size size) {
    final colors = switch (kind) {
      'video' => [const Color(0xFF734740), const Color(0xFF242428)],
      'manju' => [const Color(0xFF8B557E), const Color(0xFF35283D)],
      'manga' => [const Color(0xFF6F6887), const Color(0xFF343349)],
      'audio' => [const Color(0xFF426C78), const Color(0xFF233B42)],
      _ => [const Color(0xFF6A7964), const Color(0xFF293C35)],
    };
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(Offset.zero & size),
    );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFFF2DFC3).withValues(alpha: 0.22);
    final center = Offset(size.width * 0.92, size.height * 0.30);
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(center, size.width * (0.27 + i * 0.14), line);
    }
    canvas.save();
    canvas.translate(size.width * 0.17, size.height * 0.74);
    canvas.rotate(-math.pi / 5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width * 1.1, size.height * 0.13),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFFE2C99A).withValues(alpha: 0.13),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ClassicHomeCoverArtwork oldDelegate) =>
      oldDelegate.kind != kind;
}
