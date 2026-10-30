import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../home/home_design.dart';
import 'series_detail_theme.dart';

/// 头部：封面、标题、`全80集 · 8.7万次播放`、分类标签，紧接播放 / 收藏。
///
/// 尺寸照版式稿右机：外边距 4/16，封面 96×136 圆角 6，标题 19/1.3，
/// 状态行 12 灰，标签 11；动作行上距 14、间距 8、高 40。
class SeriesDetailHero extends StatelessWidget {
  const SeriesDetailHero({
    super.key,
    required this.title,
    required this.coverUrl,
    required this.statusLine,
    required this.categories,
    required this.playLabel,
    required this.playEnabled,
    required this.onPlay,
    required this.saved,
    required this.shelfEnabled,
    required this.shelfBusy,
    required this.onToggleShelf,
  });

  final String title;

  /// 已解析成绝对地址；空串表示没有封面。
  final String coverUrl;
  final String statusLine;
  final List<String> categories;
  final String playLabel;
  final bool playEnabled;
  final VoidCallback onPlay;
  final bool saved;
  final bool shelfEnabled;
  final bool shelfBusy;
  final VoidCallback onToggleShelf;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(palette),
              const SizedBox(width: 14),
              Expanded(child: _titleColumn(palette)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: _actions(palette),
        ),
      ],
    );
  }

  Widget _titleColumn(HomePalette palette) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          key: const ValueKey('series-detail-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 19,
            height: 1.3,
            fontWeight: FontWeight.w700,
            color: palette.ink,
          ),
        ),
        if (statusLine.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            statusLine,
            key: const ValueKey('series-detail-status'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
        ],
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            key: const ValueKey('series-detail-categories'),
            spacing: 6,
            runSpacing: 6,
            children: [for (final name in categories) _tag(palette, name)],
          ),
        ],
      ],
    ),
  );

  Widget _tag(HomePalette palette, String name) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
    decoration: BoxDecoration(
      color: palette.soft,
      borderRadius: BorderRadius.circular(99),
      border: palette.eink ? Border.all(color: palette.line) : null,
    ),
    child: Text(name, style: TextStyle(fontSize: 11, color: palette.muted)),
  );

  Widget _cover(HomePalette palette) => Container(
    width: 96,
    height: 136,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      border: palette.eink ? Border.all(color: palette.line) : null,
    ),
    child: coverUrl.isEmpty
        ? ColoredBox(
            color: palette.soft,
            child: Icon(Icons.movie_creation_outlined, color: palette.muted),
          )
        : CachedNetworkImage(
            imageUrl: coverUrl,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => ColoredBox(
              color: palette.soft,
              child: Icon(Icons.movie_creation_outlined, color: palette.muted),
            ),
          ),
  );

  Widget _actions(HomePalette palette) => Row(
    key: const ValueKey('series-detail-actions'),
    children: [
      Expanded(
        child: FilledButton(
          key: const ValueKey('series-detail-play-button'),
          onPressed: playEnabled ? onPlay : null,
          style: FilledButton.styleFrom(
            backgroundColor: seriesAccent(palette),
            foregroundColor: seriesOnAccent(palette),
            disabledBackgroundColor: palette.soft,
            disabledForegroundColor: palette.muted,
            elevation: 0,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.play_arrow_rounded, size: 18),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  playLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(width: 8),
      OutlinedButton(
        key: const ValueKey('series-detail-fav-button'),
        onPressed: shelfBusy || !shelfEnabled ? null : onToggleShelf,
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.ink,
          backgroundColor: palette.surface,
          disabledForegroundColor: palette.muted,
          side: BorderSide(color: palette.line),
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 13),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              saved ? Icons.star_rounded : Icons.star_border_rounded,
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(saved ? '已收藏' : '收藏'),
          ],
        ),
      ),
    ],
  );
}
