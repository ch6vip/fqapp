import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../models/book_detail.dart';
import '../home/home_design.dart';
import 'detail_sections.dart';

/// Review block: header, the book's aggregate rating card, then the newest
/// reviews. Renders nothing at all when the backend returns no reviews, so the
/// detail page does not grow an empty section.
class DetailReviews extends StatelessWidget {
  final BookCommentPage page;
  final BookDetail? detail;
  final VoidCallback? onLoadMore;
  final bool loadingMore;

  const DetailReviews({
    super.key,
    required this.page,
    this.detail,
    this.onLoadMore,
    this.loadingMore = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (page.isEmpty && page.totalCount == 0) return const SizedBox.shrink();
    final score = detail?.scoreValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              page.headerLabel,
              key: const Key('detail_reviews_header'),
              style: TextStyle(
                color: palette.ink,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            if (page.hasMore && onLoadMore != null)
              TextButton(
                key: const Key('detail_reviews_more'),
                onPressed: loadingMore ? null : onLoadMore,
                style: TextButton.styleFrom(
                  foregroundColor: palette.muted,
                  minimumSize: const Size(48, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                child: loadingMore
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('全部书评', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 3),
                          const Icon(LucideIcons.chevron_right, size: 15),
                        ],
                      ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _ScoreCard(score: score, label: page.scoreLabel),
        if (page.comments.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (final comment in page.comments)
            _CommentTile(
              key: ValueKey('detail_review_${comment.id}'),
              comment: comment,
            ),
        ],
      ],
    );
  }
}

/// Aggregate rating. Shows the book's own score when it has one, otherwise the
/// empty out-of-five prompt the official page uses.
class _ScoreCard extends StatelessWidget {
  final double? score;
  final String label;

  const _ScoreCard({required this.score, required this.label});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      key: const Key('detail_score_card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            '轻点评分',
            style: TextStyle(
              color: palette.ink,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (score != null) ...[
            Text(
              score!.toStringAsFixed(1),
              style: TextStyle(
                color: palette.accentText,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
          ],
          DetailStarRow(stars: score ?? 0, size: 17),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  final BookComment comment;

  const _CommentTile({super.key, required this.comment});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final time = comment.relativeTime();
    final readLabel = comment.readDurationLabel;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: 30,
                  child: comment.userAvatar.isEmpty
                      ? ColoredBox(
                          color: palette.soft,
                          child: Icon(
                            LucideIcons.user,
                            size: 15,
                            color: palette.muted,
                          ),
                        )
                      : Image.network(
                          comment.userAvatar,
                          fit: BoxFit.cover,
                          errorBuilder: (context, _, _) => ColoredBox(
                            color: palette.soft,
                            child: Icon(
                              LucideIcons.user,
                              size: 15,
                              color: palette.muted,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.userName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (comment.score > 0) ...[
                          const SizedBox(width: 8),
                          DetailStarRow(stars: comment.stars, size: 10),
                        ],
                      ],
                    ),
                    if (time.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        time,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (readLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              readLabel,
              style: TextStyle(color: palette.muted, fontSize: 11, height: 1.3),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            comment.text,
            key: ValueKey('detail_review_text_${comment.id}'),
            style: TextStyle(color: palette.ink, fontSize: 13.5, height: 1.65),
          ),
          if (comment.diggCount > 0 || comment.replyCount > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (comment.diggCount > 0) ...[
                  Icon(LucideIcons.thumbs_up, size: 13, color: palette.muted),
                  const SizedBox(width: 4),
                  Text(
                    '${comment.diggCount}',
                    style: TextStyle(color: palette.muted, fontSize: 11.5),
                  ),
                ],
                if (comment.diggCount > 0 && comment.replyCount > 0)
                  const SizedBox(width: 16),
                if (comment.replyCount > 0) ...[
                  Icon(
                    LucideIcons.message_circle,
                    size: 13,
                    color: palette.muted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${comment.replyCount}',
                    style: TextStyle(color: palette.muted, fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
