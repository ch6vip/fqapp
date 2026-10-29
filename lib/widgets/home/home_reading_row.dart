import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/library_store.dart';
import '../../services/media_history_store.dart';
import 'home_design.dart';
import 'home_shelf.dart';

// 「继续阅读」——推荐页顶上的一行字，不是一张卡。
//
// 用户 2026-10-30 拍板：首屏密度优先，主视觉大图整个去掉。这一行只回答
// 「接着看哪本、看到哪」，点一下直接续读；没有阅读史时整行消失。

/// 阅读史里的「在读」一本书，主视觉那一行要用的文案在这里一次算好。
class ReadingNow {
  final MediaItem item;

  /// 「继续阅读」/「继续收听」。
  final String verb;

  /// 「读到 第32章」/「已读 78%」/「上次阅读」。
  final String detail;

  final double progress;

  const ReadingNow({
    required this.item,
    required this.verb,
    required this.detail,
    required this.progress,
  });

  factory ReadingNow.fromHistory(Map<String, dynamic> entry) {
    final audio = entry['kind']?.toString() == 'audio';
    final value =
        ((entry['progress'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0);
    final chapter =
        (entry['lastChapterTitle'] ?? entry['chapterTitle'])?.toString() ?? '';
    final String detail;
    if (chapter.isNotEmpty) {
      detail = '${audio ? '听到' : '读到'} $chapter';
    } else if (value > 0) {
      detail = '${audio ? '已听' : '已读'} ${(value * 100).toInt()}%';
    } else {
      detail = audio ? '上次收听' : '上次阅读';
    }
    return ReadingNow(
      item: MediaItem(
        id: historyContentId(entry),
        title: entry['title']?.toString() ?? '未知作品',
        cover: entry['cover']?.toString() ?? '',
        author: entry['author']?.toString() ?? '',
        badge: '',
        ep: entry['ep']?.toString() ?? '',
        kind: entry['kind']?.toString() ?? 'book',
        seriesId: entry['seriesId']?.toString(),
        episodeId: entry['episodeId']?.toString(),
      ),
      verb: audio ? '继续收听' : '继续阅读',
      detail: detail,
      progress: value,
    );
  }
}

/// The most recent book (or audiobook) in history. 推荐页以书为主，最近看过
/// 的短剧不会顶掉这一行——直接跳过，取下一本书。
Map<String, dynamic>? latestHistoryBook() {
  final store = LibraryStore.instance;
  if (!store.isInitialized) return null;
  for (final entry in store.historySnapshot()) {
    final kind = entry['kind']?.toString() ?? 'book';
    if (kind == 'book' || kind == 'audio') return entry;
  }
  return null;
}

/// The book to put on the continue row, or null when there is none.
ReadingNow? latestReadingNow() {
  final entry = latestHistoryBook();
  return entry == null ? null : ReadingNow.fromHistory(entry);
}

/// 一行：动作 + 书名 · 章节 + 百分比 + 关闭。没有卡面、没有封面、没有阴影。
///
/// 右端的关闭只关掉「这一本」：点它不再显示这一行，换书后重新出现。
class HomeContinueRow extends StatelessWidget {
  final ReadingNow now;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const HomeContinueRow({
    super.key,
    required this.now,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final percent = (now.progress * 100).round();
    return HomePressable(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(10),
      semanticLabel: '${now.verb} ${now.item.title}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(homeGutter, 10, homeGutter - 6, 2),
        child: Row(
          children: [
            Text(
              now.verb,
              maxLines: 1,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: palette.accentText,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${now.item.title} · ${now.detail}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            if (percent > 0) ...[
              const SizedBox(width: 8),
              Text(
                '$percent%',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: palette.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            const SizedBox(width: 2),
            // 32dp 命中区：图标只有 15dp，但点在图标周围也算。
            GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 32,
                height: 32,
                child: Icon(
                  LucideIcons.x,
                  size: 15,
                  color: palette.muted,
                  semanticLabel: '隐藏继续阅读',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
