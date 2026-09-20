import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// The three states a recommendation feed can be in when it has no cards to
/// show. They were private to [HomePage] until the 短剧 destination needed the
/// same three; the copy is a parameter because "换个分类" is advice the home
/// page can give and a channel-locked page cannot.

/// A first page that has not arrived yet.
class HomeFeedLoading extends StatelessWidget {
  final String message;

  const HomeFeedLoading({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      height: 270,
      margin: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(height: 18),
          Text(message, style: TextStyle(fontSize: 13, color: palette.muted)),
        ],
      ),
    );
  }
}

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
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: palette.soft,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 32, color: HomePalette.accent),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: TextStyle(
              fontSize: 22,
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

/// A failed first page. Long upstream messages stay scrollable all the way to
/// the retry action.
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
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

/// The end of a feed that has no next page.
class HomeEndOfFeed extends StatelessWidget {
  final String message;

  const HomeEndOfFeed({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Row(
        children: [
          Expanded(child: Divider(color: palette.line)),
          Flexible(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: palette.muted),
              ),
            ),
          ),
          Expanded(child: Divider(color: palette.line)),
        ],
      ),
    );
  }
}
