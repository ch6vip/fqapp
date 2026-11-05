import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import '../home/home_archive.dart';
import '../home/home_media_card.dart';
import '../../models/media_item.dart';
import 'series_detail_theme.dart';

/// 头部：封面、标题、`全80集 · 8.7万次播放`、分类标签，紧接播放 / 收藏。
///
/// The title wraps in full; play and local collection keep their own actions.
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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

  Widget _titleColumn(HomePalette palette) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const HomeCode('SERIES'),
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text(
          title,
          key: const ValueKey('series-detail-title'),
          style: homeSerifStyle(size: 22, height: 1.3, color: palette.ink),
        ),
      ),
      if (statusLine.isNotEmpty)
        Text(
          statusLine,
          key: const ValueKey('series-detail-status'),
          style: TextStyle(fontSize: 12, height: 1.5, color: palette.muted),
        ),
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
      borderRadius: BorderRadius.circular(homePanelRadius),
      border: palette.eink ? Border.all(color: palette.line) : null,
    ),
    child: Text(
      name,
      style: TextStyle(fontSize: 11, height: 1.5, color: palette.muted),
    ),
  );

  Widget _cover(HomePalette palette) => Container(
    width: 96,
    height: 136,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(homeCoverRadius),
      border: palette.eink ? Border.all(color: palette.line) : null,
    ),
    child: StoryCover(
      item: MediaItem(
        id: '',
        title: title,
        cover: coverUrl,
        author: '',
        badge: '',
        ep: '',
        kind: 'video',
      ),
      cacheWidth: 320,
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
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(homeControlRadius),
            ),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(LucideIcons.play, size: 18),
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
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(homeControlRadius),
          ),
          textStyle: const TextStyle(fontSize: 13),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 版式稿的收藏是描边星形（收藏态由文字「已收藏」表达）。
            const Icon(LucideIcons.star, size: 16),
            const SizedBox(width: 4),
            Text(saved ? '已收藏' : '收藏'),
          ],
        ),
      ),
    ],
  );
}
