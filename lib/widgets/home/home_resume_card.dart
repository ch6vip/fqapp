import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/library_store.dart';
import '../../services/media_history_store.dart';
import '../../services/progress_format.dart';
import 'home_design.dart';
import 'home_media_card.dart';

/// A compact continuation strip.
///
/// It keeps the identity of the last item (cover + title + where you stopped)
/// while dropping the former badge stack, circular action button and nested
/// progress card. The whole strip remains one large tap target.
class HomeResumeCard extends StatelessWidget {
  final ValueChanged<MediaItem> onOpen;

  const HomeResumeCard({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (!LibraryStore.instance.isInitialized) return const SizedBox.shrink();
    return ValueListenableBuilder<dynamic>(
      valueListenable: LibraryStore.instance.historyListenable,
      builder: (context, _, _) {
        final history = LibraryStore.instance.historySnapshot();
        if (history.isEmpty) return const SizedBox.shrink();

        final latest = history.first;
        final title = latest['title']?.toString() ?? '未知作品';
        final kind = latest['kind']?.toString() ?? 'book';
        final cover = latest['cover']?.toString() ?? '';
        final author = latest['author']?.toString() ?? '';
        final ep = latest['ep']?.toString() ?? '';
        final chapterTitle =
            (latest['lastChapterTitle'] ?? latest['chapterTitle'])
                ?.toString() ??
            '';
        final episode = (latest['episode'] as num?)?.toInt() ?? 0;
        final progress = ((latest['progress'] as num?)?.toDouble() ?? 0.0)
            .clamp(0.0, 1.0);

        final item = MediaItem(
          id: historyContentId(latest),
          title: title,
          cover: cover,
          author: author,
          badge: '',
          ep: ep,
          kind: kind,
          seriesId: latest['seriesId']?.toString(),
          episodeId: latest['episodeId']?.toString(),
        );

        final actionVerb = switch (kind) {
          'video' => '继续追剧',
          'manju' => '继续观看',
          'audio' => '继续收听',
          'manga' => '继续看漫',
          _ => '继续阅读',
        };

        final progressText = switch (kind) {
          'video' || 'manju' => episode > 0 ? '看到第 $episode 集' : '正在追看',
          'audio' => episode > 0 ? '听至第 $episode 集' : '最近收听',
          _ =>
            chapterTitle.isNotEmpty
                ? '读至 $chapterTitle'
                : (progress > 0
                      ? '已读 ${formatProgressPercent(progress)}'
                      : '最近阅读'),
        };

        final palette = HomePalette.of(context);
        final tint = HomeKindTint.of(kind, eink: palette.eink);

        return Padding(
          padding: const EdgeInsets.fromLTRB(
            HomeSpace.gutter,
            10,
            HomeSpace.gutter,
            0,
          ),
          child: HomePressable(
            onTap: () => onOpen(item),
            borderRadius: BorderRadius.circular(16),
            pressedScale: 0.988,
            semanticLabel: '$actionVerb $title，$progressText',
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 38,
                          height: 52,
                          child: StoryCover(item: item, cacheWidth: 96),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HomeType.card.copyWith(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: palette.ink,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              progressText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HomeType.meta.copyWith(
                                fontSize: 11.5,
                                color: palette.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        LucideIcons.arrow_right,
                        size: 18,
                        color: palette.accentText,
                      ),
                    ],
                  ),
                  if (progress > 0) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 2.5,
                        backgroundColor: palette.hairline,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          palette.eink ? Colors.black : tint,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
