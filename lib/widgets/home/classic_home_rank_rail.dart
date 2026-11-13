import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';
import 'home_shelf.dart';

const double _rankCardWidth = 100;
const double _rankCoverHeight = 140;
const double _rankCardGap = 12;

/// f329399's horizontal TOP-cover rail. Only presentation lives here:
/// HomeRankCell retains the selected board, loader and request generation.
class ClassicHomeRankRail extends StatelessWidget {
  const ClassicHomeRankRail({
    super.key,
    required this.title,
    required this.names,
    required this.selectedIndex,
    required this.books,
    required this.loading,
    required this.onSelect,
    required this.onOpen,
    required this.onMore,
  });

  final String title;
  final List<String> names;
  final int selectedIndex;
  final List<MediaItem> books;
  final bool loading;
  final ValueChanged<int> onSelect;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final railHeight =
        _rankCoverHeight +
        8 +
        scaler.scale(13) * 1.35 * 2 +
        4 +
        scaler.scale(11) * 1.3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(
          title: title,
          action: ClassicHomeBlockMore(onTap: onMore),
          // 首页分类条下面的第一段：标签条已经有下缘留白，这里再叠 20 会让
          // 「标签 → 排行榜」空出三十多个像素，中间一片空白。
          topPadding: 8,
        ),
        if (names.length > 1)
          _BoardNames(
            names: names,
            selectedIndex: selectedIndex,
            onSelect: onSelect,
          ),
        const SizedBox(height: 12),
        if (loading)
          SizedBox(
            height: railHeight,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: HomePalette.accent,
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: railHeight,
            child: ListView.separated(
              key: const Key('classic_home_rank_rail'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: homeGutter),
              itemCount: books.length,
              separatorBuilder: (_, _) => const SizedBox(width: _rankCardGap),
              itemBuilder: (context, index) {
                final item = books[index];
                return _RankCard(
                  key: ValueKey('rank:${item.kind}:${item.id}'),
                  item: item,
                  rank: index + 1,
                  onTap: () => onOpen(item),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Original 12sp action and arrow, with no archive label or code.
class ClassicHomeBlockMore extends StatelessWidget {
  const ClassicHomeBlockMore({
    super.key,
    required this.onTap,
    this.label = '更多',
  });

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, height: 1.2, color: palette.muted),
          ),
          const SizedBox(width: 2),
          Icon(LucideIcons.chevron_right, size: 13, color: palette.muted),
        ],
      ),
    );
  }
}

/// Plain board tabs with the original 16 × 2dp underline.
class _BoardNames extends StatelessWidget {
  const _BoardNames({
    required this.names,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<String> names;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      child: Row(
        children: [
          for (var index = 0; index < names.length; index++)
            Padding(
              padding: EdgeInsets.only(left: index == 0 ? 0 : 20),
              child: GestureDetector(
                onTap: () => onSelect(index),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        names[index],
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.2,
                          fontWeight: index == selectedIndex
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: index == selectedIndex
                              ? palette.ink
                              : palette.muted,
                        ),
                      ),
                    ),
                    Container(
                      width: 16,
                      height: 2,
                      decoration: BoxDecoration(
                        color: index == selectedIndex
                            ? palette.ink
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RankCard extends StatelessWidget {
  const _RankCard({
    super.key,
    required this.item,
    required this.rank,
    required this.onTap,
  });

  final MediaItem item;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final score = item.score;
    final meta = item.rankTags.isNotEmpty
        ? item.rankTags.first
        : item.author.isNotEmpty
        ? item.author
        : score != null
        ? homeScoreText(score)
        : '';
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      semanticLabel: '$rank ${item.title}',
      child: SizedBox(
        width: _rankCardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RankCover(item: item, rank: rank),
            const SizedBox(height: 8),
            SizedBox(
              height: scaler.scale(13) * 1.35 * 2,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RankCover extends StatelessWidget {
  const _RankCover({required this.item, required this.rank});

  final MediaItem item;
  final int rank;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _rankCardWidth,
      height: _rankCoverHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            StoryCover(item: item, cacheWidth: 200),
            if (rank <= 3)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'TOP $rank',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
