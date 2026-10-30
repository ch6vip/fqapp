import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/book_detail.dart' show formatCounter;
import '../../models/playlet_comment.dart';
import '../../services/api_client.dart';
import '../home/home_cell_blocks.dart' show HomeBlockMore;
import '../home/home_design.dart';
import 'series_detail_common.dart';

/// 剧评：头部 `剧评 · 952` + 右侧「全部 ›」，下面是竖排的评论行。
///
/// 版式稿：行内 22dp 头像 + 12sp 昵称 + 12sp 相对时间，正文 13/1.5
/// 最多 4 行，行间 1px 分隔线。桌面只保留最大宽度，不铺满整屏。
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

  static const maxListWidth = 420.0;

  final List<PlayletComment> comments;
  final int total;
  final bool loading;
  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SeriesSection(
      key: const ValueKey('series-detail-comment-section'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeriesSectionHeader(
            title: total > 0 ? '剧评 · ${formatCounter('$total')}' : '剧评',
            action: comments.isEmpty
                ? null
                : HomeBlockMore(
                    key: const ValueKey('series-detail-comments-all'),
                    onTap: onShowAll,
                    label: '全部',
                  ),
          ),
          _body(palette),
        ],
      ),
    );
  }

  Widget _body(HomePalette palette) {
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxListWidth),
      child: Column(
        key: const ValueKey('series-detail-comment-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < comments.length; i++)
            _row(palette, comments[i], last: i == comments.length - 1),
        ],
      ),
    );
  }

  Widget _row(
    HomePalette palette,
    PlayletComment comment, {
    required bool last,
  }) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: last ? null : Border(bottom: BorderSide(color: palette.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
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
                style: TextStyle(fontSize: 12, color: palette.ink),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              relativeTime(comment.createdAt),
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          comment.text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, height: 1.5, color: palette.ink),
        ),
      ],
    ),
  );

  Widget _initial(HomePalette palette, PlayletComment comment) => Text(
    comment.userName.isEmpty
        ? '?'
        : String.fromCharCode(comment.userName.runes.first),
    style: TextStyle(fontSize: 11, color: palette.ink),
  );
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前，超过 30 天给日期。
String relativeTime(DateTime? time) {
  if (time == null) return '';
  final local = time.toLocal();
  final diff = DateTime.now().difference(local);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
