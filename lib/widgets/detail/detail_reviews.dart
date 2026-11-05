import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/book_comment.dart';
import '../../models/book_detail.dart';
import '../../services/poster_cache.dart';
import '../home/home_shelf.dart';
import '../wenku/wenku_ui.dart';

export 'detail_comment_tile.dart' show DetailCommentTile, ReviewReplyLoader;

/// Review block: the archive `书评` section heading with the single 「全部」
/// entry, then the newest three reviews, each clamped to four lines.
///
/// Upstream has no review list on its detail page (reviews live behind
/// `BookCommunityActions`), so the section keeps fqapp's content and adopts the
/// shared archive section/row rhythm from `wenku_archive.dart`. The aggregate
/// rating card stays gone: the detail page shows the rating once, in the hero.
/// Renders nothing when there are no reviews at all.
class DetailReviews extends StatelessWidget {
  final BookCommentPage page;
  final BookDetail? detail;
  final VoidCallback? onLoadMore;
  final VoidCallback? onOpenAll;
  final bool loadingMore;

  /// The book whose reviews these are.
  final String bookId;

  /// True when the caller already supplies the page gutter (the ported detail
  /// page pads its whole sliver); false adds fqapp's 16dp gutter itself.
  final bool flush;

  const DetailReviews({
    super.key,
    required this.page,
    this.detail,
    this.onLoadMore,
    this.onOpenAll,
    this.loadingMore = false,
    this.bookId = '',
    this.flush = false,
  });

  @override
  Widget build(BuildContext context) {
    if (page.isEmpty && page.totalCount == 0) return const SizedBox.shrink();
    final totalCount = page.totalCount > 0
        ? page.totalCount
        : page.comments.length;
    final displayed = onOpenAll != null
        ? page.comments.take(3).toList()
        : page.comments;
    final action = onOpenAll ?? (loadingMore ? null : onLoadMore);
    final countLabel = '${formatCount(totalCount)} 条';
    final horizontal = flush ? 0.0 : homeGutter;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          child: Row(
            key: const Key('detail_reviews_header'),
            children: [
              Expanded(
                child: ArchiveSection(
                  title: '书评',
                  code: '03 / REVIEWS',
                  subtitle: countLabel,
                ),
              ),
              if (action == null)
                Text(
                  countLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                )
              else
                GlassTextButton(
                  key: const Key('detail_reviews_more'),
                  compact: true,
                  onPressed: action,
                  child: loadingMore
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const AppText('全部'),
                ),
            ],
          ),
        ),
        if (page.comments.isNotEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
            child: Column(
              children: [
                for (var i = 0; i < displayed.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: Theme.of(context).dividerColor),
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
/// Upstream rhythm: 22dp round avatar, 12dp name with a muted `★ 10`, then the
/// review clamped to four lines. Likes, replies and the score summary stay in
/// the 「全部书评」 sheet, not in the preview.
class _PreviewReview extends StatelessWidget {
  final BookComment comment;

  const _PreviewReview({super.key, required this.comment});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              _avatar(context),
              const SizedBox(width: 8),
              Flexible(
                child: AppText(
                  comment.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              if (comment.score > 0) ...[
                const SizedBox(width: 8),
                AppText(
                  '★ $scoreLabel',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          if (comment.text.isNotEmpty)
            AppText(
              comment.text,
              key: ValueKey('detail_review_text_${comment.id}'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 13,
                height: 1.5,
              ),
            ),
        ],
      ),
    );
  }

  /// 22dp round avatar showing the first character of the name.
  Widget _avatar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = comment.userName.trim();
    final fallback = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          name.isEmpty ? '读' : name.substring(0, 1),
          textScaler: TextScaler.noScaling,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
        ),
      ),
    );
    final avatar = comment.userAvatar;
    return ClipOval(
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
    );
  }
}
