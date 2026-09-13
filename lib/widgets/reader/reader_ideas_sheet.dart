import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../models/chapter_ideas.dart';
import '../../services/reader_preferences.dart';
import '../home/home_design.dart';
import 'reader_theme.dart';

/// Comments for the paragraph whose bubble was tapped.
///
/// Note: the supplied official screenshot defines the sheet layout — see
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
class ReaderIdeasSheet extends StatefulWidget {
  final ChapterIdeas ideas;

  /// Loads one page of the paragraph's comments. [cursor] is the previous
  /// page's offset, null on the first request.
  final Future<BookCommentPage> Function(
    ParagraphIdeas paragraph,
    String? cursor,
  )
  loadComments;
  final ReaderThemePreset preset;
  final int? initialParaIndex;

  const ReaderIdeasSheet({
    super.key,
    required this.ideas,
    required this.loadComments,
    required this.preset,
    this.initialParaIndex,
  });

  @override
  State<ReaderIdeasSheet> createState() => _ReaderIdeasSheetState();
}

class _ReaderIdeasSheetState extends State<ReaderIdeasSheet> {
  ParagraphIdeas? _paragraph;
  BookCommentPage? _page;

  /// Lifecycle of the next page: nothing in flight ([_MoreStatus.idle]), the
  /// request is out ([_MoreStatus.fetching]), the result is waiting for the
  /// fling to end ([_MoreStatus.held]), or the last request failed
  /// ([_MoreStatus.failed]).
  _MoreStatus _moreStatus = _MoreStatus.idle;
  BookCommentPage? _heldPage;

  bool _loading = false;
  bool _failed = false;
  final ScrollController _scroll = ScrollController();

  Color get _textColor =>
      widget.preset.isDark ? widget.preset.textColor : const Color(0xFF111111);

  Color get _mutedColor => const Color(0xFF999999);

  bool get _nearEnd => _scroll.hasClients && _scroll.position.extentAfter < 400;

  @override
  void initState() {
    super.initState();
    final paragraphs = widget.ideas.withIdeas;
    if (paragraphs.isEmpty) return;
    _paragraph = paragraphs.firstWhere(
      (paragraph) => paragraph.paraIndex == widget.initialParaIndex,
      orElse: () => paragraphs.first,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Pagination runs on scroll notifications only. The request goes out as soon
  /// as the footer comes into view, hiding the network latency under the
  /// ongoing motion; the append itself waits for the motion to stop — laying
  /// out twenty fresh rows mid-fling shows up as a dropped frame (measured
  /// 28-41ms in the frame-cost test).
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      unawaited(_settleAfterScroll());
    } else if (_moreStatus == _MoreStatus.idle &&
        _page != null &&
        _page!.hasMore &&
        notification.metrics.extentAfter < 400) {
      unawaited(_fetchNextPage());
    }
    return false;
  }

  /// Runs once the motion has stopped: apply a held page, then keep feeding
  /// pages while the reader stays parked near the end of the list.
  Future<void> _settleAfterScroll() async {
    if (!mounted) return;
    if (_moreStatus == _MoreStatus.held) {
      final held = _heldPage!;
      _heldPage = null;
      setState(() {
        _mergePage(held);
        _moreStatus = _MoreStatus.idle;
      });
    }
    // After the first page the list may not be built yet at this point (the
    // spinner shows instead), so the near-end check waits for the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_moreStatus == _MoreStatus.idle &&
          _page != null &&
          _page!.hasMore &&
          _nearEnd) {
        unawaited(_fetchNextPage());
      }
    });
  }

  Future<void> _load() async {
    final paragraph = _paragraph;
    if (paragraph == null || _loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.loadComments(paragraph, null);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
      });
      unawaited(_settleAfterScroll());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _fetchNextPage() async {
    final paragraph = _paragraph;
    final page = _page;
    if (paragraph == null || page == null || !page.hasMore) return;
    // failed means the retry button asked for this same page again.
    if (_moreStatus == _MoreStatus.fetching ||
        _moreStatus == _MoreStatus.held ||
        _loading) {
      return;
    }
    setState(() => _moreStatus = _MoreStatus.fetching);
    try {
      final next = await widget.loadComments(paragraph, '${page.nextOffset}');
      if (!mounted) return;
      if (Scrollable.recommendDeferredLoadingForContext(context) && _nearEnd) {
        // Still flinging fast: hold the rows so the append lands in an idle
        // frame. The spinner keeps turning as the "more coming" signal.
        setState(() {
          _heldPage = next;
          _moreStatus = _MoreStatus.held;
        });
        return;
      }
      setState(() {
        _mergePage(next);
        _moreStatus = _MoreStatus.idle;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _moreStatus = _MoreStatus.failed);
    }
  }

  /// Upstream pages never overlap, but a defensive merge keeps the list stable
  /// if the backend ever echoes the last item. Called inside setState.
  void _mergePage(BookCommentPage next) {
    final page = _page!;
    final seen = page.comments.map((c) => c.id).toSet();
    _page = BookCommentPage(
      comments: List.unmodifiable([
        ...page.comments,
        ...next.comments.where((c) => !seen.contains(c.id)),
      ]),
      totalCount: next.totalCount,
      hasMore: next.hasMore,
      nextOffset: next.nextOffset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = (_page?.totalCount ?? 0) > 0
        ? _page!.totalCount
        : _paragraph?.count ?? 0;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 56),
                  child: Text(
                    '$total条评论',
                    key: const Key('reader-ideas-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _textColor,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: IconButton(
                      key: const Key('reader-ideas-close'),
                      tooltip: '收起评论',
                      onPressed: () => Navigator.pop(context),
                      color: _textColor,
                      iconSize: 26,
                      icon: const Icon(LucideIcons.chevron_down),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _commentArea()),
        ],
      ),
    );
  }

  Widget _commentArea() {
    if (_loading) {
      return Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: _mutedColor),
        ),
      );
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('评论加载失败', style: TextStyle(color: _mutedColor, fontSize: 13)),
            TextButton(
              onPressed: _load,
              child: Text('重试', style: TextStyle(color: _textColor)),
            ),
          ],
        ),
      );
    }
    final comments = _page?.comments ?? const <BookComment>[];
    if (comments.isEmpty) {
      return Center(
        child: Text(
          _paragraph == null ? '本章还没有段评' : '暂无评论',
          style: TextStyle(color: _mutedColor, fontSize: 13),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        key: const Key('reader-ideas-comments'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        // One extra footer slot while more pages exist or the last fetch failed.
        itemCount:
            comments.length +
            ((_page!.hasMore || _moreStatus == _MoreStatus.failed) ? 1 : 0),
        addAutomaticKeepAlives: false,
        itemBuilder: (context, index) {
          if (index >= comments.length) {
            return _moreFooter();
          }
          return _CommentRow(
            comment: comments[index],
            textColor: _textColor,
            mutedColor: _mutedColor,
          );
        },
      ),
    );
  }

  /// Bottom slot: a thin spinner while the next page loads, a retry label when
  /// it failed, nothing when the paragraph is exhausted.
  Widget _moreFooter() {
    if (_moreStatus == _MoreStatus.fetching ||
        _moreStatus == _MoreStatus.held) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _mutedColor,
            ),
          ),
        ),
      );
    }
    if (_moreStatus == _MoreStatus.failed) {
      return Center(
        child: TextButton(
          onPressed: () => unawaited(_fetchNextPage()),
          child: Text('加载失败，点击重试', style: TextStyle(color: _textColor)),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Lifecycle of the next page request; see [_onScrollNotification].
enum _MoreStatus { idle, fetching, held, failed }

/// Avatar beside the name and body; date, reply and reactions below the body.
class _CommentRow extends StatelessWidget {
  final BookComment comment;
  final Color textColor;
  final Color mutedColor;

  const _CommentRow({
    required this.comment,
    required this.textColor,
    required this.mutedColor,
  });

  Widget _avatarFallback() => ColoredBox(
    color: mutedColor.withValues(alpha: 0.12),
    child: Icon(LucideIcons.user, size: 18, color: mutedColor),
  );

  @override
  Widget build(BuildContext context) {
    final time = comment.paragraphTime();
    final metaStyle = TextStyle(color: mutedColor, fontSize: 12.5, height: 1.3);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox.square(
              dimension: 32,
              child: comment.userAvatar.isEmpty
                  ? _avatarFallback()
                  : Image.network(
                      comment.userAvatar,
                      fit: BoxFit.cover,
                      // The upstream serves 144px avatars for a 32dp slot;
                      // decode once at the display size instead of keeping
                      // full-size surfaces alive for every row.
                      cacheWidth: (32 * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low,
                      frameBuilder: (context, child, frame, _) =>
                          frame == null ? _avatarFallback() : child,
                      errorBuilder: (context, _, _) => _avatarFallback(),
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
                        comment.userName.isEmpty ? '读者' : comment.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: mutedColor,
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                    ),
                    if (comment.isAuthor) ...[
                      const SizedBox(width: 5),
                      const Text(
                        '作者',
                        style: TextStyle(
                          color: HomePalette.accent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  comment.text,
                  style: TextStyle(color: textColor, fontSize: 16, height: 1.5),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (time.isNotEmpty) Text(time, style: metaStyle),
                          Text(
                            comment.replyCount > 0
                                ? '回复 ${formatCount(comment.replyCount)}'
                                : '回复',
                            style: metaStyle,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // The backend exposes counts but no reaction writes. Keep
                    // these as read-only indicators, without fake tap handlers.
                    Semantics(
                      label: '${comment.diggCount}人点赞',
                      excludeSemantics: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.heart, size: 20, color: mutedColor),
                          const SizedBox(width: 5),
                          Text(
                            comment.diggCount > 0
                                ? formatCount(comment.diggCount)
                                : '点赞',
                            style: metaStyle,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Icon(
                      LucideIcons.heart_crack,
                      size: 20,
                      color: mutedColor,
                      semanticLabel: '不喜欢',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
