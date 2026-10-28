import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/app_theme.dart';
import '../../services/audio_page_theme.dart';
import '../../services/poster_cache.dart';

/// The expanded dk5/hm.xml player; experimental edge folding stays disabled.
class AudioFloatingPlayer extends StatefulWidget {
  const AudioFloatingPlayer({
    super.key,
    required this.title,
    required this.cover,
    required this.progress,
    required this.readProgress,
    required this.playing,
    required this.loading,
    required this.canToggle,
    required this.visible,
    required this.bottomInset,
    required this.onOpen,
    required this.onToggle,
    required this.onClose,
  });

  final String title;
  final String cover;

  /// Notifies when [readProgress] changes, without rebuilding the capsule.
  final Listenable progress;

  /// Played fraction of the current item, 0..1 (official `fa3/a` ring).
  final double Function() readProgress;
  final bool playing;
  final bool loading;
  final bool canToggle;
  final bool visible;
  final double bottomInset;
  final VoidCallback onOpen;
  final VoidCallback onToggle;
  final VoidCallback onClose;

  @override
  State<AudioFloatingPlayer> createState() => _AudioFloatingPlayerState();
}

class _AudioFloatingPlayerState extends State<AudioFloatingPlayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _width = 162.0;
  static const _height = 50.0;
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  );
  Color _background = const Color(0xFC666666);
  bool _right = false;
  double _vertical = 1;
  Offset? _drag;
  bool _closing = false;
  Timer? _closeTimer;
  bool _systemReducedMotion = false;
  bool get _reducedMotion => _systemReducedMotion || einkModeNotifier.value;
  bool _active =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    einkModeNotifier.addListener(_motionChanged);
    unawaited(_loadColor());
  }

  void _motionChanged() {
    setState(() {});
    _syncRotation();
  }

  Future<void> _loadColor() async {
    final cover = widget.cover;
    // 官方 GlobalPlayerView 取 Palette swatch 的色相，再套固定的饱和度/明度。
    final hue = await fetchCoverPaletteHue(cover);
    if (!mounted || widget.cover != cover) return;
    setState(() {
      _background = hue == null
          ? const Color(0xFC666666)
          : HSVColor.fromAHSV(252 / 255, hue, 0.23, 0.54).toColor();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _systemReducedMotion =
        media.disableAnimations || media.accessibleNavigation;
    _syncRotation();
  }

  @override
  void didUpdateWidget(AudioFloatingPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover) {
      _background = const Color(0xFC666666);
      unawaited(_loadColor());
    }
    _syncRotation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _syncRotation();
  }

  void _syncRotation() {
    if (_active &&
        widget.visible &&
        widget.playing &&
        !widget.loading &&
        !_reducedMotion &&
        !_closing) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  void _close() {
    if (_closing) return;
    if (_reducedMotion) {
      widget.onClose();
      return;
    }
    setState(() => _closing = true);
    _syncRotation();
    // A route may hide/mute the widget during the dismissal animation.
    _closeTimer = Timer(const Duration(milliseconds: 300), widget.onClose);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    einkModeNotifier.removeListener(_motionChanged);
    _closeTimer?.cancel();
    _rotation.dispose();
    super.dispose();
  }

  // Officially plain click targets: no ripple, no tooltip.
  Widget _button({
    required Key key,
    required String label,
    required double width,
    required VoidCallback? onTap,
    required Widget child,
  }) => Semantics(
    key: key,
    button: true,
    enabled: onTap != null,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: _height,
        child: Center(child: ExcludeSemantics(child: child)),
      ),
    ),
  );

  Widget _capsule(BuildContext context, {double closeProgress = 0}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final eink = einkModeNotifier.value;
    // Background and cover fade linearly across the 300ms dismissal; the
    // play/close icons finish their 200ms fade earlier.
    final fade = (1 - closeProgress).clamp(0.0, 1.0);
    final controlFade =
        (1 -
                const Cubic(
                  0.25,
                  1,
                  0.25,
                  1,
                ).transform((closeProgress * 1.5).clamp(0.0, 1.0)))
            .clamp(0.0, 1.0);
    final background = eink
        ? Colors.white
        : dark
        ? const Color(0xFB4A4A4A)
        : _background;
    final ink = eink
        ? Colors.black
        : const Color(0xFFF6F6F6).withValues(alpha: dark ? 0.8 : 1);
    // Official skin_loading_book_cover_light: a flat grey cover, no glyph.
    final placeholder = ColoredBox(
      color: dark ? const Color(0xFF3A3A3A) : const Color(0xFFE8E8E8),
    );
    final cover = ClipOval(
      child: SizedBox.square(
        dimension: 42,
        child: RotationTransition(
          turns: _rotation,
          child: widget.cover.isEmpty
              ? placeholder
              : CachedNetworkImage(
                  imageUrl: widget.cover,
                  cacheManager: PosterCache.instance,
                  fit: BoxFit.cover,
                  memCacheWidth: (42 * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) => placeholder,
                  errorWidget: (_, _, _) => placeholder,
                  color: dark ? const Color(0x33000000) : null,
                  colorBlendMode: BlendMode.darken,
                ),
        ),
      ),
    );
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: background),
      // 官方用 TransitionDrawable 做 300ms 交叉淡入；夜间/墨水屏保持瞬切。
      duration: eink || dark
          ? Duration.zero
          : const Duration(milliseconds: 300),
      builder: (context, color, child) {
        final tint = color ?? background;
        return Material(
          color: tint.withValues(alpha: tint.a * fade),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: eink ? const BorderSide() : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        );
      },
      child: Row(
        children: [
          const SizedBox(width: 4),
          _button(
            key: const ValueKey('audio-floating-open'),
            label: '\u6253\u5f00\u542c\u4e66\uff1a${widget.title}',
            width: 42,
            onTap: widget.onOpen,
            child: Opacity(opacity: fade, child: cover),
          ),
          const SizedBox(width: 14),
          _button(
            key: const ValueKey('audio-floating-toggle'),
            label: widget.loading
                ? '\u6b63\u5728\u52a0\u8f7d'
                : widget.playing
                ? '\u6682\u505c\u64ad\u653e'
                : '\u7ee7\u7eed\u64ad\u653e',
            width: 32,
            // Buffering keeps the button live, as on the listening page.
            onTap: widget.canToggle ? widget.onToggle : null,
            child: SizedBox.square(
              dimension: 32,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Official LOADING keeps the icon and swaps the ring for a
                  // rotating white sweep (`fa3/a.java:48-58`). The ring frame
                  // is not faded on close (`pn2/b0.java:288-314`).
                  if (widget.loading)
                    _LoadingRing(color: ink, animate: !_reducedMotion)
                  else
                    ListenableBuilder(
                      listenable: widget.progress,
                      builder: (context, _) {
                        final value = widget.readProgress();
                        return CustomPaint(
                          size: const Size.square(32),
                          painter: _RingPainter(
                            progress: value.isFinite
                                ? value.clamp(0.0, 1.0)
                                : 0,
                            color: ink,
                          ),
                        );
                      },
                    ),
                  Opacity(
                    opacity: controlFade,
                    child: CustomPaint(
                      size: const Size.square(18),
                      painter: widget.playing
                          ? _PauseGlyph(ink)
                          : _PlayGlyph(ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          _button(
            key: const ValueKey('audio-floating-close'),
            label: '\u5173\u95ed\u64ad\u653e',
            width: 26,
            onTap: _close,
            // Official swaps `cav` for the 16dp `alh` cross in code.
            child: Opacity(
              opacity: controlFade,
              child: CustomPaint(
                size: const Size.square(16),
                painter: _CloseGlyph(ink),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        // Rest rect: 1dp inset on each side (still respecting safe areas),
        // 142dp from the top, bottom margin = 18 + bottom safe area / IME.
        final left = math.max(1.0, media.viewPadding.left);
        final right = width - math.max(1.0, media.viewPadding.right) - _width;
        final top = 142.0;
        final bottom =
            height -
            _height -
            18 -
            math.max(
              media.viewPadding.bottom + widget.bottomInset,
              media.viewInsets.bottom,
            );
        if (right < left || bottom < top) return const SizedBox.shrink();
        final rest = Offset(
          _right ? right : left,
          top + (bottom - top) * _vertical,
        );
        // While dragging the capsule may leave the rest rect: horizontally
        // -12dp..width+12dp (folding is off) and vertically the whole container.
        final dragLeft = -12.0;
        final dragRight = math.max(dragLeft, width + 12 - _width);
        final dragBottom = math.max(0.0, height - _height);
        Offset dragBounded(Offset value) => Offset(
          value.dx.clamp(dragLeft, dragRight),
          value.dy.clamp(0.0, dragBottom),
        );
        final position = _drag == null ? rest : dragBounded(_drag!);
        void snap() {
          final released = _drag ?? position;
          setState(() {
            _right = released.dx + _width / 2 >= width / 2;
            _vertical = bottom == top
                ? 1
                : ((released.dy - top) / (bottom - top)).clamp(0.0, 1.0);
            _drag = null;
          });
        }

        return Visibility(
          visible: widget.visible,
          maintainState: true,
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: _drag != null || _reducedMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: const Cubic(0.445, 0.05, 0.55, 0.95),
                left: position.dx,
                top: position.dy,
                width: _width,
                height: _height,
                child: IgnorePointer(
                  ignoring: _closing,
                  child: GestureDetector(
                    onPanStart: (_) => setState(() => _drag = position),
                    onPanUpdate: (details) => setState(() {
                      _drag = dragBounded((_drag ?? position) + details.delta);
                    }),
                    onPanEnd: (_) => snap(),
                    onPanCancel: snap,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: _closing ? 1 : 0),
                      duration: const Duration(milliseconds: 300),
                      builder: (context, value, child) {
                        final shrink = const Cubic(
                          0.25,
                          0.1,
                          0.25,
                          1.0,
                        ).transform(value);
                        // The dismissal shrink is always anchored to the left.
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              widthFactor: 1 - shrink * (_width - 74) / _width,
                              child: RepaintBoundary(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: _capsule(
                                    context,
                                    closeProgress: value,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Official `fa3/a`: 2.5dp track (#33 white) and clockwise progress (#E5)
/// from 12 o'clock. Ours tints with the capsule's ink so e-ink stays black.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  static const _stroke = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      0,
      0,
      size.width,
      size.height,
    ).deflate(_stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    canvas.drawOval(rect, paint..color = color.withValues(alpha: 0.2));
    if (progress <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      paint..color = color.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

/// Official loading ring: a transparent-to-opaque sweep turning 4°/frame.
class _LoadingRing extends StatefulWidget {
  const _LoadingRing({required this.color, required this.animate});

  final Color color;
  final bool animate;

  @override
  State<_LoadingRing> createState() => _LoadingRingState();
}

class _LoadingRingState extends State<_LoadingRing>
    with SingleTickerProviderStateMixin {
  // 4° per 60Hz frame is one turn in 1.5s.
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_LoadingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.animate) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _spin,
    child: CustomPaint(
      size: const Size.square(32),
      painter: _SweepPainter(widget.color),
    ),
  );
}

class _SweepPainter extends CustomPainter {
  const _SweepPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(1.25);
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..shader = SweepGradient(
          colors: [color.withValues(alpha: 0), color],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.color != color;
}

/// Official `csw`: a filled, slightly rounded right-pointing triangle.
class _PlayGlyph extends CustomPainter {
  const _PlayGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.30, h * 0.18)
      ..lineTo(w * 0.82, h * 0.50)
      ..lineTo(w * 0.30, h * 0.82)
      ..close();
    final paint = Paint()
      ..color = color
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = w * 0.08;
    // Fill, then a round-joined stroke to soften the corners.
    canvas.drawPath(path, paint);
    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_PlayGlyph old) => old.color != color;
}

/// Official `cax`: two rounded vertical bars.
class _PauseGlyph extends CustomPainter {
  const _PauseGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..color = color;
    final radius = Radius.circular(w * 0.06);
    for (final left in [w * 0.26, w * 0.60]) {
      canvas.drawRRect(
        RRect.fromLTRBR(left, h * 0.20, left + w * 0.14, h * 0.80, radius),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PauseGlyph old) => old.color != color;
}

/// Official `alh`: a thin round-capped cross.
class _CloseGlyph extends CustomPainter {
  const _CloseGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = color
      ..strokeWidth = w * 0.1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * 0.25, h * 0.25),
      Offset(w * 0.75, h * 0.75),
      paint,
    );
    canvas.drawLine(
      Offset(w * 0.75, h * 0.25),
      Offset(w * 0.25, h * 0.75),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CloseGlyph old) => old.color != color;
}
