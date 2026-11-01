import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'shelf_design.dart';

// 三种空态共用同一套尺度：图标砖 20dp 内边距 + 48dp 图标、标题 16sp w600、
// 说明 13sp，间距 18 / 6。此前分别是 20/20/16 内边距、48/48/36 图标和
// 16/14 字号，放在同一条 tab 里切换时会跳。
const double _emptyIconPadding = 20;
const double _emptyIconSize = 48;
const double _emptyTitleSize = 16;
const double _emptyMessageSize = 13;
const double _emptyIconGap = 18;
const double _emptyMessageGap = 6;

const _emptyTitleStyle = TextStyle(
  fontSize: _emptyTitleSize,
  fontWeight: FontWeight.w600,
);

TextStyle _mutedMessage(HomePalette palette) =>
    TextStyle(fontSize: _emptyMessageSize, color: palette.muted);

Widget _iconBrick(HomePalette palette, IconData icon) => Container(
  padding: const EdgeInsets.all(_emptyIconPadding),
  decoration: BoxDecoration(
    color: palette.soft,
    borderRadius: BorderRadius.circular(ShelfTokens.radiusCard),
  ),
  child: Icon(
    icon,
    size: _emptyIconSize,
    // 墨水屏退化为纯黑：图标是这屏唯一的视觉锚点，灰阶容易糊成一片。
    color: palette.eink ? Colors.black : palette.muted.withValues(alpha: 0.65),
  ),
);

ButtonStyle _filledActionStyle(HomePalette palette) => FilledButton.styleFrom(
  backgroundColor: palette.eink ? palette.ink : HomePalette.accent,
  foregroundColor: palette.eink ? palette.canvas : Colors.white,
  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
);

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
            _iconBrick(palette, LucideIcons.book_open),
            const SizedBox(height: _emptyIconGap),
            Text(
              '书架暂无书籍',
              style: _emptyTitleStyle.copyWith(color: palette.ink),
            ),
            const SizedBox(height: _emptyMessageGap),
            Text('去书城发现海量故事，随时随地畅读', style: _mutedMessage(palette)),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('shelf-browse-button'),
              onPressed: onBrowse,
              icon: const Icon(LucideIcons.compass, size: 16),
              label: const Text('去书城找书'),
              style: _filledActionStyle(palette),
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
            _iconBrick(palette, LucideIcons.clapperboard),
            const SizedBox(height: _emptyIconGap),
            Text(text, style: _emptyTitleStyle.copyWith(color: palette.ink)),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('collection-find-drama-button'),
              onPressed: onFindDrama,
              style: _filledActionStyle(palette),
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
            _iconBrick(palette, LucideIcons.search_x),
            const SizedBox(height: _emptyIconGap),
            Text(text, style: _emptyTitleStyle.copyWith(color: palette.ink)),
          ],
        ),
      ),
    );
  }
}
