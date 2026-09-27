import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/comment_reply.dart';
import '../../models/playlet_comment.dart';
import '../../services/api_client.dart';
import 'playlet_discussion_tile.dart';

typedef PlayletReplyPageLoader =
    Future<CommentReplyPage> Function({
      required String commentId,
      required int count,
      required String cursor,
      String refReplyId,
    });

/// 官方剧评详情中的回复列表。保持同一个面板高度，返回时保留剧评排序和滚动位置。
class PlayletReplyPanel extends StatefulWidget {
  const PlayletReplyPanel({
    super.key,
    required this.seriesId,
    required this.comment,
    required this.onBack,
    this.loader,
    this.focusReplyId = '',
  });

  final String seriesId;
  final PlayletComment comment;
  final VoidCallback onBack;
  final PlayletReplyPageLoader? loader;

  /// 回复型热评定位（`hot_reply_id`）：非空时首页走官方 source=1002
  /// 定点读（business_param.ref_reply_id/insert_reply_ids，
  /// `y.java` L():1163-1203），失败回退普通列表（官方 zip 的
  /// onErrorReturn → 仅 A 生效）。
  final String focusReplyId;

  @override
  State<PlayletReplyPanel> createState() => _PlayletReplyPanelState();
}

class _PlayletReplyPanelState extends State<PlayletReplyPanel> {
  final _scroll = ScrollController();
  final _replies = <CommentReply>[];
  String _cursor = '';
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  late int _total = widget.comment.replyCount;

  /// 首次加载是否还走定点读；失败后回退普通列表并不再重试定点。
  bool _useFocus = false;

  @override
  void initState() {
    super.initState();
    _useFocus = widget.focusReplyId.isNotEmpty;
    _scroll.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_error == null &&
        _scroll.hasClients &&
        _scroll.position.extentAfter < 160) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final requestedCursor = _cursor;
    // 官方定点读只在首页（cursor 为空）带 ref_reply_id（`L()` 的
    // cursor=""），加载更多回到普通分页。
    final refReplyId =
        _useFocus && requestedCursor.isEmpty ? widget.focusReplyId : '';
    final pinnedFirst = refReplyId.isNotEmpty;
    try {
      // 官方回复分页每页 5 条（`y.java:97-98` static{o=5;p=5}）。
      final page =
          await (widget.loader?.call(
                commentId: widget.comment.id,
                count: 5,
                cursor: requestedCursor,
                refReplyId: refReplyId,
              ) ??
              ApiClient.instance.playletCommentReplies(
                widget.seriesId,
                widget.comment.id,
                count: 5,
                cursor: requestedCursor,
                refReplyId: refReplyId,
              ));
      if (!mounted) return;
      setState(() {
        final replies = List.of(page.replies);
        // 定点读命中时把目标楼层提到父楼层之后（`c0()` 插入位置 i2）。
        if (pinnedFirst && replies.length > 1) {
          replies.sort((a, b) {
            final aFocus = a.id == widget.focusReplyId;
            final bFocus = b.id == widget.focusReplyId;
            if (aFocus == bFocus) return 0;
            return aFocus ? -1 : 1;
          });
        }
        final ids = _replies.map((reply) => reply.id).toSet();
        _replies.addAll(replies.where((reply) => reply.id.isEmpty || ids.add(reply.id)));
        if (page.totalCount > 0) _total = page.totalCount;
        _cursor = page.cursor;
        _hasMore =
            page.hasMore && _cursor.isNotEmpty && _cursor != requestedCursor;
        _loading = false;
      });
    } catch (error) {
      // 定点读失败：官方 onErrorReturn 让 B 请求退化为空、仅剩普通
      // 列表。这里回退一次不带 ref_reply_id 的普通请求。
      if (pinnedFirst) {
        _useFocus = false;
        if (mounted) {
          setState(() {
            _loading = false;
            _error = null;
          });
          unawaited(_load());
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          IconButton(
            key: const ValueKey('playlet-replies-back'),
            tooltip: '返回剧评',
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          ),
          Expanded(
            child: Text(
              _total > 0 ? '回复（$_total）' : '回复',
              key: const ValueKey('playlet-replies-title'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B1B1B),
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            key: const ValueKey('playlet-replies-close'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, color: Color(0xFF9499A0)),
          ),
        ],
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.builder(
          key: const ValueKey('playlet-reply-list'),
          controller: _scroll,
          itemCount: _replies.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              final parent = widget.comment;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PlayletDiscussionTile(
                    key: const ValueKey('playlet-reply-parent'),
                    text: parent.text,
                    userName: parent.userName,
                    userAvatar: parent.userAvatar,
                    published: parent.relativeTime(),
                    diggCount: parent.diggCount,
                  ),
                  const Divider(
                    height: 16,
                    thickness: 6,
                    color: Color(0xFFF5F5F7),
                  ),
                ],
              );
            }
            if (index > _replies.length) return _footer();
            final reply = _replies[index - 1];
            return PlayletDiscussionTile(
              key: ValueKey('playlet-reply-${reply.id}'),
              text: reply.text,
              userName: reply.userName,
              userAvatar: reply.userAvatar,
              published: reply.relativeTime(),
              diggCount: reply.diggCount,
            );
          },
        ),
      ),
    ],
  );

  Widget _footer() => Padding(
    padding: const EdgeInsets.all(16),
    child: Center(
      child: _loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _error != null
          ? TextButton(
              key: const ValueKey('playlet-replies-retry'),
              onPressed: () => unawaited(_load()),
              child: const Text('回复加载失败，点击重试'),
            )
          : _hasMore
          ? TextButton(
              key: const ValueKey('playlet-replies-more'),
              onPressed: () => unawaited(_load()),
              child: const Text('加载更多回复'),
            )
          : _replies.isEmpty
          ? const Text('暂无回复', style: TextStyle(color: Color(0xFF9499A0)))
          : const SizedBox.shrink(),
    ),
  );
}
