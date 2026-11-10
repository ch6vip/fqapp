import 'package:flutter/material.dart';

import '../app_ui/app_ui_scope.dart';
import '../home/home_design.dart';
import '../wenku/wenku_ui.dart';

/// 短剧详情里统一的区块头：经典主题回到版式稿的「15sp 标题 + 右端 12sp
/// 动作」；档案主题沿用上游 `ArchiveSection` 的编号、分隔线与 18sp 标题。
///
/// 两种分支都保留同一套动作和基线，行为与既有测试不变。
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
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: AppUiScope.isClassic(context)
                ? Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      // 版式稿渲染出的 `.sh` 行盒是 24（浏览器按字体度量把
                      // 15sp 撑到 1.6 倍），不是名义上的 1.5。
                      height: 1.6,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  )
                : ArchiveSection(title: title, code: _codeFor(title)),
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
