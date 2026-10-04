import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/library_store.dart';
import '../../services/media_history_store.dart';
import 'home_design.dart';
import 'home_media_card.dart';

/// A compact "continue reading/watching" capsule banner displayed on the home page.
/// If there is no browsing history, it gracefully collapses to [SizedBox.shrink].
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
            (latest['lastChapterTitle'] ?? latest['chapterTitle'])?.toString() ?? '';
        final episode = (latest['episode'] as num?)?.toInt() ?? 0;
        final progress = ((latest['progress'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0);

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
          'video' || 'manju' =>
            episode > 0 ? '看到第 $episode 集' : '正在追看',
          'audio' =>
            episode > 0 ? '听至第 $episode 集' : '最近收听',
          _ =>
            chapterTitle.isNotEmpty
                ? '读至 $chapterTitle'
                : (progress > 0 ? '已读 ${(progress * 100).toInt()}%' : '最近阅读'),
        };

        final palette = HomePalette.of(context);

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: HomePressable(
            onTap: () => onOpen(item),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: palette.line.withValues(alpha: 0.7),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: palette.dark ? 0.22 : 0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 36,
                      height: 48,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          StoryCover(
                            item: item,
                            cacheWidth: 80,
                          ),
                          Positioned(
                            right: 2,
                            bottom: 2,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Icon(
                                homeKindIcon(kind),
                                size: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: HomePalette.accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                actionVerb,
                                style: TextStyle(
                                  color: HomePalette.accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: palette.ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                progressText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                            if (progress > 0) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 50,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 3,
                                    backgroundColor: palette.line,
                                    valueColor: const AlwaysStoppedAnimation<Color>(
                                      HomePalette.accent,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: palette.soft,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      LucideIcons.play,
                      size: 13,
                      color: palette.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
