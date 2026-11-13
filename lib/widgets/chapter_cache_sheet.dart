import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_download.dart';
import '../services/reader_preferences.dart';
import 'app_ui/app_ui_scope.dart';
import 'home/home_sheet.dart';
import 'reader/reader_theme.dart';
import 'reader/settings/reader_settings_widgets.dart';

/// 章节缓存面板的外壳：听书页用通用 HomeSheetFrame，阅读器用阅读设置面板
/// 那套 ReaderSettingsSheetFrame（配色跟随阅读背景 preset）。
enum ChapterCacheShell { home, reader }

/// Range picker for the reader, where picking a batch size still makes sense.
/// The detail page downloads the whole book without a sheet.
class ChapterCacheSheet extends StatefulWidget {
  final CachedBook book;
  final int currentIndex;
  final bool includeCurrentChapter;
  final ChapterCache cache;
  final Future<String> Function(Chapter) loader;
  final void Function(Chapter chapter, String text)? onContentAvailable;

  /// 听书页传入的「离线音频」区块。
  ///
  /// 文本缓存与音频缓存是两件事（见 issue #81），所以由调用方组装；阅读器和
  /// 详情页不传这个参数时，面板保持原来的纯文本缓存形态。
  final Widget? extraSection;

  /// 外壳样式；默认听书页的 HomeSheetFrame。
  final ChapterCacheShell shell;

  /// [ChapterCacheShell.reader] 时使用的阅读配色。
  final ReaderThemePreset readerPreset;

  const ChapterCacheSheet({
    super.key,
    required this.book,
    required this.currentIndex,
    this.includeCurrentChapter = false,
    required this.cache,
    required this.loader,
    this.extraSection,
    this.onContentAvailable,
    this.shell = ChapterCacheShell.home,
    this.readerPreset = ReaderThemePreset.light,
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
    final remaining = widget.book.chapters.length - _startIndex;
    final validIds = widget.book.chapters
        .map((chapter) => chapter.itemId)
        .toSet();
    final cachedCount = _cached.intersection(validIds).length;
    final children = _content(
      context,
      state: state,
      remaining: remaining,
      cachedCount: cachedCount,
    );
    switch (widget.shell) {
      case ChapterCacheShell.home:
        return HomeSheetFrame(title: '章节缓存', children: children);
      case ChapterCacheShell.reader:
        return ReaderSettingsSheetFrame(
          preset: widget.readerPreset,
          title: '章节缓存',
          closeTooltip: '关闭',
          scrollKey: const ValueKey('chapter-cache-scroll'),
          children: children,
        );
    }
  }

  List<Widget> _content(
    BuildContext context, {
    required ChapterDownloadState state,
    required int remaining,
    required int cachedCount,
  }) {
    final running = state.running;
    final message = state.message ?? _cacheError;
    final capacity = widget.cache.chapterCapacity;
    // Offered once the presets leave a gap: the whole-book action downloads
    // everything left and pins it, so the cache's automatic budget can neither
    // truncate nor evict a download the user asked for.
    final offersWholeBook = remaining > _presetCounts.last;
    final choices = <int>{
      for (final count in _presetCounts)
        if (remaining > 0) remaining < count ? remaining : count,
    };
    if (widget.shell == ChapterCacheShell.reader &&
        AppUiScope.isClassic(context)) {
      return [
        _classicContent(
          state: state,
          remaining: remaining,
          cachedCount: cachedCount,
          choices: choices,
          offersWholeBook: offersWholeBook,
          message: message,
          capacity: capacity,
        ),
      ];
    }
    return [
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
                        _batch.start(startIndex: _startIndex, count: count),
                      ),
                child: Text(
                  widget.includeCurrentChapter ? '缓存 $count 章' : '缓存后 $count 章',
                ),
              ),
            // The presets already cover a short remainder, so the whole-book
            // action only appears where they leave a gap.
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
          icon: const Icon(LucideIcons.circle_stop),
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
      if (widget.extraSection != null) widget.extraSection!,
    ];
  }

  Widget _classicContent({
    required ChapterDownloadState state,
    required int remaining,
    required int cachedCount,
    required Set<int> choices,
    required bool offersWholeBook,
    required String? message,
    required int capacity,
  }) {
    final preset = widget.readerPreset;
    final secondary = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: preset.textColor.withValues(alpha: 0.78),
    );
    final total = widget.book.chapters.length;
    final buttonStyle = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    );
    final actions = <Widget>[
      for (final count in choices)
        OutlinedButton(
          style: buttonStyle,
          onPressed: state.running
              ? null
              : () => unawaited(
                  _batch.start(startIndex: _startIndex, count: count),
                ),
          child: Text(
            widget.includeCurrentChapter ? '缓存 $count 章' : '缓存后 $count 章',
            textAlign: TextAlign.center,
          ),
        ),
      if (offersWholeBook)
        FilledButton(
          key: const Key('chapter_cache_all'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          onPressed: state.running
              ? null
              : () => unawaited(
                  _batch.start(
                    startIndex: _startIndex,
                    count: remaining,
                    pin: true,
                  ),
                ),
          child: Text('全部下载 $remaining 章', textAlign: TextAlign.center),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = constraints.maxWidth <= 320 ? 16.0 : 20.0;
        final columns = MediaQuery.textScalerOf(context).scale(14) > 20 ? 1 : 2;
        return Padding(
          key: const ValueKey('classic-cache-content'),
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.book.title,
                style: TextStyle(
                  color: preset.textColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 6),
              Text('已缓存 $cachedCount / $total 章', style: secondary),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                key: const ValueKey('classic-cache-summary-progress'),
                value: total == 0 ? 0 : cachedCount / total,
                minHeight: 4,
                borderRadius: BorderRadius.circular(4),
                semanticsLabel: '已缓存 $cachedCount / $total 章',
              ),
              const SizedBox(height: 20),
              if (remaining == 0)
                const Text('当前已是最后一章')
              else
                for (var i = 0; i < actions.length; i += columns) ...[
                  if (i > 0) const SizedBox(height: 8),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: actions[i]),
                        if (columns == 2) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: i + 1 < actions.length
                                ? actions[i + 1]
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              if (state.running) ...[
                const SizedBox(height: 16),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: preset.fieldColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: preset.borderColor),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '正在缓存 ${state.completed} / ${state.total} 章',
                          style: TextStyle(
                            color: preset.textColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: state.fraction,
                          semanticsLabel:
                              '本次缓存 ${state.completed} / ${state.total} 章',
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 48),
                          ),
                          onPressed: _cancel,
                          icon: const Icon(LucideIcons.circle_stop, size: 18),
                          label: const Text('停止缓存'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (message != null) ...[
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(message)),
              ],
              const SizedBox(height: 16),
              Text(
                widget.includeCurrentChapter
                    ? '从当前章节开始缓存，已有缓存自动复用。插图首次查看需联网，显示后自动缓存。'
                    : '阅读过的章节自动保存，可提前缓存后续章节。插图首次查看需联网，显示后自动缓存。',
                style: secondary,
              ),
              const SizedBox(height: 8),
              Text(
                '关闭面板会停止下载。「全部下载」一直保留；自动缓存最多保留 '
                '$capacity 章或 80 MB，超出后清理较久未读的。',
                style: secondary,
              ),
              if (widget.extraSection != null) widget.extraSection!,
            ],
          ),
        );
      },
    );
  }
}
