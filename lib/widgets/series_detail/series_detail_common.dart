import 'package:flutter/material.dart';

import '../home/home_design.dart';
import '../home/home_archive.dart';

/// Series details share archive headings with book details.
class SeriesSectionHeader extends StatelessWidget {
  const SeriesSectionHeader({
    super.key,
    required this.code,
    required this.title,
    this.action,
  });

  final String code;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => HomeSectionLabel(
    code: code,
    title: title,
    action: action,
    gutter: 0,
    bottomGap: 10,
  );
}

/// The heading owns top spacing; sections own only outer gutters.
class SeriesSection extends StatelessWidget {
  const SeriesSection({super.key, required this.child, this.bottom = 0});

  final Widget child;
  final double bottom;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, bottom), child: child);
}

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
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(action),
        ),
      ],
    );
  }
}
