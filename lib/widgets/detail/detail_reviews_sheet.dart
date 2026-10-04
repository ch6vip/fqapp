import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../services/api_client.dart';
import '../home/home_design.dart';
import 'detail_reviews.dart';

/// 呼出全部书评全屏/半屏抽屉面板（虚拟化懒加载列表，高帧率无卡顿）。
Future<void> showDetailReviewsSheet(
  BuildContext context, {
  required String bookId,
  required String title,
  required BookCommentPage initialComments,
  ReviewReplyLoader? replyLoader,
  Future<BookCommentPage> Function(int offset)? loader,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: HomePalette.of(context).canvas,
  barrierColor: Colors.black.withValues(alpha: 0.45),
  clipBehavior: Clip.antiAlias,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 300),
          reverseDuration: Duration(milliseconds: 220),
        ),
  builder: (context) => DetailReviewsSheet(
    bookId: bookId,
    title: title,
    initialComments: initialComments,
    replyLoader: replyLoader,
    loader: loader,
  ),
);

class DetailReviewsSheet extends StatefulWidget {
  final String bookId;
  final String title;
  final BookCommentPage initialComments;
  final ReviewReplyLoader? replyLoader;
  final Future<BookCommentPage> Function(int offset)? loader;

  const DetailReviewsSheet({
    super.key,
    required this.bookId,
    required this.title,
    required this.initialComments,
    this.replyLoader,
    this.loader,
  });

  @override
  State<DetailReviewsSheet> createState() => _DetailReviewsSheetState();
}

class _DetailReviewsSheetState extends State<DetailReviewsSheet> {
  final ScrollController _scroll = ScrollController();
  late List<BookComment> _comments;
  late int _total;
  late int _nextOffset;
  late bool _hasMore;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _comments = List.of(widget.initialComments.comments);
    _total = widget.initialComments.totalCount;
    _nextOffset = widget.initialComments.nextOffset;
    _hasMore = widget.initialComments.hasMore;

    _scroll.addListener(_onScroll);
    if (_comments.isEmpty && _hasMore) {
      _loadMore();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loading || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final BookCommentPage page;
      if (widget.loader != null) {
        page = await widget.loader!(_nextOffset);
      } else {
        page = await ApiClient.instance.bookComments(
          widget.bookId,
          offset: _nextOffset,
          count: 20,
        );
      }
      if (!mounted) return;
      setState(() {
        _comments.addAll(page.comments);
        _total = page.totalCount > 0 ? page.totalCount : _total;
        _nextOffset = page.nextOffset;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载书评失败，点击重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.82;

    return SizedBox(
      height: height,
      child: Column(
        children: [
          // 顶部拖拽指示条
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: palette.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _total > 0 ? '全部书评 · $_total' : '全部书评',
                        style: TextStyle(
                          color: palette.ink,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      if (widget.title.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.muted, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(LucideIcons.x, color: palette.muted, size: 20),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.line),
          // 虚拟化评论列表
          Expanded(
            child: _comments.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.message_square,
                          size: 40,
                          color: palette.muted,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _error ?? '暂无书评',
                          style: TextStyle(color: palette.muted, fontSize: 14),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _loadMore,
                            child: const Text('重试'),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    itemCount:
                        _comments.length + (_hasMore || _loading ? 1 : 0),
                    separatorBuilder: (context, index) =>
                        Divider(height: 1, color: palette.line),
                    itemBuilder: (context, index) {
                      if (index >= _comments.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: Center(
                            child: _loading
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : TextButton(
                                    onPressed: _loadMore,
                                    child: Text(
                                      _error ?? '加载更多',
                                      style: TextStyle(color: palette.muted),
                                    ),
                                  ),
                          ),
                        );
                      }
                      return DetailCommentTile(
                        key: ValueKey('sheet_review_${_comments[index].id}'),
                        comment: _comments[index],
                        replyLoader: widget.replyLoader,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
