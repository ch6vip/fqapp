import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/book_comment.dart';
import '../../models/book_detail.dart';
import '../../services/poster_cache.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_states.dart';

export 'detail_comment_tile.dart' show DetailCommentTile, ReviewReplyLoader;

/// Review block: section heading with the single 「全部」 entry, then the
/// newest three reviews, each clamped to four lines.
///
/// The aggregate rating card is gone: the detail page shows the rating once,
/// in the hero. Renders nothing when there are no reviews at all.
class DetailReviews extends StatelessWidget {
  final BookCommentPage page;
  final BookDetail? detail;
  final VoidCallback? onLoadMore;
  final VoidCallback? onOpenAll;
  final bool loadingMore;

  /// The book whose reviews these are.
  final String bookId;

  const DetailReviews({
    super.key,
    required this.page,
    this.detail,
    this.onLoadMore,
    this.onOpenAll,
    this.loadingMore = false,
    this.bookId = '',
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (page.isEmpty && page.totalCount == 0) return const SizedBox.shrink();
    final totalCount = page.totalCount > 0
        ? page.totalCount
        : page.comments.length;
    final displayed = onOpenAll != null
        ? page.comments.take(3).toList()
        : page.comments;
    final action = onOpenAll ?? (loadingMore ? null : onLoadMore);
    final countLabel = '${formatCount(totalCount)} 条';
    final actionLabel = action == null ? countLabel : '$countLabel · 全部 ›';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSectionHeader(
          key: const Key('detail_reviews_header'),
          title: '书评',
          action: action == null
              ? Text(
                  actionLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.muted, fontSize: 12),
                )
              : HomePressable(
                  key: const Key('detail_reviews_more'),
                  semanticLabel: '查看全部书评',
                  onTap: action,
                  borderRadius: BorderRadius.circular(6),
                  child: loadingMore
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          actionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.muted, fontSize: 12),
                        ),
                ),
        ),
        if (page.comments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: Column(
              children: [
                for (var i = 0; i < displayed.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: palette.line),
                  _PreviewReview(
                    key: ValueKey('detail_review_${displayed[i].id}'),
                    comment: displayed[i],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Compact review row used on the detail page.
///
/// Mockup: 22dp round avatar, 12dp name with a muted `★ 10`, then the review
/// clamped to four lines. Likes, replies and the score summary stay in the
/// 「全部书评」 sheet, not in the preview.
class _PreviewReview extends StatelessWidget {
  final BookComment comment;

  const _PreviewReview({super.key, required this.comment});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final score = comment.score;
    final scoreLabel = score == score.roundToDouble()
        ? score.toInt().toString()
        : score.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _avatar(palette),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  comment.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              if (comment.score > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '★ $scoreLabel',
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          if (comment.text.isNotEmpty)
            Text(
              comment.text,
              key: ValueKey('detail_review_text_${comment.id}'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.ink, fontSize: 13, height: 1.5),
            ),
        ],
      ),
    );
  }

  /// 22dp round avatar showing the first character of the name.
  Widget _avatar(HomePalette palette) {
    final name = comment.userName.trim();
    final fallback = ColoredBox(
      color: palette.soft,
      child: Center(
        child: Text(
          name.isEmpty ? '读' : name.substring(0, 1),
          textScaler: TextScaler.noScaling,
          style: TextStyle(color: palette.muted, fontSize: 11, height: 1.2),
        ),
      ),
    );
    final avatar = comment.userAvatar;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: palette.eink ? Border.all(color: palette.line) : null,
      ),
      child: ClipOval(
        child: SizedBox.square(
          dimension: 22,
          child: avatar.isEmpty
              ? fallback
              : CachedNetworkImage(
                  cacheManager: PosterCache.instance,
                  imageUrl: avatar,
                  fit: BoxFit.cover,
                  memCacheWidth: 44,
                  errorWidget: (context, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
