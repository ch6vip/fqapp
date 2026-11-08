import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// Empty, error and loading presentations restored from f329399.

/// A loaded feed that ended up empty.
class ClassicHomeFeedEmpty extends StatelessWidget {
  final String title;
  final String message;
  final String actionLabel;
  final IconData icon;
  final Future<void> Function() onRefresh;

  const ClassicHomeFeedEmpty({
    super.key,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onRefresh,
    this.icon = LucideIcons.compass,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 28, color: palette.muted),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(LucideIcons.rotate_ccw, size: 16),
            label: Text(actionLabel),
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.accentText,
            ),
          ),
        ],
      ),
    );
  }
}

/// A failed first page. It renders inside the page's own scroll view now (the
/// search row and category strip stay above it), so the message itself no
/// longer needs a `SingleChildScrollView`; a long upstream message simply
/// extends the feed and scrolls with it.
class ClassicHomeFeedError extends StatelessWidget {
  final String headline;
  final String message;
  final String detail;
  final Future<void> Function() onRetry;

  const ClassicHomeFeedError({
    super.key,
    required this.headline,
    required this.message,
    required this.detail,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              LucideIcons.cloud_off,
              size: 30,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            headline,
            style: TextStyle(
              fontSize: 30,
              height: 1.2,
              fontWeight: FontWeight.w800,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(color: palette.muted, fontSize: 14, height: 1.6),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              detail,
              style: TextStyle(fontSize: 12, height: 1.6, color: palette.muted),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(LucideIcons.rotate_ccw, size: 16),
            label: const Text('重试'),
            style: FilledButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: HomePalette.accentStrong,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 切分类时的占位。
///
/// 冷启动首载铺 `HomeSkeleton`（官方 `alx.xml` 的 `SkeletonLayout`），但横滑
/// 切到一个还没进过的分类时，满屏脉冲骨架会被读成「整页重新加载了」——搜
/// 索行和分类条也会跟着回来。这里对齐短剧页切频道的观感：一段安静的提示，
/// 顶栏、分类条、滚动位置都留在原地。
class ClassicHomeFeedLoading extends StatelessWidget {
  const ClassicHomeFeedLoading({super.key, this.message = '正在刷新内容'});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.muted,
            ),
          ),
          const SizedBox(width: 10),
          Text(message, style: TextStyle(fontSize: 13, color: palette.muted)),
        ],
      ),
    );
  }
}
