import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/app_style_tokens.dart';
import '../../services/library_store.dart';
import '../../services/media_history_store.dart';
import 'classic_home_continue_row.dart';
import 'home_archive.dart';
import 'home_design.dart';

// 「继续阅读」——推荐页顶上的一张档案条，不是卡片。
//
// 用户 2026-10-30 拍板首屏密度优先、主视觉大图整个去掉；2026-11 重做时
// 这条保留，只是换成档案版式：等宽编号行 + 书名 + 2dp 进度线 + 百分比。

/// 阅读史里的「在读」一本书，这一条要用的文案在这里一次算好。
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
    final value = ((entry['progress'] as num?)?.toDouble() ?? 0.0).clamp(
      0.0,
      1.0,
    );
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
/// 的短剧不会顶掉这一条——直接跳过，取下一本书。
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

/// 一张档案条：编号行（`CONTINUE / 读到 第32章`）、书名 + 作者、进度线、
/// 右端百分比与关闭。
///
/// 右端的关闭只关掉「这一本」：点它不再显示这一条，换书后重新出现。
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
    final tokens = AppStyleTokens.of(context);
    if (tokens.isClassic) {
      return ClassicHomeContinueRow(
        now: now,
        onOpen: onOpen,
        onDismiss: onDismiss,
      );
    }
    final panelRadius = BorderRadius.circular(tokens.panelRadius);
    final percent = (now.progress * 100).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: panelRadius,
          border: palette.eink
              ? Border.all(color: palette.ink, width: 1)
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: HomePressable(
                onTap: onOpen,
                borderRadius: panelRadius,
                semanticLabel: '${now.verb} ${now.item.title}',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tokens.showDecorativeCodes)
                        HomeCode('CONTINUE / ${now.detail}')
                      else
                        Text(
                          '${now.verb} · ${now.detail}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.25,
                            color: palette.muted,
                          ),
                        ),
                      const SizedBox(height: 5),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Flexible(
                            child: Text(
                              now.item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.25,
                                fontWeight: FontWeight.w700,
                                color: palette.ink,
                              ),
                            ),
                          ),
                          if (now.item.author.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                now.item.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.25,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 9),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(1),
                        child: LinearProgressIndicator(
                          value: now.progress,
                          minHeight: 2,
                          backgroundColor: palette.line,
                          valueColor: AlwaysStoppedAnimation(palette.mark),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (percent > 0)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  '$percent%',
                  style: homeCodeStyle(palette, size: 12, color: palette.ink)
                      .copyWith(
                        letterSpacing: 0,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ),
            // 32dp 命中区：图标只有 15dp，但点在图标周围也算。
            GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 34,
                height: 44,
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
