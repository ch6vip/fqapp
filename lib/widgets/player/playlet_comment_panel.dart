/// 短剧评论面板（竖屏底部弹窗）。
///
/// 官方形态（`CommentDialogHelper` + `gx1/n0`）：
/// - Dialog / bottom sheet，面板高度 ≈ 屏幕高 × 系数（`CommentDialogHelper.java:473-483`）
/// - 顶部筛选：客户端硬插「全部 / 最新」，其后是服务端标签
///   （`gx1/n0.java:871-902`）；「全部」= `UgcSort.smartHot`，「最新」= `timeDesc`
/// - 列表游标分页：首页 `count=10, need_count=true`，加载更多带 cursor
/// - 空态文案随计数变化（`gx1/n0.java:698-708`）
/// - 列表项：头像 + 昵称 + 正文 + 时间 + 点赞/回复计数
///
/// 官方把评论入口整体默认 gone（`res/layout/cjs.xml:11`），显示条件未取证，
/// 因此本面板只在宿主明确传入 seriesId 时打开。
///
/// 证据见 .agents/notes/proposed/architecture/2026-09-25-f04-official-evidence.md。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/book_comment.dart' show formatCount;
import '../../models/playlet_comment.dart';
import '../../services/api_client.dart';
import 'playlet_discussion_tile.dart';
import 'playlet_reply_panel.dart';

/// 一次「加载一页」的请求：宿主注入，测试可替身。
typedef PlayletCommentPageLoader =
    Future<PlayletCommentPage> Function({
      required int sort,
      required int count,
      required String cursor,
      required String tag,
    });

class PlayletCommentPanel extends StatefulWidget {
  const PlayletCommentPanel({
    super.key,
    required this.seriesId,
    this.loader,
    this.initialTotal = 0,
    this.focusCommentId = '',
    this.replyLoader,
  });

  final String seriesId;

  /// 缺省走 `ApiClient.playletComments`。
  final PlayletCommentPageLoader? loader;

  /// 宿主已知的评论数（官方入口计数同源），用于首屏空态文案。
  final int initialTotal;

  /// 官方从热评进入评论时带 `hot_comment_id`/`hot_reply_id`
  /// （`SeriesHotCommentView.java:468-559`）。本地等价：用
  /// `insert_comment_ids` 让服务端把这条插进列表，页面里高亮它。
  final String focusCommentId;
  final PlayletReplyPageLoader? replyLoader;

  /// 打开面板：官方入口在右侧竖栏，竖屏走底部弹窗。
  static Future<void> show(
    BuildContext context, {
    required String seriesId,
    PlayletCommentPageLoader? loader,
    int total = 0,
    String focusCommentId = '',
    PlayletReplyPageLoader? replyLoader,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => PlayletCommentPanel(
      seriesId: seriesId,
      loader: loader,
      initialTotal: total,
      focusCommentId: focusCommentId,
      replyLoader: replyLoader,
    ),
  );

  @override
  State<PlayletCommentPanel> createState() => _PlayletCommentPanelState();
}

class _PlayletCommentPanelState extends State<PlayletCommentPanel> {
  final _scroll = ScrollController();
  final List<PlayletComment> _comments = [];

  /// 官方筛选：第 0 位「全部」（SmartHot）、第 1 位「最新」（TimeDesc），
  /// 服务端标签接在其后（`gx1/n0.java:871-902`）。
  static const _fixedFilters = <_FilterOption>[
    _FilterOption(label: '全部', sort: UgcSort.smartHot),
    _FilterOption(label: '最新', sort: UgcSort.timeDesc),
  ];

  int _sort = UgcSort.smartHot;
  String _tag = '';
  String _cursor = '';
  int? _total;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  int _generation = 0;
  PlayletComment? _replyTarget;

  @override
  void initState() {
    super.initState();
    _total = widget.initialTotal > 0 ? widget.initialTotal : null;
    _scroll.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<PlayletCommentPage> _fetch({
    required int sort,
    required int count,
    required String cursor,
    required String tag,
  }) {
    final loader = widget.loader;
    if (loader != null) {
      return loader(sort: sort, count: count, cursor: cursor, tag: tag);
    }
    return ApiClient.instance.playletComments(
      widget.seriesId,
      sort: sort,
      count: count,
      cursor: cursor,
      tag: tag,
      // 官方从热评进来时带 `hot_comment_id`（`gx1/m.java:236-241`），
      // 本地等价是 `insert_comment_ids`；只在首页（cursor 为空）带。
      insertCommentIds: cursor.isEmpty ? widget.focusCommentId : '',
    );
  }

  /// 官方分页：首页整表替换，加载更多按 cursor 追加。
  Future<void> _load({required bool reset}) async {
    if (!reset && (_loading || !_hasMore)) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _comments.clear();
        _cursor = '';
        _hasMore = true;
      }
    });

    final generation = ++_generation;
    final requestedCursor = reset ? '' : _cursor;
    try {
      final page = await _fetch(
        sort: _sort,
        count: 10,
        cursor: requestedCursor,
        tag: _tag,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) {
          _comments
            ..clear()
            ..addAll(page.comments);
        } else {
          final ids = _comments.map((comment) => comment.id).toSet();
          _comments.addAll(
            page.comments.where(
              (comment) => comment.id.isEmpty || ids.add(comment.id),
            ),
          );
        }
        _total = page.totalCount > 0 ? page.totalCount : _total;
        _cursor = page.cursor;
        _hasMore =
            page.hasMore &&
            page.cursor.isNotEmpty &&
            page.cursor != requestedCursor;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_hasMore || _error != null) return;
    final threshold = _scroll.position.maxScrollExtent - 240;
    if (_scroll.position.pixels >= threshold) {
      unawaited(_load(reset: false));
    }
  }

  void _selectFilter(_FilterOption option) {
    if (_sort == option.sort && _tag == option.tag) return;
    setState(() {
      _sort = option.sort;
      _tag = option.tag;
    });
    unawaited(_load(reset: true));
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final replyTarget = _replyTarget;
    if (replyTarget != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) setState(() => _replyTarget = null);
        },
        child: SizedBox(
          height: height * .62,
          child: PlayletReplyPanel(
            key: ValueKey(replyTarget.id),
            seriesId: widget.seriesId,
            comment: replyTarget,
            loader: widget.replyLoader,
            onBack: () => setState(() => _replyTarget = null),
          ),
        ),
      );
    }
    return SizedBox(
      // 官方高度是屏幕高 × 系数（CommentDialogHelper.java:473-483）；竖屏用
      // 0.62 作为该系数在本布局下的等价，避免顶到状态栏。
      height: height * .62,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          _filters(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
    child: Row(
      children: [
        const Text(
          '剧评',
          key: ValueKey('playlet-comment-title'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1B1B1B),
          ),
        ),
        const SizedBox(width: 8),
        if (_total != null && _total! > 0)
          Text(
            formatCount(_total!),
            key: const ValueKey('playlet-comment-total'),
            style: const TextStyle(fontSize: 13, color: Color(0xFF9499A0)),
          ),
        const Spacer(),
        IconButton(
          key: const ValueKey('playlet-comment-close'),
          tooltip: '关闭',
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(
            Icons.close_rounded,
            size: 20,
            color: Color(0xFF9499A0),
          ),
        ),
      ],
    ),
  );

  Widget _filters() => SizedBox(
    height: 40,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [for (final option in _fixedFilters) _filterChip(option)],
    ),
  );

  Widget _filterChip(_FilterOption option) {
    final selected = _sort == option.sort && _tag == option.tag;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: GestureDetector(
        key: ValueKey('playlet-comment-filter-${option.label}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectFilter(option),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // 官方选中样式：橙字 #FFFA6725 + 浅橙底 #1AFA6725。
            color: selected ? const Color(0x1AFA6725) : const Color(0xFFF5F5F7),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            option.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected
                  ? const Color(0xFFFA6725)
                  : const Color(0xFF61656B),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_comments.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_comments.isEmpty && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('评论加载失败', style: TextStyle(color: Color(0xFF9499A0))),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('playlet-comment-retry'),
              onPressed: () => unawaited(_load(reset: true)),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return Center(
        child: Text(
          PlayletCommentPage(totalCount: _total ?? 0).emptyText,
          key: const ValueKey('playlet-comment-empty'),
          style: const TextStyle(color: Color(0xFF9499A0)),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('playlet-comment-list'),
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _comments.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _comments.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      key: const ValueKey('playlet-comment-more'),
                      onPressed: () => unawaited(_load(reset: false)),
                      child: Text(_error == null ? '加载更多' : '加载失败，点击重试'),
                    ),
            ),
          );
        }
        return _tile(_comments[index]);
      },
    );
  }

  Widget _tile(PlayletComment comment) => PlayletDiscussionTile(
    key: ValueKey('playlet-comment-${comment.id}'),
    text: comment.text,
    userName: comment.userName,
    userAvatar: comment.userAvatar,
    published: comment.relativeTime(),
    diggCount: comment.diggCount,
    replyCount: comment.replyCount,
    highlighted: comment.id == widget.focusCommentId,
    onReplies: comment.id.isEmpty
        ? null
        : () => setState(() => _replyTarget = comment),
  );
}

class _FilterOption {
  const _FilterOption({required this.label, required this.sort});

  final String label;
  final int sort;

  String get tag => '';
}
