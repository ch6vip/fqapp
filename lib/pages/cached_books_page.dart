import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/book_txt_export.dart';
import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import 'reader_page.dart';

class CachedBooksPage extends StatefulWidget {
  final ChapterCacheStore? cacheStore;
  final ReaderStore? readerStore;

  /// 导出时重取的目录与正文加载器、以及落点；都缺省走实时实现，
  /// 注入后测试可完全离线（与详情页的 loader 注入同一套路）。
  final Future<List<Chapter>> Function(String bookId)? exportDirectoryLoader;
  final Future<String> Function(Chapter chapter)? exportChapterLoader;
  final TxtSink? exportSink;

  const CachedBooksPage({
    super.key,
    this.cacheStore,
    this.readerStore,
    this.exportDirectoryLoader,
    this.exportChapterLoader,
    this.exportSink,
  });

  @override
  State<CachedBooksPage> createState() => _CachedBooksPageState();
}

class _CachedBooksPageState extends State<CachedBooksPage> {
  late final ChapterCacheStore _store =
      widget.cacheStore ?? ChapterCacheStore.instance;
  List<CachedBookSummary> _books = [];
  bool _loading = true;
  bool _openingBook = false;
  String? _error;
  int _generation = 0;
  BookTxtExport? _export;
  String? _exportBookId;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _store.changes.removeListener(_reload);
    // 离开页面就不该再有后台导出：没有界面报告结果的成功等于骗人。
    _export?.removeListener(_onExportChanged);
    _export?.dispose();
    _export = null;
    super.dispose();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final books = await _store.books();
      if (!mounted || generation != _generation) return;
      setState(() {
        _books = books;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = '无法读取缓存';
        });
      }
    }
  }

  Future<void> _clear([CachedBook? book]) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(book == null ? '清空全部章节缓存' : '删除这本书的缓存'),
        content: const Text('只清理缓存正文与目录，阅读历史和排版设置会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _store.clear(bookId: book?.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清理失败，请重试')));
      }
    }
  }

  Future<void> _open(CachedBook book) async {
    if (_openingBook) return;
    _openingBook = true;
    try {
      final historyStore = widget.readerStore ?? LibraryStore.instance;
      Map<String, dynamic>? saved;
      try {
        saved = await ReaderHistory(historyStore).load(book.id);
      } catch (_) {
        // An unavailable history store must not block cached chapters.
      }
      final cached = await _store.cachedChapterIds(book.id);
      if (!mounted) return;
      if (cached.isEmpty) {
        await _reload();
        return;
      }
      var index = book.chapters.indexWhere(
        (chapter) => chapter.itemId == saved?['chapterId']?.toString(),
      );
      if (index < 0) {
        final episode = num.tryParse(saved?['episode']?.toString() ?? '');
        index = (episode != null && episode.isFinite ? episode.toInt() : 0)
            .clamp(0, book.chapters.length - 1);
      }
      if (!cached.contains(book.chapters[index].itemId)) {
        index = book.chapters.indexWhere(
          (chapter) => cached.contains(chapter.itemId),
        );
      }
      if (index < 0) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            bookId: book.id,
            title: book.title,
            cover: book.cover,
            chapters: book.chapters,
            startIndex: index,
            chapterCache: _store,
            readerStore: historyStore,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开缓存，请重试')));
      }
    } finally {
      _openingBook = false;
    }
  }

  Future<List<Chapter>> _loadExportDirectory(String bookId) async {
    final volumes = await ApiClient.instance.directoryChapters(bookId);
    return [for (final volume in volumes) ...volume];
  }

  /// Starts the whole-book export of one cached book. Only one runs at a time,
  /// and a second tap on any row cancels it instead of starting a second file.
  void _startExport(CachedBook book) {
    if (_export != null) return;
    final export = BookTxtExport(
      directoryLoader: widget.exportDirectoryLoader ?? _loadExportDirectory,
      // 取文只经 ApiClient：CRIT-005 要求业务请求都过它的 _get 漏斗。
      chapterLoader:
          widget.exportChapterLoader ??
          (chapter) => ApiClient.instance.contentText(chapter.itemId),
      sink: widget.exportSink ?? const PlatformTxtSink(),
    );
    export.addListener(_onExportChanged);
    _export = export;
    _exportBookId = book.id;
    setState(() {});
    export.start(bookId: book.id, title: book.title);
  }

  void _cancelExport() => _export?.cancel();

  void _onExportChanged() {
    final export = _export;
    if (export == null) return;
    final state = export.value;
    if (!state.running) {
      export.removeListener(_onExportChanged);
      _export = null;
      _exportBookId = null;
      // 不能在自己的 notifyListeners 调用栈里 dispose：那一刻通知列表正在被遍历。
      final message = state.message;
      Future<void>.microtask(export.dispose);
      if (message != null) _snack(message);
    }
    if (mounted) setState(() {});
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  /// One cached book row: tap opens the reader, the trailing actions export and
  /// clear. A running export turns its own button into progress and cancel.
  Widget _bookTile(CachedBookSummary item) {
    final bookId = item.book.id;
    // _onExportChanged clears _exportBookId as soon as the export stops, so a
    // row can only see a state here while that export is still running.
    final progress = _exportBookId == bookId ? _export?.value : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 38,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Icon(Icons.menu_book_outlined, size: 20),
        ),
        title: Text(
          item.book.title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${item.stats.chapterCount}/${item.book.chapters.length} 章'
              ' · ${formatCacheBytes(item.stats.byteCount)}',
            ),
            if (progress != null)
              Text(
                progress.total == 0
                    ? '导出中…'
                    : '导出 ${progress.completed}/${progress.total} 章',
                key: Key('cached_book_export_progress_$bookId'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
        onTap: () => _open(item.book),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress != null)
              IconButton(
                key: Key('cached_book_export_$bookId'),
                tooltip: '取消导出',
                onPressed: _cancelExport,
                icon: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    value: progress.total == 0 ? null : progress.fraction,
                    strokeWidth: 2,
                  ),
                ),
              )
            else
              IconButton(
                key: Key('cached_book_export_$bookId'),
                tooltip: '导出 TXT 到系统「下载」',
                onPressed: _export == null
                    ? () => _startExport(item.book)
                    : null,
                icon: const Icon(Icons.file_download_outlined),
              ),
            IconButton(
              tooltip: '删除《${item.book.title}》缓存',
              onPressed: () => _clear(item.book),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = _books.fold(0, (sum, item) => sum + item.stats.chapterCount);
    final bytes = _books.fold(0, (sum, item) => sum + item.stats.byteCount);
    return Scaffold(
      appBar: AppBar(
        title: const Text('离线缓存'),
        actions: [
          IconButton(
            tooltip: '清空全部缓存',
            onPressed: _books.isEmpty ? null : () => _clear(),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            )
          : _books.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.download_for_offline_outlined,
                        size: 32,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '暂无缓存章节',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '阅读小说后会自动保存，详情页「下载」会保存整本；下载的章节不会被自动清理。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 0.6,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.menu_book_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '已缓存 ${_books.length} 本 · 共 $count 章',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '占用空间：${formatCacheBytes(bytes)} · 点击可离线续读',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                for (final item in _books) _bookTile(item),
              ],
            ),
    );
  }
}
