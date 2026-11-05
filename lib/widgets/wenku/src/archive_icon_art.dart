part of 'archive_icons.dart';

/// One source for Flutter painting and SVG export. Exported previews therefore
/// show the actual app vectors and intermediate poses, not a separate mockup.
abstract final class ArchiveIconArt {
  static List<Path> paths(
    ArchiveSymbol symbol, {
    double contact = 0,
    ArchiveIconGesture? gesture,
    bool active = false,
  }) => _build(
    _IconPose.of(symbol, active),
    contact: contact,
    gesture: gesture,
  ).strokes.map((stroke) => stroke.path).toList(growable: false);

  static String svg(
    ArchiveSymbol symbol, {
    double contact = 0,
    ArchiveIconGesture? gesture,
    bool active = false,
    ArchiveSymbol? towards,
    bool? towardsActive,
    double progress = 1,
    String color = 'currentColor',
    double strokeWidth = 1.72,
  }) {
    final from = _IconPose.of(symbol, active);
    final to = _IconPose.of(towards ?? symbol, towardsActive ?? active);
    final t = progress;
    String paths(_IconPose pose, double alpha) =>
        _build(pose, contact: contact, gesture: gesture, serialize: true)
            .strokes
            .map(
              (s) =>
                  '<path d="${s.data}" '
                  'fill="${s.fill ? color : 'none'}" '
                  'stroke="${s.fill ? 'none' : color}" '
                  'stroke-width="${_number(strokeWidth * s.width)}" '
                  'opacity="${_number(s.opacity * alpha.clamp(0, 1))}"/>',
            )
            .join();
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        'fill="none" stroke-linecap="round" stroke-linejoin="round" '
        'aria-hidden="true">'
        '${from.symbol == to.symbol ? paths(_IconPose.lerp(from, to, t), 1) : '${paths(from, 1 - t)}${paths(to, t)}'}'
        '</svg>';
  }

  static _Art _build(
    _IconPose pose, {
    double contact = 0,
    ArchiveIconGesture? gesture,
    bool serialize = false,
  }) => _foldDrawing(
    pose,
    gesture ?? ArchiveIconGesture(contact, contact, contact),
    serialize: serialize,
  );
}

class _Stroke {
  const _Stroke(
    this.path, {
    this.fill = false,
    this.opacity = 1,
    this.width = 1,
    this.data = '',
  });
  final Path path;
  final bool fill;
  final double opacity, width;
  final String data;
}

class _Art {
  _Art({required this.serialize});
  final bool serialize;
  final strokes = <_Stroke>[];
  Matrix4 _matrix = Matrix4.identity();

  void rotate(double angle, VoidCallback draw) {
    transform(angle: angle, draw: draw);
  }

  void move(double x, double y, VoidCallback draw) =>
      transform(x: x, y: y, draw: draw);

  void transform({
    double x = 0,
    double y = 0,
    double angle = 0,
    double scale = 1,
    Offset pivot = const Offset(12, 12),
    required VoidCallback draw,
  }) {
    final previous = _matrix;
    _matrix = Matrix4.copy(previous)
      ..translateByDouble(x + pivot.dx, y + pivot.dy, 0, 1)
      ..rotateZ(angle)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-pivot.dx, -pivot.dy, 0, 1);
    draw();
    _matrix = previous;
  }

  void card(
    double x,
    double y,
    double w,
    double h, {
    double fold = 2,
    double shade = .12,
    bool outline = true,
  }) {
    final f = math.min(fold, math.min(w, h) * .48);
    void contour(_Trace s) => s
        .m(x, y)
        .l(x + w - f, y)
        .l(x + w, y + f)
        .l(x + w, y + h)
        .l(x, y + h)
        .z();
    if (shade > 0) path(contour, fill: true, opacity: shade);
    if (outline) {
      path(contour);
      poly([x + w - f, y, x + w - f, y + f, x + w, y + f], opacity: .7);
    }
  }

  void mark(double x, double y, double size, {double angle = 0}) => transform(
    angle: angle,
    pivot: Offset(x + size / 2, y + size / 2),
    draw: () => rect(x, y, size, size, fill: true),
  );

  void ring() {
    arc(12, 12, 8.4, 8.4, -.48, math.pi * 1.83);
    mark(16.9, 4.5, 1.5, angle: math.pi / 4);
  }

  void path(
    void Function(_Trace) draw, {
    bool fill = false,
    double opacity = 1,
    double width = 1,
  }) {
    final trace = _Trace(serialize: serialize, matrix: _matrix);
    draw(trace);
    strokes.add(
      _Stroke(
        trace.path,
        fill: fill,
        opacity: opacity.clamp(0, 1),
        width: width,
        data: trace.data,
      ),
    );
  }

  void line(double x1, double y1, double x2, double y2, {double opacity = 1}) =>
      path((s) => s.m(x1, y1).l(x2, y2), opacity: opacity);

  void poly(
    List<double> points, {
    bool close = false,
    bool fill = false,
    double opacity = 1,
  }) => path(
    (s) {
      s.m(points[0], points[1]);
      for (var i = 2; i < points.length; i += 2) {
        s.l(points[i], points[i + 1]);
      }
      if (close) s.z();
    },
    fill: fill,
    opacity: opacity,
  );

  void rect(
    double x,
    double y,
    double w,
    double h, {
    double radius = 0,
    bool fill = false,
    double opacity = 1,
  }) => path(
    (s) => s
        .m(x + radius, y)
        .l(x + w - radius, y)
        .q(x + w, y, x + w, y + radius)
        .l(x + w, y + h - radius)
        .q(x + w, y + h, x + w - radius, y + h)
        .l(x + radius, y + h)
        .q(x, y + h, x, y + h - radius)
        .l(x, y + radius)
        .q(x, y, x + radius, y)
        .z(),
    fill: fill,
    opacity: opacity,
  );

  void circle(
    double x,
    double y,
    double r, {
    bool fill = false,
    double opacity = 1,
  }) => ellipse(x, y, r, r, fill: fill, opacity: opacity);

  void dot(double x, double y, double r) => circle(x, y, r, fill: true);

  void ellipse(
    double x,
    double y,
    double rx,
    double ry, {
    bool fill = false,
    double opacity = 1,
  }) {
    const k = .5522847498307936;
    path(
      (s) => s
          .m(x + rx, y)
          .c(x + rx, y + ry * k, x + rx * k, y + ry, x, y + ry)
          .c(x - rx * k, y + ry, x - rx, y + ry * k, x - rx, y)
          .c(x - rx, y - ry * k, x - rx * k, y - ry, x, y - ry)
          .c(x + rx * k, y - ry, x + rx, y - ry * k, x + rx, y)
          .z(),
      fill: fill,
      opacity: opacity,
    );
  }

  void arc(
    double x,
    double y,
    double rx,
    double ry,
    double start,
    double sweep,
  ) {
    path((s) {
      s.m(x + rx * math.cos(start), y + ry * math.sin(start));
      final n = (sweep.abs() / (math.pi / 4)).ceil();
      final step = sweep / n;
      for (var i = 0; i < n; i++) {
        final a = start + step * i,
            b = a + step,
            k = 4 / 3 * math.tan(step / 4);
        s.c(
          x + rx * (math.cos(a) - k * math.sin(a)),
          y + ry * (math.sin(a) + k * math.cos(a)),
          x + rx * (math.cos(b) + k * math.sin(b)),
          y + ry * (math.sin(b) - k * math.cos(b)),
          x + rx * math.cos(b),
          y + ry * math.sin(b),
        );
      }
    });
  }

  void star(double x, double y, double r) => path(
    (s) => s
        .m(x, y - r)
        .q(x + r * .15, y - r * .15, x + r, y)
        .q(x + r * .15, y + r * .15, x, y + r)
        .q(x - r * .15, y + r * .15, x - r, y)
        .q(x - r * .15, y - r * .15, x, y - r)
        .z(),
  );
}

class _Trace {
  _Trace({required this.serialize, this._matrix});
  final bool serialize;
  final Matrix4? _matrix;
  final path = Path();
  final _data = StringBuffer();
  String get data => _data.toString();
  Offset _p(double x, double y) {
    final m = _matrix?.storage;
    return m == null
        ? Offset(x, y)
        : Offset(m[0] * x + m[4] * y + m[12], m[1] * x + m[5] * y + m[13]);
  }

  _Trace m(double x, double y) {
    final p = _p(x, y);
    path.moveTo(p.dx, p.dy);
    if (serialize) _data.write('M${_number(p.dx)} ${_number(p.dy)}');
    return this;
  }

  _Trace l(double x, double y) {
    final p = _p(x, y);
    path.lineTo(p.dx, p.dy);
    if (serialize) _data.write('L${_number(p.dx)} ${_number(p.dy)}');
    return this;
  }

  _Trace q(double x1, double y1, double x, double y) {
    final a = _p(x1, y1), b = _p(x, y);
    path.quadraticBezierTo(a.dx, a.dy, b.dx, b.dy);
    if (serialize) {
      _data.write(
        'Q${_number(a.dx)} ${_number(a.dy)} ${_number(b.dx)} ${_number(b.dy)}',
      );
    }
    return this;
  }

  _Trace c(double x1, double y1, double x2, double y2, double x, double y) {
    final a = _p(x1, y1), b = _p(x2, y2), c = _p(x, y);
    path.cubicTo(a.dx, a.dy, b.dx, b.dy, c.dx, c.dy);
    if (serialize) {
      _data.write(
        'C${_number(a.dx)} ${_number(a.dy)} ${_number(b.dx)} ${_number(b.dy)} ${_number(c.dx)} ${_number(c.dy)}',
      );
    }
    return this;
  }

  _Trace z() {
    path.close();
    if (serialize) _data.write('Z');
    return this;
  }
}

String _number(double n) =>
    n.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
