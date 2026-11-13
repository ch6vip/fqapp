import 'package:flutter/material.dart';

/// A short reader notice. It stays out of the gesture arena and sizes to text,
/// so it never becomes a full-width snackbar or obscures the bottom controls.
class ReaderToast extends StatefulWidget {
  const ReaderToast({
    super.key,
    required this.message,
    this.reduceMotion = false,
    this.immediateDismiss = false,
  });

  final String? message;
  final bool reduceMotion;
  final bool immediateDismiss;

  @override
  State<ReaderToast> createState() => _ReaderToastState();
}

class _ReaderToastState extends State<ReaderToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 160),
        reverseDuration: const Duration(milliseconds: 200),
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed &&
            widget.message == null &&
            mounted) {
          setState(() => _displayedMessage = null);
        }
      });
  String? _displayedMessage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateVisibility();
  }

  @override
  void didUpdateWidget(ReaderToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateVisibility();
  }

  void _updateVisibility() {
    final instant =
        widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    if (widget.message case final String message) {
      _displayedMessage = message;
      if (instant) {
        _opacity.value = 1;
      } else {
        _opacity.forward();
      }
    } else if (instant || widget.immediateDismiss) {
      _displayedMessage = null;
      _opacity.value = 0;
    } else {
      _opacity.reverse();
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = _displayedMessage;
    if (message == null) return const SizedBox.shrink();
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final top = (size.height * .15).clamp(
      padding.top + 16,
      (size.height - padding.bottom - 64).clamp(
        padding.top + 16,
        double.infinity,
      ),
    );
    return Positioned(
      top: top,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.topCenter,
          child: FadeTransition(
            key: const ValueKey('reader-toast-fade'),
            opacity: _opacity,
            child: ExcludeSemantics(
              excluding: widget.message == null,
              child: Semantics(
                container: true,
                liveRegion: true,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Material(
                    key: const ValueKey('reader-toast'),
                    color: const Color(0xFF424242),
                    borderRadius: BorderRadius.circular(48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
