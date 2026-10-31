import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// 紧凑版空 / 错态：图标砖 + 标题 + 说明 + 可选动作。
///
/// 与 [HomeFeedEmpty] / [HomeFeedError] 的整页大态区分：这个版本放在列表
/// 末尾、卡片内或弹层里都合适，自身不撑满高度、不做滚动。
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
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? actionIcon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final actionLabel = this.actionLabel;
    final actionIcon = this.actionIcon;
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(14),
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
