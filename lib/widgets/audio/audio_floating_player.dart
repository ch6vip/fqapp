import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
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
    required this.position,
    required this.duration,
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
  final ValueListenable<Duration> position;
  final Duration duration;
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
    final color = await fetchCoverDominant(cover);
    if (!mounted || widget.cover != cover) return;
    setState(() {
      _background = color == null
          ? const Color(0xFC666666)
          : HSVColor.fromAHSV(
              252 / 255,
              HSVColor.fromColor(color).hue,
              0.23,
              0.54,
            ).toColor();
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

  Widget _button({
    required String label,
    required double width,
    required VoidCallback? onTap,
    required Widget child,
  }) => SizedBox(
    width: width,
    height: _height,
    child: IconButton(
      tooltip: label,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: child,
    ),
  );

  Widget _capsule(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final eink = einkModeNotifier.value;
    final ink = eink
        ? Colors.black
        : const Color(0xFFF6F6F6).withValues(alpha: dark ? 0.8 : 1);
    final placeholder = ColoredBox(
      color: Colors.white24,
      child: Center(child: Icon(Icons.headphones, size: 22, color: ink)),
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
    return Material(
      color: eink
          ? Colors.white
          : dark
          ? const Color(0xFB4A4A4A)
          : _background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: eink ? const BorderSide() : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          const SizedBox(width: 4),
          _button(
            label: '\u6253\u5f00\u542c\u4e66\uff1a${widget.title}',
            width: 42,
            onTap: widget.onOpen,
            child: cover,
          ),
          const SizedBox(width: 14),
          _button(
            label: widget.loading
                ? '\u6b63\u5728\u52a0\u8f7d'
                : widget.playing
                ? '\u6682\u505c\u64ad\u653e'
                : '\u7ee7\u7eed\u64ad\u653e',
            width: 32,
            onTap: widget.canToggle && !widget.loading ? widget.onToggle : null,
            child: SizedBox.square(
              dimension: 32,
              child: ValueListenableBuilder<Duration>(
                valueListenable: widget.position,
                builder: (context, position, _) {
                  final duration = widget.duration.inMilliseconds;
                  final progress = duration <= 0
                      ? 0.0
                      : (position.inMilliseconds / duration).clamp(0.0, 1.0);
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: widget.loading && !_reducedMotion
                              ? null
                              : progress,
                          strokeWidth: 2.5,
                          trackGap: 0,
                          color: ink,
                          backgroundColor: ink.withValues(alpha: 0.18),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      if (!widget.loading)
                        Icon(
                          widget.playing ? Icons.pause : Icons.play_arrow,
                          color: ink,
                          size: 18,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 10),
          _button(
            label: '\u5173\u95ed\u64ad\u653e',
            width: 26,
            onTap: _close,
            child: Icon(Icons.close, size: 18, color: ink),
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
        final left = media.viewPadding.left;
        final right = constraints.maxWidth - media.viewPadding.right - _width;
        final top = media.viewPadding.top + 46;
        final bottom =
            constraints.maxHeight -
            _height -
            18 -
            math.max(
              media.viewPadding.bottom + widget.bottomInset,
              media.viewInsets.bottom,
            );
        if (right < left || bottom < top) return const SizedBox.shrink();
        Offset bounded(Offset value) =>
            Offset(value.dx.clamp(left, right), value.dy.clamp(top, bottom));
        final position = bounded(
          _drag ??
              Offset(_right ? right : left, top + (bottom - top) * _vertical),
        );
        void snap() {
          setState(() {
            final target = bounded(_drag ?? position);
            _right = target.dx >= (left + right) / 2;
            _vertical = bottom == top ? 1 : (target.dy - top) / (bottom - top);
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
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                left: position.dx,
                top: position.dy,
                width: _width,
                height: _height,
                child: IgnorePointer(
                  ignoring: _closing,
                  child: GestureDetector(
                    onPanStart: (_) => setState(() => _drag = position),
                    onPanUpdate: (details) => setState(() {
                      _drag = bounded((_drag ?? position) + details.delta);
                    }),
                    onPanEnd: (_) => snap(),
                    onPanCancel: snap,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: _closing ? 1 : 0),
                      duration: const Duration(milliseconds: 300),
                      builder: (context, value, child) => Align(
                        alignment: _right
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: ClipRect(
                          child: Align(
                            alignment: _right
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            widthFactor: 1 - value * 88 / _width,
                            child: Opacity(opacity: 1 - value, child: child),
                          ),
                        ),
                      ),
                      child: RepaintBoundary(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: _capsule(context),
                        ),
                      ),
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
