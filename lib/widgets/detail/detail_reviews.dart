import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../models/book_detail.dart';
import '../../models/comment_reply.dart';
import '../home/home_design.dart';
import 'detail_sections.dart';

/// Loads the replies to one review.
///
/// Note: 回复体在大写 `Common` 下、三个 id 均必填，且按需懒加载 — 见
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
typedef ReviewReplyLoader = Future<CommentReplyPage> Function(String commentId);

/// Review block: header, the book's aggregate rating card, then the newest
/// reviews. Renders nothing at all when the backend returns no reviews, so the
/// detail page does not grow an empty section.
class DetailReviews extends StatelessWidget {
  final BookCommentPage page;
  final BookDetail? detail;
  final VoidCallback? onLoadMore;
  final bool loadingMore;

  /// The book whose reviews these are; replies are fetched per review.
  final String bookId;

  /// Null disables the reply affordance entirely, which is what an offline
  /// caller (a test that injected its own loaders) wants.
  final ReviewReplyLoader? replyLoader;

  const DetailReviews({
    super.key,
    required this.page,
    this.detail,
    this.onLoadMore,
    this.loadingMore = false,
    this.bookId = '',
    this.replyLoader,
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
              replyLoader: replyLoader,
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

class _CommentTile extends StatefulWidget {
  final BookComment comment;
  final ReviewReplyLoader? replyLoader;

  const _CommentTile({super.key, required this.comment, this.replyLoader});

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  CommentReplyPage? _replies;
  bool _loading = false;
  bool _failed = false;

  /// Replies load on first tap: a review list is long, and most reviews are
  /// never expanded.
  Future<void> _toggle() async {
    if (_loading) return;
    if (_replies != null) {
      setState(() => _replies = null);
      return;
    }
    final loader = widget.replyLoader;
    if (loader == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await loader(widget.comment.id);
      if (!mounted) return;
      setState(() {
        _replies = page;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final comment = widget.comment;
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
                if (comment.replyCount > 0) _replyToggle(palette, comment),
              ],
            ),
          ],
          if (_failed) ...[
            const SizedBox(height: 8),
            Text(
              '回复加载失败',
              key: ValueKey('detail_reply_error_${comment.id}'),
              style: TextStyle(color: palette.muted, fontSize: 11.5),
            ),
          ],
          if (_replies case final CommentReplyPage loaded)
            _ReplyList(
              key: ValueKey('detail_replies_${comment.id}'),
              page: loaded,
            ),
        ],
      ),
    );
  }

  /// `回复 N` doubles as the expand/collapse control, so the count the official
  /// page shows becomes the way to read them.
  Widget _replyToggle(HomePalette palette, BookComment comment) {
    final open = _replies != null;
    final canOpen = widget.replyLoader != null;
    final label = _replies?.totalCount ?? comment.replyCount;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.message_circle, size: 13, color: palette.muted),
        const SizedBox(width: 4),
        Text(
          canOpen ? '回复 $label' : '$label',
          style: TextStyle(color: palette.muted, fontSize: 11.5),
        ),
        if (canOpen) ...[
          const SizedBox(width: 2),
          Icon(
            open ? LucideIcons.chevron_up : LucideIcons.chevron_down,
            size: 13,
            color: palette.muted,
          ),
        ],
      ],
    );
    if (!canOpen) return row;
    return HomePressable(
      key: ValueKey('detail_reply_toggle_${comment.id}'),
      semanticLabel: open ? '收起回复' : '查看 $label 条回复',
      onTap: () => unawaited(_toggle()),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _loading
            ? SizedBox.square(
                dimension: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.muted,
                ),
              )
            : row,
      ),
    );
  }
}

/// Replies to one review, indented under it.
class _ReplyList extends StatelessWidget {
  final CommentReplyPage page;

  const _ReplyList({super.key, required this.page});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (page.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '暂无回复',
          style: TextStyle(color: palette.muted, fontSize: 11.5),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          for (final reply in page.replies) _ReplyTile(reply: reply),
          if (page.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '仅显示部分回复',
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReplyTile extends StatelessWidget {
  final CommentReply reply;

  const _ReplyTile({required this.reply});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final time = reply.relativeTime();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox.square(
              dimension: 22,
              child: reply.userAvatar.isEmpty
                  ? ColoredBox(
                      color: palette.surface,
                      child: Icon(
                        LucideIcons.user,
                        size: 11,
                        color: palette.muted,
                      ),
                    )
                  : Image.network(
                      reply.userAvatar,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, _) => ColoredBox(
                        color: palette.surface,
                        child: Icon(
                          LucideIcons.user,
                          size: 11,
                          color: palette.muted,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        reply.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (time.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        time,
                        style: TextStyle(color: palette.muted, fontSize: 10.5),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  reply.text,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 12.5,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
