import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_chapter_row.dart';
import 'detail_states.dart';

/// `目录` section: heading with the one chapter-count line, then a preview of
/// the reader's current chapter ±1 (first three when there is no progress).
///
/// The old preview was pinned to chapters 1–3, so its `current` flag never
/// matched anything past the opening chapters.
class DetailDirectorySection extends StatelessWidget {
  final String trailing;

  /// The visible slice: current ±1, or chapters 1–3 without progress.
  final List<Chapter> preview;

  /// Index of the preview's first row in the whole catalogue.
  final int startIndex;

  /// Index of the current chapter inside [preview]; null when unread.
  final int? currentIndex;

  /// Opening excerpts keyed by chapter item id.
  final Map<String, String> excerpts;
  final String? error;
  final VoidCallback onOpenAll;
  final VoidCallback onRetry;
  final VoidCallback? onReadCached;
  final ValueChanged<Chapter> onOpenChapter;

  const DetailDirectorySection({
    super.key,
    required this.trailing,
    required this.preview,
    required this.startIndex,
    required this.currentIndex,
    required this.excerpts,
    required this.onOpenAll,
    required this.onRetry,
    required this.onOpenChapter,
    this.error,
    this.onReadCached,
  });

  /// `完结 共820章 · 全部 ›` — the only place the chapter count appears.
  Widget? _action(HomePalette palette) {
    if (trailing.isEmpty) return null;
    return HomePressable(
      key: const Key('detail_directory_button'),
      semanticLabel: '查看全部章节',
      onTap: onOpenAll,
      borderRadius: BorderRadius.circular(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              trailing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSectionHeader(title: '目录', action: _action(palette)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: error != null
              ? DetailInlineError(
                  message: error!,
                  onRetry: onRetry,
                  onReadCached: onReadCached,
                )
              : preview.isEmpty
              ? Text(
                  '暂无目录',
                  style: TextStyle(color: palette.muted, fontSize: 13),
                )
              : Column(
                  key: const Key('detail_preview_chapters'),
                  children: [
                    for (var i = 0; i < preview.length; i++) ...[
                      DetailChapterRow(
                        key: ValueKey(
                          'detail_preview_chapter_${preview[i].itemId}',
                        ),
                        chapter: preview[i],
                        index: startIndex + i,
                        current: i == currentIndex,
                        divider:
                            i < preview.length - 1 ||
                            excerpts[preview[i].itemId] != null,
                        onTap: () => onOpenChapter(preview[i]),
                      ),
                      if (excerpts[preview[i].itemId] case final String text)
                        _ChapterExcerpt(
                          key: ValueKey(
                            'detail_preview_excerpt_${preview[i].itemId}',
                          ),
                          text: text,
                          divider: i < preview.length - 1,
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// Opening lines of a chapter, shown under its row in the preview block.
class _ChapterExcerpt extends StatelessWidget {
  final String text;
  final bool divider;

  const _ChapterExcerpt({super.key, required this.text, required this.divider});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.7),
          ),
          if (divider) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: palette.line),
          ],
        ],
      ),
    );
  }
}
