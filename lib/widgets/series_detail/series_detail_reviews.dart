import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/book_detail.dart' show formatCounter;
import '../../models/playlet_comment.dart';
import '../../services/api_client.dart';
import '../home/home_cell_blocks.dart' show HomeBlockMore;
import '../home/home_design.dart';
import '../home/home_shelf.dart' show HomeSectionHeader, homeGutter;
import 'series_detail_common.dart';

/// 剧评：头部 `剧评 · 952` + 右侧「全部 ›」，下方横滑卡片。
///
/// 桌面宽度下卡片不再拉到 900dp，最长 [maxCardWidth] 就换行留白。
class SeriesDetailReviews extends StatelessWidget {
  const SeriesDetailReviews({
    super.key,
    required this.comments,
    required this.total,
    required this.loading,
    required this.failed,
    required this.onRetry,
    required this.onShowAll,
  });

  static const maxCardWidth = 420.0;

  final List<PlayletComment> comments;
  final int total;
  final bool loading;
  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      key: const ValueKey('series-detail-comment-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(
          title: total > 0 ? '剧评 · ${formatCounter('$total')}' : '剧评',
          action: comments.isEmpty
              ? null
              : HomeBlockMore(
                  key: const ValueKey('series-detail-comments-all'),
                  onTap: onShowAll,
                  label: '全部',
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: _body(context, palette),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, HomePalette palette) {
    if (loading) return const SeriesDetailSkeleton();
    if (failed) {
      return SeriesRetryInline(message: '剧评加载失败', onRetry: onRetry);
    }
    if (comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '暂无剧评',
          key: const ValueKey('series-detail-comments-empty'),
          style: TextStyle(fontSize: 13, color: palette.muted),
        ),
      );
    }
    final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
    final width = math.min(
      MediaQuery.sizeOf(context).width * 0.78,
      maxCardWidth,
    );
    return SizedBox(
      height: 70 + 88 * scale,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: comments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) =>
            _card(palette, comments[index], width, index),
      ),
    );
  }

  Widget _card(
    HomePalette palette,
    PlayletComment comment,
    double width,
    int index,
  ) => Container(
    key: ValueKey('series-detail-comment-card-$index'),
    width: width,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: BorderRadius.circular(12),
      border: palette.eink ? Border.all(color: palette.line) : null,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: palette.soft,
                shape: BoxShape.circle,
                border: palette.eink ? Border.all(color: palette.line) : null,
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: comment.userAvatar.isEmpty
                  ? _initial(palette, comment)
                  : CachedNetworkImage(
                      imageUrl: ApiClient.instance.absoluteUrl(
                        comment.userAvatar,
                      ),
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _initial(palette, comment),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                comment.userName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.favorite_border_rounded, size: 15, color: palette.muted),
            const SizedBox(width: 3),
            Text(
              comment.diggCount > 0
                  ? formatCounter('${comment.diggCount}')
                  : '',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Text(
            comment.text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15, height: 1.35, color: palette.ink),
          ),
        ),
      ],
    ),
  );

  Widget _initial(HomePalette palette, PlayletComment comment) => Text(
    comment.userName.isEmpty
        ? '?'
        : String.fromCharCode(comment.userName.runes.first),
    style: TextStyle(fontSize: 13, color: palette.ink),
  );
}
