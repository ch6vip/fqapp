import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../models/comment_reply.dart';
import '../../services/poster_cache.dart';
import '../comment_images.dart';
import '../home/home_design.dart';
import 'detail_sections.dart';

/// Loads the replies to one review.
///
/// Note: 回复体在大写 `Common` 下、三个 id 均必填，且按需懒加载 — 见
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
typedef ReviewReplyLoader = Future<CommentReplyPage> Function(String commentId);

class DetailCommentTile extends StatefulWidget {
  final BookComment comment;
  final ReviewReplyLoader? replyLoader;

  /// Clamp for the review body; null shows the full text (the sheet).
  final int? maxTextLines;

  const DetailCommentTile({
    super.key,
    required this.comment,
    this.replyLoader,
    this.maxTextLines,
  });

  @override
  State<DetailCommentTile> createState() => _DetailCommentTileState();
}

class _DetailCommentTileState extends State<DetailCommentTile> {
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
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _avatar(palette),
              const SizedBox(width: 8),
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
                              fontSize: 12.5,
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
            const SizedBox(height: 6),
            Text(
              readLabel,
              style: TextStyle(color: palette.muted, fontSize: 11, height: 1.3),
            ),
          ],
          const SizedBox(height: 6),
          if (comment.text.isNotEmpty)
            Text(
              comment.text,
              key: ValueKey('detail_review_text_${comment.id}'),
              maxLines: widget.maxTextLines,
              overflow: widget.maxTextLines == null
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.ink,
                fontSize: 13.5,
                height: 1.65,
              ),
            ),
          if (comment.imageUrls.isNotEmpty) ...[
            if (comment.text.isNotEmpty) const SizedBox(height: 8),
            CommentImages(imageUrls: comment.imageUrls),
          ],
          if (comment.diggCount > 0 || comment.replyCount > 0) ...[
            const SizedBox(height: 8),
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

  /// 26dp reviewer avatar; falls back to a neutral person glyph.
  Widget _avatar(HomePalette palette) {
    final fallback = ColoredBox(
      color: palette.soft,
      child: Icon(LucideIcons.user, size: 14, color: palette.muted),
    );
    final avatar = widget.comment.userAvatar;
    return ClipOval(
      child: SizedBox.square(
        dimension: 26,
        child: avatar.isEmpty
            ? fallback
            : CachedNetworkImage(
                cacheManager: PosterCache.instance,
                imageUrl: avatar,
                fit: BoxFit.cover,
                // Decode at 2×; CachedNetworkImage also adds the disk cache a
                // bare Image.network lacks.
                memCacheWidth: 56,
                errorWidget: (context, _, _) => fallback,
              ),
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
        border: palette.eink ? Border.all(color: palette.line) : null,
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
                  : CachedNetworkImage(
                      cacheManager: PosterCache.instance,
                      imageUrl: reply.userAvatar,
                      fit: BoxFit.cover,
                      // 22dp avatar; decode at 2×.
                      memCacheWidth: 48,
                      errorWidget: (context, _, _) => ColoredBox(
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
                if (reply.text.isNotEmpty)
                  Text(
                    reply.text,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 12.5,
                      height: 1.55,
                    ),
                  ),
                if (reply.imageUrls.isNotEmpty) ...[
                  if (reply.text.isNotEmpty) const SizedBox(height: 8),
                  CommentImages(imageUrls: reply.imageUrls),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
