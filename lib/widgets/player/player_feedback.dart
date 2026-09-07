import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/playback_issue.dart';

class PlayerErrorFeedback extends StatelessWidget {
  final PlaybackIssue issue;
  final VoidCallback? onRetry;

  const PlayerErrorFeedback({super.key, required this.issue, this.onRetry});

  @override
  Widget build(BuildContext context) => _FeedbackCard(
    title: issue.title,
    message: issue.message,
    leading: const Icon(Icons.error_outline, color: Colors.white70, size: 24),
    onRetry: onRetry,
  );
}

/// A single foreground wait across address lookup, native creation and the
/// first frame. The page keys this by load attempt and removes it when ready.
/// Later buffering mounts a new instance while the existing texture stays put.
class PlayerLoadingFeedback extends StatefulWidget {
  final String? label;
  final VoidCallback onRetry;

  const PlayerLoadingFeedback({super.key, this.label, required this.onRetry});

  @override
  State<PlayerLoadingFeedback> createState() => _PlayerLoadingFeedbackState();
}

class _PlayerLoadingFeedbackState extends State<PlayerLoadingFeedback>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _slow = false;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    if (!_foreground) return;
    _timer = Timer(const Duration(seconds: 8), () {
      if (mounted && _foreground) setState(() => _slow = true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (_slow) setState(() => _slow = false);
    if (state == AppLifecycleState.resumed) _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const progress = SizedBox.square(
      dimension: 24,
      child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
    );
    if (_slow) {
      return _FeedbackCard(
        title: widget.label == null ? '缓冲较慢' : '加载较慢',
        message: '网络或视频响应较慢，可以继续等待，或检查网络后重试。',
        leading: progress,
        onRetry: widget.onRetry,
      );
    }
    return IgnorePointer(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              progress,
              if (widget.label != null) ...[
                const SizedBox(height: 16),
                Text(
                  widget.label!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FeedbackCard extends StatelessWidget {
  final String title;
  final String message;
  final Widget leading;
  final VoidCallback? onRetry;

  const _FeedbackCard({
    required this.title,
    required this.message,
    required this.leading,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final retryButton = onRetry == null
          ? null
          : OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              onPressed: onRetry,
              child: const Text('重试'),
            );
      // An expanded description panel can leave only a narrow video strip.
      // Keep the action reachable without overflowing or enlarging the video.
      if (constraints.maxWidth < 140 || constraints.maxHeight < 96) {
        return Center(
          child: Tooltip(
            message: '$title\n$message',
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child:
                  retryButton ??
                  Text(title, style: const TextStyle(color: Colors.white70)),
            ),
          ),
        );
      }
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xCC16161A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        leading,
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    if (retryButton != null) ...[
                      const SizedBox(height: 8),
                      retryButton,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
