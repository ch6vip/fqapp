import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_chapter_row.dart';
import 'detail_style.dart';
import 'detail_states.dart';

/// `目录` section: heading with the one chapter-count line, the reader's
/// progress line and bar, then a preview of the current chapter ±1 (first
/// three when there is no progress).
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

  /// Index of the saved chapter in the whole catalogue; null when unread.
  final int? resumeIndex;

  /// Whole-catalogue chapter count, used by the progress percentage.
  final int chapterCount;

  /// `3 天前` for the progress line; null hides the time part.
  final String? readTimeLabel;

  final String? error;
  final VoidCallback onOpenAll;
  final VoidCallback onRetry;
  final ValueChanged<Chapter> onOpenChapter;

  const DetailDirectorySection({
    super.key,
    required this.trailing,
    required this.preview,
    required this.currentIndex,
    this.resumeIndex,
    this.chapterCount = 0,
    this.readTimeLabel,
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

  /// `205 / 820` and `已读 25% · 3 天前`, or null when unread.
  ({int number, int total, int percent, String label})? _progress() {
    final index = resumeIndex;
    if (index == null || chapterCount <= 0) return null;
    final number = (index + 1).clamp(1, chapterCount);
    final percent = (number / chapterCount * 100).round();
    final time = readTimeLabel;
    final label = time == null || time.isEmpty
        ? '已读 $percent%'
        : '已读 $percent% · $time';
    return (
      number: number,
      total: chapterCount,
      percent: percent,
      label: label,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final progress = _progress();
    final rows = error != null
        ? DetailInlineError(message: error!, onRetry: onRetry)
        : preview.isEmpty
        ? Text('暂无目录', style: TextStyle(color: palette.muted, fontSize: 13))
        : Column(
            key: const Key('detail_preview_chapters'),
            children: [
              for (var i = 0; i < preview.length; i++)
                DetailChapterRow(
                  key: ValueKey('detail_preview_chapter_${preview[i].itemId}'),
                  chapter: preview[i],
                  current: i == currentIndex,
                  read: currentIndex != null && i < currentIndex!,
                  divider: i < preview.length - 1,
                  onTap: () => onOpenChapter(preview[i]),
                ),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSectionHeader(
          title: '目录',
          action: _action(palette),
          bottomGap: progress == null ? 10 : 8,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (progress != null) ...[
                _ProgressLine(palette: palette, progress: progress),
                const SizedBox(height: 6),
                _ProgressBar(palette: palette, percent: progress.percent),
                const SizedBox(height: 4),
              ],
              rows,
            ],
          ),
        ),
      ],
    );
  }
}

/// `已读 25% · 3 天前` on the left, `205 / 820` on the right.
class _ProgressLine extends StatelessWidget {
  final HomePalette palette;
  final ({int number, int total, int percent, String label}) progress;

  const _ProgressLine({required this.palette, required this.progress});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: palette.muted,
      fontSize: 12,
      height: 1.5,
      fontFeatures: detailNumericFeatures,
    );
    return Row(
      key: const Key('detail_progress_line'),
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            progress.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${progress.number} / ${progress.total}',
          key: const Key('detail_progress_count'),
          style: style,
        ),
      ],
    );
  }
}

/// 4dp track (`--m-soft`) with an accent fill; e-ink is a 5dp black bar in a
/// black hairline.
class _ProgressBar extends StatelessWidget {
  final HomePalette palette;
  final int percent;

  const _ProgressBar({required this.palette, required this.percent});

  @override
  Widget build(BuildContext context) {
    final eink = palette.eink;
    final radius = BorderRadius.circular(99);
    return Container(
      key: const Key('detail_progress_bar'),
      height: eink ? 5 : 4,
      decoration: BoxDecoration(
        color: detailProgressTrack(palette),
        borderRadius: radius,
        border: eink ? Border.all(color: palette.line) : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: (percent / 100).clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(
              key: const Key('detail_progress_fill'),
              color: detailProgressFill(palette),
            ),
          ),
        ),
      ),
    );
  }
}
