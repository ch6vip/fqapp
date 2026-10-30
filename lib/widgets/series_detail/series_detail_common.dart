import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 区块骨架屏：两行灰条，等宽 + 定宽。
class SeriesDetailSkeleton extends StatelessWidget {
  const SeriesDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    Widget bar(double? width) => SizedBox(
      height: 14,
      width: width ?? double.infinity,
      child: ColoredBox(color: palette.soft),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [bar(null), const SizedBox(height: 10), bar(180)],
      ),
    );
  }
}

/// 区块内联重试：「加载失败」+ 文字按钮，失败只影响本区块。
class SeriesRetryInline extends StatelessWidget {
  const SeriesRetryInline({
    super.key,
    required this.message,
    required this.onRetry,
    this.action = '重试',
    this.actionKey,
  });

  final String message;
  final VoidCallback onRetry;
  final String action;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(message, style: TextStyle(fontSize: 13, color: palette.muted)),
        TextButton(
          key: actionKey,
          onPressed: onRetry,
          style: TextButton.styleFrom(
            foregroundColor: palette.accentText,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(action),
        ),
      ],
    );
  }
}
