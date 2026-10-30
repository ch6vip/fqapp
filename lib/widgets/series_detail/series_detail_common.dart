import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 短剧详情里统一的区块头：标题 15sp 粗体，右侧动作 12sp 灰字。
///
/// 版式稿的 `.sh` 是「15sp 标题 + 右端 12sp 动作」，与首页 19sp 的分区头
/// 不是同一套，所以这里不复用 `HomeSectionHeader`。
class SeriesSectionHeader extends StatelessWidget {
  const SeriesSectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                height: 1.4,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

/// 区块外距：左右 16、上 20（版式稿 `.sec`）。
class SeriesSection extends StatelessWidget {
  const SeriesSection({super.key, required this.child, this.bottom = 0});

  final Widget child;
  final double bottom;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(16, 20, 16, bottom), child: child);
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
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(action),
        ),
      ],
    );
  }
}
