import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'shelf_design.dart';

/// 空书架（官方文案延续）：书架暂无书籍 + 去书城找书。
///
/// [onCachedBooks] 非空时多给一条「查看离线缓存」：书架空、又断网时
/// 「去书城找书」是条死路，而用户手里可能正好有下载好的内容。
class ShelfEmptyState extends StatelessWidget {
  final VoidCallback? onBrowse;
  final VoidCallback? onCachedBooks;

  const ShelfEmptyState({super.key, this.onBrowse, this.onCachedBooks});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: HomeEntrance(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(ShelfTokens.radiusCard),
              ),
              child: Icon(
                LucideIcons.book_open,
                size: 48,
                color: palette.muted.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '书架暂无书籍',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '去书城发现海量故事，随时随地畅读',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('shelf-browse-button'),
              onPressed: onBrowse,
              icon: const Icon(LucideIcons.compass, size: 16),
              label: const Text('去书城找书'),
              style: FilledButton.styleFrom(
                backgroundColor: HomePalette.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
            if (onCachedBooks != null) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                key: const Key('shelf-cached-books-button'),
                onPressed: onCachedBooks,
                style: TextButton.styleFrom(foregroundColor: palette.muted),
                icon: const Icon(LucideIcons.download, size: 16),
                label: const Text('查看离线缓存'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 收藏 tab 空态（官方收藏页形态）：文案随筛选变化（暂无短剧 / 暂无
/// 漫剧 / 暂无收藏内容），下方给「找短剧」入口切到短剧 tab。
class ShelfCollectionEmptyState extends StatelessWidget {
  final String text;
  final VoidCallback? onFindDrama;

  const ShelfCollectionEmptyState({
    super.key,
    required this.text,
    this.onFindDrama,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: HomeEntrance(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(ShelfTokens.radiusCard),
              ),
              child: Icon(
                LucideIcons.clapperboard,
                size: 48,
                color: palette.muted.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 18),
            Text(text, style: TextStyle(fontSize: 14, color: palette.muted)),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('collection-find-drama-button'),
              onPressed: onFindDrama,
              style: FilledButton.styleFrom(
                backgroundColor: HomePalette.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: const Text('找短剧'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 官方通用空态文案（RecyclerBookLayoutV2）：空历史 / 筛选无结果。
class ShelfEmptyHint extends StatelessWidget {
  final String text;

  const ShelfEmptyHint({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: HomeEntrance(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(ShelfTokens.radiusCard),
              ),
              child: Icon(
                LucideIcons.search_x,
                size: 36,
                color: palette.muted.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 14),
            Text(text, style: TextStyle(fontSize: 14, color: palette.muted)),
          ],
        ),
      ),
    );
  }
}
