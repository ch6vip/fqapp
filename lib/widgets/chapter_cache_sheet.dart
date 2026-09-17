import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_text_formatter.dart';

class ChapterCacheSheet extends StatefulWidget {
  final CachedBook book;
  final int currentIndex;
  final bool includeCurrentChapter;
  final ChapterCache cache;
  final Future<String> Function(Chapter) loader;
  final void Function(Chapter chapter, String text)? onContentAvailable;

  const ChapterCacheSheet({
    super.key,
    required this.book,
    required this.currentIndex,
    this.includeCurrentChapter = false,
    required this.cache,
    required this.loader,
    this.onContentAvailable,
  });

  @override
  State<ChapterCacheSheet> createState() => _ChapterCacheSheetState();
}

class _ChapterCacheSheetState extends State<ChapterCacheSheet> {
  Set<String> _cached = {};
  bool _running = false;
  int _completed = 0;
  int _total = 0;
  int _incompleteImages = 0;
  int _job = 0;
  String? _message;

  // Detail pages have not loaded the current chapter's body yet. The reader
  // already has it and keeps its existing "following chapters" behavior.
  // Note: .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md
  int get _startIndex =>
      (widget.currentIndex + (widget.includeCurrentChapter ? 0 : 1)).clamp(
        0,
        widget.book.chapters.length,
      );

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    ++_job;
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final cached = await widget.cache.cachedChapterIds(widget.book.id);
      if (mounted) setState(() => _cached = cached);
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取缓存，请重试');
    }
  }

  Future<void> _download(int count) async {
    if (_running) return;
    final job = ++_job;
    final chapters = widget.book.chapters
        .skip(_startIndex)
        .take(count)
        .toList(growable: false);
    setState(() {
      _running = true;
      _completed = 0;
      _total = chapters.length;
      _incompleteImages = 0;
      _message = null;
    });
    try {
      await widget.cache.saveBook(widget.book);
      for (final chapter in chapters) {
        if (!mounted || job != _job) return;
        // Earlier writes may evict a chapter that was cached when we started.
        final cached = await widget.cache.read(
          bookId: widget.book.id,
          chapterId: chapter.itemId,
        );
        if (!mounted || job != _job) return;
        var content = _readCachedChapter(cached, chapter.title);
        var shouldWrite = false;
        if (content == null || content.needsImageRefresh()) {
          final text = await widget
              .loader(chapter)
              .timeout(const Duration(seconds: 30));
          if (!mounted || job != _job) return;
          final fetched = ChapterContent.isStructuredCache(text)
              ? ChapterContent.fromCacheText(text)
              : ChapterContent.fromPlainText(text, illustrationsChecked: false);
          if (fetched.withoutLeadingTitle(chapter.title).isEmpty) {
            throw StateError('章节正文为空');
          }
          // A reader refresh may have completed while the batch was fetching.
          final latest = await widget.cache.read(
            bookId: widget.book.id,
            chapterId: chapter.itemId,
          );
          if (!mounted || job != _job) return;
          final previous = _readCachedChapter(latest, chapter.title);
          content = fetched.preferCompleteCache(previous);
          shouldWrite = !identical(content, previous);
        }
        final text = content.toCacheText();
        // Publish before queuing the disk write so older reader requests can
        // no longer queue a stale write behind it. A failed save still leaves
        // the downloaded chapter available to the open reader.
        widget.onContentAvailable?.call(chapter, text);
        if (shouldWrite) {
          await widget.cache.write(
            bookId: widget.book.id,
            chapterId: chapter.itemId,
            title: chapter.title,
            text: text,
          );
        }
        if (!mounted || job != _job) return;
        setState(() {
          _completed++;
          if (content!.needsImageRefresh()) _incompleteImages++;
        });
      }
      if (mounted && job == _job) {
        setState(
          () => _message = _incompleteImages == 0
              ? '缓存完成，可从书架的离线缓存入口继续阅读'
              : '已保存 $_completed/$_total 章，其中 $_incompleteImages 章插图未更新，联网后可重试',
        );
      }
    } catch (_) {
      if (mounted && job == _job) {
        setState(() => _message = '缓存未完成，已保存 $_completed/$_total 章。检查网络后可重试');
      }
    } finally {
      if (mounted && job == _job) {
        setState(() => _running = false);
        await _refresh();
      }
    }
  }

  void _cancel() {
    ++_job;
    setState(() {
      _running = false;
      _message = '已停止缓存，已保存的章节会保留';
    });
    _refresh();
  }

  ChapterContent? _readCachedChapter(String? text, String title) {
    if (text == null) return null;
    try {
      final content = ChapterContent.fromCacheText(text);
      return content.withoutLeadingTitle(title).isEmpty ? null : content;
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.book.chapters.length - _startIndex;
    final choices = <int>{
      for (final count in [20, 50, 100])
        if (remaining > 0) remaining < count ? remaining : count,
    };
    final validIds = widget.book.chapters
        .map((chapter) => chapter.itemId)
        .toSet();
    final cachedCount = _cached.intersection(validIds).length;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('章节缓存', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(widget.book.title),
            const SizedBox(height: 6),
            Text('已缓存 $cachedCount / ${widget.book.chapters.length} 章'),
            const SizedBox(height: 16),
            Text(
              widget.includeCurrentChapter
                  ? '从当前章节开始缓存，已有缓存会自动复用。插图首次查看需要联网，显示后会自动缓存。'
                  : '阅读过的章节会自动保存，也可提前缓存后续章节。插图首次查看需要联网，显示后会自动缓存。',
            ),
            const SizedBox(height: 16),
            if (remaining == 0)
              const Text('当前已是最后一章')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final count in choices)
                    OutlinedButton(
                      onPressed: _running ? null : () => _download(count),
                      child: Text(
                        widget.includeCurrentChapter
                            ? '缓存 $count 章'
                            : '缓存后 $count 章',
                      ),
                    ),
                ],
              ),
            if (_running) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _total == 0 ? 0 : _completed / _total,
              ),
              const SizedBox(height: 8),
              Text('正在缓存 $_completed / $_total 章'),
              TextButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('停止缓存'),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!),
            ],
            const SizedBox(height: 12),
            Text(
              '关闭此面板会停止下载。缓存最多保留 500 章或 80 MB，超出后清理较久未读的章节。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
