import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_chapter_row.dart';
import 'detail_states.dart';

/// `目录` section: heading with the one chapter-count line, then a preview of
/// the reader's current chapter ±1 (first three when there is no progress).
///
/// The old preview was pinned to chapters 1–3, so its `current` flag never
/// matched anything past the opening chapters. The mockup shows plain rows
/// only: no ordinals, chevrons or opening excerpts.
class DetailDirectorySection extends StatelessWidget {
  final String trailing;

  /// The visible slice: current ±1, or chapters 1–3 without progress.
  final List<Chapter> preview;

  /// Index of the current chapter inside [preview]; null when unread.
  final int? currentIndex;

  final String? error;
  final VoidCallback onOpenAll;
  final VoidCallback onRetry;
  final ValueChanged<Chapter> onOpenChapter;

  const DetailDirectorySection({
    super.key,
    required this.trailing,
    required this.preview,
    required this.currentIndex,
    required this.onOpenAll,
    required this.onRetry,
    required this.onOpenChapter,
    this.error,
  });

  /// `完结 共820章 · 全部 ›` — the only place the chapter count appears.
  Widget? _action(HomePalette palette) {
    if (trailing.isEmpty) return null;
    return HomePressable(
      key: const Key('detail_directory_button'),
      semanticLabel: '查看全部章节',
      onTap: onOpenAll,
      borderRadius: BorderRadius.circular(4),
      child: Text(
        '$trailing ›',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
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
              ? DetailInlineError(message: error!, onRetry: onRetry)
              : preview.isEmpty
              ? Text(
                  '暂无目录',
                  style: TextStyle(color: palette.muted, fontSize: 13),
                )
              : Column(
                  key: const Key('detail_preview_chapters'),
                  children: [
                    for (var i = 0; i < preview.length; i++)
                      DetailChapterRow(
                        key: ValueKey(
                          'detail_preview_chapter_${preview[i].itemId}',
                        ),
                        chapter: preview[i],
                        current: i == currentIndex,
                        read: currentIndex != null && i < currentIndex!,
                        divider: i < preview.length - 1,
                        onTap: () => onOpenChapter(preview[i]),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
