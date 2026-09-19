import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_download.dart';

/// Range picker for the reader, where picking a batch size still makes sense.
/// The detail page downloads the whole book without a sheet.
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
  String? _cacheError;
  late final ChapterDownload _batch;

  /// Stepped batch sizes offered next to the whole-book action.
  // Note: 面板只留给阅读器，详情页点「下载」直接下整本 — 见
  // .agents/notes/implemented/feature/2026-09-20-offline-whole-book-download.md
  static const _presetCounts = [20, 50, 100];

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
    _batch = ChapterDownload(
      cache: widget.cache,
      book: widget.book,
      loader: widget.loader,
      onContentAvailable: widget.onContentAvailable,
    )..addListener(_onBatchChanged);
    _refresh();
  }

  @override
  void dispose() {
    // Closing the panel stops the batch it started; saved chapters stay.
    _batch.dispose();
    super.dispose();
  }

  void _onBatchChanged() {
    if (!mounted) return;
    if (!_batch.value.running) {
      _cacheError = null;
      _refresh();
    }
    setState(() {});
  }

  Future<void> _refresh() async {
    try {
      final cached = await widget.cache.cachedChapterIds(widget.book.id);
      if (mounted) setState(() => _cached = cached);
    } catch (_) {
      if (mounted) setState(() => _cacheError = '无法读取缓存，请重试');
    }
  }

  void _cancel() {
    _batch.cancel();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = _batch.value;
    final running = state.running;
    final message = state.message ?? _cacheError;
    final remaining = widget.book.chapters.length - _startIndex;
    final capacity = widget.cache.chapterCapacity;
    // Offered once the presets leave a gap: the whole-book action downloads
    // everything left and pins it, so the cache's automatic budget can neither
    // truncate nor evict a download the user asked for.
    final offersWholeBook = remaining > _presetCounts.last;
    final choices = <int>{
      for (final count in _presetCounts)
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
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final count in choices)
                    OutlinedButton(
                      onPressed: running
                          ? null
                          : () => unawaited(
                              _batch.start(
                                startIndex: _startIndex,
                                count: count,
                              ),
                            ),
                      child: Text(
                        widget.includeCurrentChapter
                            ? '缓存 $count 章'
                            : '缓存后 $count 章',
                      ),
                    ),
                  // The presets already cover a short remainder, so the
                  // whole-book action only appears where they leave a gap.
                  if (offersWholeBook)
                    FilledButton(
                      key: const Key('chapter_cache_all'),
                      onPressed: running
                          ? null
                          : () => unawaited(
                              _batch.start(
                                startIndex: _startIndex,
                                count: remaining,
                                pin: true,
                              ),
                            ),
                      child: Text('全部下载 $remaining 章'),
                    ),
                ],
              ),
            ],
            if (running) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: state.fraction),
              const SizedBox(height: 8),
              Text('正在缓存 ${state.completed} / ${state.total} 章'),
              TextButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('停止缓存'),
              ),
            ],
            if (message != null) ...[const SizedBox(height: 12), Text(message)],
            const SizedBox(height: 12),
            Text(
              '关闭此面板会停止下载。「全部下载」的章节会一直保留；自动缓存的章节最多保留 '
              '$capacity 章或 80 MB，超出后清理较久未读的。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
