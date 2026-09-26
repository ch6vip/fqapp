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
    });

/// 官方剧评详情中的回复列表。保持同一个面板高度，返回时保留剧评排序和滚动位置。
class PlayletReplyPanel extends StatefulWidget {
  const PlayletReplyPanel({
    super.key,
    required this.seriesId,
    required this.comment,
    required this.onBack,
    this.loader,
  });

  final String seriesId;
  final PlayletComment comment;
  final VoidCallback onBack;
  final PlayletReplyPageLoader? loader;

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

  @override
  void initState() {
    super.initState();
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
    try {
      final page =
          await (widget.loader?.call(
                commentId: widget.comment.id,
                count: 10,
                cursor: requestedCursor,
              ) ??
              ApiClient.instance.playletCommentReplies(
                widget.seriesId,
                widget.comment.id,
                count: 10,
                cursor: requestedCursor,
              ));
      if (!mounted) return;
      setState(() {
        final ids = _replies.map((reply) => reply.id).toSet();
        _replies.addAll(
          page.replies.where((reply) => reply.id.isEmpty || ids.add(reply.id)),
        );
        if (page.totalCount > 0) _total = page.totalCount;
        _cursor = page.cursor;
        _hasMore =
            page.hasMore && _cursor.isNotEmpty && _cursor != requestedCursor;
        _loading = false;
      });
    } catch (error) {
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
