import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_archive.dart';
import 'home_design.dart';

/// 紧凑版空 / 错态：图标砖 + 标题 + 说明 + 可选动作。
///
/// 与 [HomeFeedEmpty] / [HomeFeedError] 的整页大态区分：这个版本放在列表
/// 末尾、卡片内或弹层里都合适，自身不撑满高度。
///
/// [scrollable] 为 true 时按 [alignment] 定位（默认居中）并可垂直滚动，
/// 用于替页面承担滚动：内容区夹在 tab / chip 下面、高度有限时，窄屏大字号
/// 下的动作按钮仍可达。之前榜单、缓存、日志、漫画和书评弹层各包了一层
/// `Center(SingleChildScrollView(...))`，统一收敛到这里。
class HomeStateView extends StatelessWidget {
  const HomeStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
    this.scrollable = false,
    // Full-page notices can lift their block above the geometric center; the
    // page header already occupies the top, so a plain center reads low.
    this.alignment = Alignment.center,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? actionIcon;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final actionLabel = this.actionLabel;
    final actionIcon = this.actionIcon;
    final content = Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(homePanelRadius),
              border: Border.all(color: palette.line),
            ),
            child: Icon(icon, size: 22, color: palette.accentText),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.3,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.5, color: palette.muted),
            ),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 14),
            _action(palette, actionLabel, actionIcon),
          ],
        ],
      ),
    );
    if (!scrollable) return content;
    return Align(
      alignment: alignment,
      child: SingleChildScrollView(child: content),
    );
  }

  Widget _action(HomePalette palette, String label, IconData? icon) {
    final style = TextButton.styleFrom(
      foregroundColor: palette.accentText,
      minimumSize: const Size(48, 44),
      padding: const EdgeInsets.symmetric(horizontal: 16),
    );
    if (icon == null) {
      return TextButton(onPressed: onAction, style: style, child: Text(label));
    }
    return TextButton.icon(
      onPressed: onAction,
      style: style,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}

/// The two states a recommendation feed can be in when it has no cards to
/// show. They were private to [HomePage] until the 短剧 destination needed the
/// same two; the copy is a parameter because "换个分类" is advice the home
/// page can give and a channel-locked page cannot.

/// A loaded feed that ended up empty.
class HomeFeedEmpty extends StatelessWidget {
  final String title;
  final String message;
  final String actionLabel;
  final IconData icon;
  final Future<void> Function() onRefresh;

  const HomeFeedEmpty({
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
class HomeFeedError extends StatelessWidget {
  final String headline;
  final String message;
  final String detail;
  final Future<void> Function() onRetry;

  const HomeFeedError({
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
              borderRadius: BorderRadius.circular(homePanelRadius),
              border: Border.all(color: palette.line),
            ),
            child: const Icon(
              LucideIcons.cloud_off,
              size: 30,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(height: 24),
          HomeCode('ERR / FEED', size: 9, color: palette.muted),
          const SizedBox(height: 10),
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
              borderRadius: BorderRadius.circular(homePanelRadius),
              border: Border.all(color: palette.line),
            ),
            child: Text(
              detail,
              style: homeCodeStyle(
                palette,
                size: 11,
                color: palette.muted,
              ).copyWith(height: 1.6),
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
                borderRadius: BorderRadius.circular(homePanelRadius),
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
class HomeFeedLoading extends StatelessWidget {
  const HomeFeedLoading({super.key, this.message = '正在刷新内容'});

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
