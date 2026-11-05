import 'package:flutter/material.dart';

import '../home/home_design.dart';
import '../wenku/wenku_ui.dart';

/// 短剧详情里统一的区块头：上游 `ArchiveSection` 的档案标题（编号 + 分隔线 +
/// 标题）右侧接一个动作。
///
/// 版式稿原本是「15sp 标题 + 右端 12sp 动作」；移植到详情页这套共享组件后，
/// 编号行由 [ArchiveSection] 提供，标题升级为档案标题 18sp。动作仍然是
/// 12sp 灰字并保持与标题同一基线、右端贴栏距，行为与既有测试不变。
class SeriesSectionHeader extends StatelessWidget {
  const SeriesSectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  static String _codeFor(String title) {
    if (title.startsWith('剧评')) return '03 / REVIEWS';
    return switch (title) {
      '简介' => '01 / SYNOPSIS',
      '选集' => '02 / EPISODES',
      '原著小说' => '04 / ORIGINAL',
      _ => '01 / CATALOG',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: ArchiveSection(title: title, code: _codeFor(title)),
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
