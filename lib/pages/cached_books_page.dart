import 'package:flutter/material.dart';

import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import 'reader_page.dart';

class CachedBooksPage extends StatefulWidget {
  final ChapterCacheStore? cacheStore;
  final ReaderStore? readerStore;

  const CachedBooksPage({super.key, this.cacheStore, this.readerStore});

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

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _store.changes.removeListener(_reload);
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
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '暂无缓存章节\n阅读小说后会自动保存，详情页「下载」会保存整本；下载的章节不会被自动清理。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '$count 章 · ${formatCacheBytes(bytes)}\n'
                    '点击书籍可离线续读，目录中已保存的章节带有缓存标记。',
                  ),
                ),
                for (final item in _books)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: Text(item.book.title),
                      subtitle: Text(
                        '${item.stats.chapterCount}/${item.book.chapters.length} 章'
                        ' · ${formatCacheBytes(item.stats.byteCount)}',
                      ),
                      onTap: () => _open(item.book),
                      trailing: IconButton(
                        tooltip: '删除《${item.book.title}》缓存',
                        onPressed: () => _clear(item.book),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
