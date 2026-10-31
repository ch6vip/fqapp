import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/book_txt_export.dart';
import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
import '../widgets/cache/cache_page_widgets.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/shelf/shelf_design.dart';
import 'cached_book_reader.dart';

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
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: book == null ? '清空全部章节缓存' : '删除这本书的缓存',
      message: '只清理缓存正文与目录，阅读历史和排版设置会保留。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
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
      final opened = await openCachedBook(
        context,
        book: book,
        cache: _store,
        readerStore: widget.readerStore,
      );
      // 目录与章节对不上（章节已被逐出）时刷新列表，别让一行点不动又没反馈。
      if (!opened && mounted) await _reload();
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
  Widget _bookCard(CachedBookSummary item, HomePalette palette) {
    final bookId = item.book.id;
    // _onExportChanged clears _exportBookId as soon as the export stops, so a
    // row can only see a state here while that export is still running.
    final progress = _exportBookId == bookId ? _export?.value : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SettingsGroupCard(
        showDividers: false,
        children: [
          SettingsRow(
            icon: LucideIcons.book_open,
            iconTile: true,
            title: item.book.title,
            subtitle:
                '${item.stats.chapterCount}/${item.book.chapters.length} 章'
                ' · ${formatCacheBytes(item.stats.byteCount)}',
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
                    icon: Icon(
                      LucideIcons.download,
                      size: 20,
                      color: palette.muted,
                    ),
                  ),
                IconButton(
                  tooltip: '删除《${item.book.title}》缓存',
                  onPressed: () => _clear(item.book),
                  icon: Icon(
                    LucideIcons.trash,
                    size: 20,
                    color: palette.eink ? Colors.black : ShelfTokens.deleteRed,
                  ),
                ),
              ],
            ),
          ),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  progress.total == 0
                      ? '导出中…'
                      : '导出 ${progress.completed}/${progress.total} 章',
                  key: Key('cached_book_export_progress_$bookId'),
                  style: TextStyle(fontSize: 12, color: palette.accentText),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(HomePalette palette) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return CacheErrorState(message: error, onRetry: _reload);
    }
    if (_books.isEmpty) {
      return const CacheEmptyState(
        icon: LucideIcons.hard_drive_download,
        title: '暂无缓存章节',
        message: '阅读小说后会自动保存，详情页「下载」会保存整本；下载的章节不会被自动清理。',
      );
    }
    final count = _books.fold(0, (sum, item) => sum + item.stats.chapterCount);
    final bytes = _books.fold(0, (sum, item) => sum + item.stats.byteCount);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        CacheSummaryCard(
          icon: LucideIcons.book_open,
          title: '已缓存 ${_books.length} 本 · 共 $count 章',
          subtitle: '占用空间：${formatCacheBytes(bytes)} · 点击可离线续读',
        ),
        const SizedBox(height: 12),
        for (final item in _books) _bookCard(item, palette),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SettingsScaffold(
      title: '小说离线缓存',
      actions: [
        IconButton(
          tooltip: '清空全部缓存',
          onPressed: _books.isEmpty ? null : () => _clear(),
          icon: Icon(
            LucideIcons.trash,
            color: _books.isEmpty
                ? palette.muted.withValues(alpha: 0.4)
                : (palette.eink ? Colors.black : ShelfTokens.deleteRed),
          ),
        ),
      ],
      body: _body(palette),
    );
  }
}
