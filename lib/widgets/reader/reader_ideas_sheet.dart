import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../models/chapter_ideas.dart';
import '../../services/reader_preferences.dart';
import '../home/home_design.dart';
import 'reader_theme.dart';

/// The paragraph-comment panel.
///
/// Laid out like the official one, which shows **one paragraph's comments** as a
/// flat list rather than a chapter-wide index: a title, the 全部/最新 filter the
/// official client calls `comment_filter_id_all` / `comment_filter_id_new`, the
/// paragraph being discussed, then the comment list. See
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
///
/// The official panel also carries a bottom publish bar (`趣评千万条，你也来一条`).
/// It is deliberately absent here: the backend exposes no write endpoint, so it
/// would be a control that cannot do anything.
class ReaderIdeasSheet extends StatefulWidget {
  final ChapterIdeas ideas;

  /// Paragraph text by paragraph id, used as the context for the comments.
  final Map<int, String> paragraphTexts;

  /// Resolves comment bodies for one paragraph.
  final Future<BookCommentPage> Function(ParagraphIdeas paragraph) loadComments;

  final ReaderThemePreset preset;

  /// Paragraph to show first: the one whose bubble was tapped.
  final int? initialParaIndex;

  const ReaderIdeasSheet({
    super.key,
    required this.ideas,
    required this.paragraphTexts,
    required this.loadComments,
    required this.preset,
    this.initialParaIndex,
  });

  @override
  State<ReaderIdeasSheet> createState() => _ReaderIdeasSheetState();
}

/// The official filter ids, kept as the two labels it shows.
enum _Filter {
  all('全部'),
  newest('最新');

  const _Filter(this.label);

  final String label;
}

class _ReaderIdeasSheetState extends State<ReaderIdeasSheet> {
  final _bodies = <int, BookCommentPage>{};
  final _loading = <int>{};
  final _failed = <int>{};
  int? _paraIndex;
  _Filter _filter = _Filter.all;

  List<ParagraphIdeas> get _paragraphs => widget.ideas.withIdeas;

  @override
  void initState() {
    super.initState();
    final paragraphs = _paragraphs;
    if (paragraphs.isEmpty) return;
    final wanted = widget.initialParaIndex;
    _paraIndex = paragraphs.any((p) => p.paraIndex == wanted)
        ? wanted
        : paragraphs.first.paraIndex;
    unawaited(_load(_paraIndex!));
  }

  Future<void> _load(int paraIndex) async {
    if (_bodies.containsKey(paraIndex) || _loading.contains(paraIndex)) return;
    final paragraph = _paragraph(paraIndex);
    if (paragraph == null) return;
    setState(() => _loading.add(paraIndex));
    try {
      final page = await widget.loadComments(paragraph);
      if (!mounted) return;
      setState(() {
        _bodies[paraIndex] = page;
        _loading.remove(paraIndex);
      });
    } catch (_) {
      // A decoration must not break the panel, and loaders may surface either an
      // Exception or an Error.
      if (!mounted) return;
      setState(() {
        _failed.add(paraIndex);
        _loading.remove(paraIndex);
      });
    }
  }

  ParagraphIdeas? _paragraph(int paraIndex) {
    for (final paragraph in _paragraphs) {
      if (paragraph.paraIndex == paraIndex) return paragraph;
    }
    return null;
  }

  void _select(int paraIndex) {
    if (paraIndex == _paraIndex) return;
    setState(() => _paraIndex = paraIndex);
    unawaited(_load(paraIndex));
  }

  /// `全部` keeps the upstream order (the service answers by hotness);
  /// `最新` orders by publish time. The backend has no sort parameter on the
  /// body-resolution path, so the ordering is applied here.
  List<BookComment> _ordered(BookCommentPage page) {
    if (_filter != _Filter.newest) return page.comments;
    final ordered = [...page.comments];
    ordered.sort((a, b) {
      final left = a.createdAt;
      final right = b.createdAt;
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return right.compareTo(left);
    });
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final paragraphs = _paragraphs;
    final selected = _paraIndex;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(preset),
          if (paragraphs.length > 1) _paragraphStrip(preset, paragraphs),
          _filterRow(preset),
          if (selected != null) _quote(preset, selected),
          Divider(height: 1, color: preset.borderColor),
          Expanded(child: _commentArea(preset, selected)),
        ],
      ),
    );
  }

  Widget _header(ReaderThemePreset preset) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 2, 12, 10),
    child: Row(
      children: [
        Text(
          '段评',
          style: TextStyle(
            color: preset.textColor,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '共 ${widget.ideas.total} 条 · ${_paragraphs.length} 段',
            style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
          ),
        ),
        IconButton(
          key: const Key('reader-ideas-close'),
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          style: IconButton.styleFrom(
            foregroundColor: preset.mutedTextColor,
            minimumSize: const Size(44, 44),
          ),
          icon: const Icon(LucideIcons.x, size: 19),
        ),
      ],
    ),
  );

  /// Only shown when the chapter has several commented paragraphs, so a reader
  /// can move between them without going back to the text.
  Widget _paragraphStrip(
    ReaderThemePreset preset,
    List<ParagraphIdeas> paragraphs,
  ) => SizedBox(
    height: 40,
    child: ListView.separated(
      key: const Key('reader-ideas-paragraphs'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: paragraphs.length,
      separatorBuilder: (context, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final paragraph = paragraphs[index];
        final active = paragraph.paraIndex == _paraIndex;
        return Center(
          child: GestureDetector(
            key: ValueKey('reader-idea-${paragraph.paraIndex}'),
            onTap: () => _select(paragraph.paraIndex),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: active
                    ? HomePalette.accent
                    : preset.textColor.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '第 ${paragraph.paraIndex + 1} 段 · ${paragraph.count}',
                style: TextStyle(
                  color: active ? Colors.white : preset.mutedTextColor,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _filterRow(ReaderThemePreset preset) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
    child: Row(
      children: [
        for (final filter in _Filter.values) ...[
          GestureDetector(
            key: ValueKey('reader-ideas-filter-${filter.name}'),
            onTap: () => setState(() => _filter = filter),
            child: Padding(
              padding: const EdgeInsets.only(right: 16, top: 6, bottom: 6),
              child: Text(
                filter.label,
                style: TextStyle(
                  color: _filter == filter
                      ? preset.textColor
                      : preset.mutedTextColor,
                  fontSize: 13.5,
                  fontWeight: _filter == filter
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );

  /// The paragraph the comments belong to, so the list has context.
  Widget _quote(ReaderThemePreset preset, int paraIndex) {
    final text = widget.paragraphTexts[paraIndex] ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: preset.textColor.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          key: const Key('reader-ideas-quote'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: preset.mutedTextColor,
            fontSize: 12.5,
            height: 1.6,
          ),
        ),
      ),
    );
  }

  Widget _commentArea(ReaderThemePreset preset, int? paraIndex) {
    if (paraIndex == null) {
      return Center(
        child: Text('本章还没有段评', style: TextStyle(color: preset.mutedTextColor)),
      );
    }
    if (_loading.contains(paraIndex)) {
      return const Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_failed.contains(paraIndex)) {
      return Center(
        child: Text(
          '段评暂时无法加载',
          style: TextStyle(color: preset.mutedTextColor, fontSize: 13),
        ),
      );
    }
    final page = _bodies[paraIndex];
    if (page == null) return const SizedBox.shrink();
    final comments = _ordered(page);
    if (comments.isEmpty) {
      return Center(
        child: Text(
          '这段还没有可显示的段评',
          style: TextStyle(color: preset.mutedTextColor, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      key: const Key('reader-ideas-comments'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      itemCount: comments.length,
      itemBuilder: (context, index) =>
          _CommentRow(comment: comments[index], preset: preset),
    );
  }
}

/// One comment: avatar, name, time, body, then the digg and reply counts.
class _CommentRow extends StatelessWidget {
  final BookComment comment;
  final ReaderThemePreset preset;

  const _CommentRow({required this.comment, required this.preset});

  @override
  Widget build(BuildContext context) {
    final time = comment.relativeTime();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: 32,
                  child: comment.userAvatar.isEmpty
                      ? ColoredBox(
                          color: preset.textColor.withValues(alpha: 0.08),
                          child: Icon(
                            LucideIcons.user,
                            size: 16,
                            color: preset.mutedTextColor,
                          ),
                        )
                      : Image.network(
                          comment.userAvatar,
                          fit: BoxFit.cover,
                          errorBuilder: (context, _, _) => ColoredBox(
                            color: preset.textColor.withValues(alpha: 0.08),
                            child: Icon(
                              LucideIcons.user,
                              size: 16,
                              color: preset.mutedTextColor,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
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
                              color: preset.mutedTextColor,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (comment.isAuthor) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: HomePalette.accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              '作者',
                              style: TextStyle(
                                color: HomePalette.accent,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        if (time.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            time,
                            style: TextStyle(
                              color: preset.mutedTextColor,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      comment.text,
                      style: TextStyle(
                        color: preset.textColor,
                        fontSize: 13.5,
                        height: 1.65,
                      ),
                    ),
                    if (comment.diggCount > 0 || comment.replyCount > 0) ...[
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          if (comment.diggCount > 0)
                            Text(
                              '赞 ${comment.diggCount}',
                              style: TextStyle(
                                color: preset.mutedTextColor,
                                fontSize: 11,
                              ),
                            ),
                          if (comment.diggCount > 0 && comment.replyCount > 0)
                            const SizedBox(width: 14),
                          if (comment.replyCount > 0)
                            Text(
                              '回复 ${comment.replyCount}',
                              style: TextStyle(
                                color: preset.mutedTextColor,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
