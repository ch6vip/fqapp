import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart' show homeGutter;
import 'series_detail_theme.dart';

/// 头部：封面、标题、`全80集 · 8.7万次播放`、分类标签，下面是主行动钮
/// 与收藏（改版后从底部悬浮栏挪到这里，首屏就能播）。
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 4, homeGutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(palette),
              const SizedBox(width: 14),
              Expanded(child: _titleColumn(palette)),
            ],
          ),
          const SizedBox(height: 14),
          _actions(palette),
        ],
      ),
    );
  }

  Widget _titleColumn(HomePalette palette) => Column(
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
          letterSpacing: -0.2,
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
      borderRadius: BorderRadius.circular(8),
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
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: Text(
            playLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        key: const ValueKey('series-detail-fav-button'),
        onPressed: shelfBusy || !shelfEnabled ? null : onToggleShelf,
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.ink,
          disabledForegroundColor: palette.muted,
          side: BorderSide(color: palette.line),
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 14),
        ),
        icon: Icon(
          saved ? Icons.star_rounded : Icons.star_border_rounded,
          size: 18,
        ),
        label: Text(saved ? '已收藏' : '收藏'),
      ),
    ],
  );
}
