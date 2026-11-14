import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';
import 'home_shelf.dart';

const double _rankCardWidth = 100;
const double _rankCoverHeight = 140;
const double _rankCardGap = 12;

/// 最小触控尺寸（Material 48dp）：「更多」与榜单标签共用。
const double _minTapSize = 48;

/// 「更多」热区与标签内容之间保留的间距。
const double _moreGap = 12;

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
    // 标题行高（HomeSectionHeader：19sp × 1.25）；单榜单没有标签行借
    // 热区时，用它算出让位高度。
    final titleHeight = scaler.scale(19) * 1.25;
    final railHeight =
        _rankCoverHeight +
        8 +
        scaler.scale(13) * 1.35 * 2 +
        4 +
        scaler.scale(11) * 1.3;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HomeSectionHeader(
              title: title,
              // 零高占位，只给「更多」留水平空间；按钮本体浮在下面的
              // 覆盖层里。若把 48 高的按钮当 action 传进来，标题行会被撑高
              // 到 48dp，标题底部到榜单标签空出近 50dp（#372 回归，#384）。
              action: const SizedBox(width: _minTapSize),
              // 首页分类条下面的第一段：标签条已经有下缘留白，这里再叠 20 会让
              // 「标签 → 排行榜」空出三十多个像素，中间一片空白。
              topPadding: 8,
              // 标签行自带的 48dp 热区上下各留 12.7dp 空白，标题下方不再
              // 叠 12；下划线到卡片的间距也由热区下缘承担（不再加 SizedBox）。
              bottomPadding: 0,
            ),
            if (names.length > 1)
              _BoardNames(
                names: names,
                selectedIndex: selectedIndex,
                onSelect: onSelect,
              )
            else
              // 没有标签行时热区不存在，自己补回标题到卡片的间距；但卡片
              // 必须落在「更多」热区（top 8 + 48）下方：否则卡片横向排到
              // 右缘时，最后一张卡片顶部的点击会落到热区里。
              SizedBox(
                height: math.max(homeHeaderGap, _minTapSize - titleHeight + 1),
              ),
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
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: _rankCardGap),
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
        ),
        // 热区从标题文字顶部起算、向下 48dp：整块 Column 远高于它，
        // RenderBox 的 hitTest 不会裁掉超出行高的部分。
        Positioned(
          top: 8,
          right: homeGutter,
          child: ClassicHomeBlockMore(onTap: onMore),
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
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Align(
            alignment: Alignment.topCenter,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(LucideIcons.chevron_right, size: 13, color: palette.muted),
              ],
            ),
          ),
        ),
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
      // 右侧给「更多」的 48dp 热区 + 间距让位：热区浮在标题行上，横向
      // 滚到底时最后一个标签不能钻到它下面，否则文字上半的点击会被
      // 「更多」截获（窄屏 6 个以上榜单名就会滚）。
      padding: const EdgeInsets.only(
        left: homeGutter,
        right: homeGutter + _minTapSize + _moreGap,
      ),
      child: Row(
        children: [
          for (var index = 0; index < names.length; index++)
            Padding(
              padding: EdgeInsets.only(left: index == 0 ? 0 : 4),
              child: Semantics(
                button: true,
                selected: index == selectedIndex,
                label: names[index],
                onTap: () => onSelect(index),
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => onSelect(index),
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: _minTapSize,
                      minHeight: _minTapSize,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        // 48dp 热区高于内容（文字 + 下划线 ≈ 23dp）：内容垂直
                        // 居中，上下各留 12.7dp。标题下方的 padding 和卡片的
                        // SizedBox 已置 0，这两段空白正好被热区溢出借走，
                        // 标题→标签、下划线→卡片都是 12.7dp（#384）。
                        mainAxisAlignment: MainAxisAlignment.center,
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
