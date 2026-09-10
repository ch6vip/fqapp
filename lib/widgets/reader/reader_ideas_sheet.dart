import 'package:flutter/material.dart';

import '../../models/book_comment.dart';
import '../../models/chapter_ideas.dart';
import '../../services/reader_preferences.dart';
import '../home/home_design.dart';
import 'reader_theme.dart';

/// Bottom sheet listing a chapter's ideas (段评) grouped by paragraph.
///
/// The idea list only carries counts and comment ids, so bodies are fetched
/// lazily: expanding a paragraph resolves its ids through [loadComments].
class ReaderIdeasSheet extends StatefulWidget {
  final ChapterIdeas ideas;

  /// Paragraph text by paragraph id, used as the row context so a reader can
  /// tell which paragraph a comment belongs to.
  final Map<int, String> paragraphTexts;

  /// Resolves comment bodies for one paragraph.
  final Future<BookCommentPage> Function(ParagraphIdeas paragraph) loadComments;

  final ReaderThemePreset preset;

  const ReaderIdeasSheet({
    super.key,
    required this.ideas,
    required this.paragraphTexts,
    required this.loadComments,
    required this.preset,
  });

  @override
  State<ReaderIdeasSheet> createState() => _ReaderIdeasSheetState();
}

class _ReaderIdeasSheetState extends State<ReaderIdeasSheet> {
  final _expanded = <int>{};
  final _loading = <int>{};
  final _bodies = <int, BookCommentPage>{};
  final _failed = <int>{};

  Future<void> _toggle(ParagraphIdeas paragraph) async {
    setState(() {
      if (!_expanded.remove(paragraph.paraIndex)) {
        _expanded.add(paragraph.paraIndex);
      }
    });
    if (!_expanded.contains(paragraph.paraIndex)) return;
    if (_bodies.containsKey(paragraph.paraIndex) ||
        _loading.contains(paragraph.paraIndex)) {
      return;
    }
    setState(() => _loading.add(paragraph.paraIndex));
    try {
      final page = await widget.loadComments(paragraph);
      if (!mounted) return;
      setState(() {
        _bodies[paragraph.paraIndex] = page;
        _loading.remove(paragraph.paraIndex);
      });
    } catch (_) {
      // Catch everything: a decoration must not break the sheet, and loaders
      // may surface either an Exception or an Error.
      if (!mounted) return;
      setState(() {
        _failed.add(paragraph.paraIndex);
        _loading.remove(paragraph.paraIndex);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final paragraphs = widget.ideas.withIdeas;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
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
                Text(
                  '共 ${widget.ideas.total} 条 · ${paragraphs.length} 段',
                  style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: preset.borderColor),
          Expanded(
            child: paragraphs.isEmpty
                ? Center(
                    child: Text(
                      '本章还没有段评',
                      style: TextStyle(color: preset.mutedTextColor),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: paragraphs.length,
                    itemBuilder: (context, index) =>
                        _paragraphTile(paragraphs[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _paragraphTile(ParagraphIdeas paragraph) {
    final preset = widget.preset;
    final open = _expanded.contains(paragraph.paraIndex);
    final context_ = widget.paragraphTexts[paragraph.paraIndex] ?? '';
    final page = _bodies[paragraph.paraIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: ValueKey('reader-idea-${paragraph.paraIndex}'),
          onTap: () => _toggle(paragraph),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context_.isEmpty
                            ? '第 ${paragraph.paraIndex + 1} 段'
                            : context_,
                        maxLines: open ? 4 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: preset.textColor,
                          fontSize: 13.5,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${paragraph.count} 条段评',
                        style: TextStyle(
                          color: HomePalette.accent,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_loading.contains(paragraph.paraIndex))
                  const SizedBox.square(
                    dimension: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: preset.mutedTextColor,
                  ),
              ],
            ),
          ),
        ),
        if (open) ...[
          if (_failed.contains(paragraph.paraIndex))
            _hint('段评暂时无法加载')
          else if (page == null)
            _hint('正在加载…')
          else if (page.comments.isEmpty)
            _hint('这段还没有可显示的段评')
          else
            for (final comment in page.comments) _commentTile(comment),
          Divider(height: 1, color: preset.borderColor),
        ],
      ],
    );
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
    child: Text(
      text,
      style: TextStyle(color: widget.preset.mutedTextColor, fontSize: 12.5),
    ),
  );

  Widget _commentTile(BookComment comment) {
    final preset = widget.preset;
    final time = comment.relativeTime();
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  comment.userName.isEmpty ? '读者' : comment.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: preset.mutedTextColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (time.isNotEmpty)
                Text(
                  time,
                  style: TextStyle(color: preset.mutedTextColor, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            comment.text,
            style: TextStyle(
              color: preset.textColor,
              fontSize: 13,
              height: 1.65,
            ),
          ),
          if (comment.diggCount > 0) ...[
            const SizedBox(height: 5),
            Text(
              '赞 ${comment.diggCount}',
              style: TextStyle(color: preset.mutedTextColor, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
