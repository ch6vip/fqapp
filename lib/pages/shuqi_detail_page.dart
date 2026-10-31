import 'dart:async';

import 'package:flutter/material.dart';

import '../models/shuqi_book.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../services/user_facing_error.dart';
import 'reader_page.dart';

/// 书旗书籍详情 + 目录。
///
/// 这条链路是**只读**的：不写书架、不写阅读历史、不下载。阅读器以
/// `localOnly: true` 打开，从而跳过番茄那套目录同步与磁盘缓存；阅读器内部
/// 的进度/阅读时长写入则靠注入 [_ReadOnlyReaderStore] 丢弃。
///
/// 书旗 bookId 与番茄同为纯数字，所以在阅读器里加 `shuqi:` 前缀，避免两套 id
/// 在同一条进度/缓存键上相撞。
class ShuqiDetailPage extends StatefulWidget {
  final String bookId;

  /// 搜索结果带过来的标题/封面，只用于首屏占位，加载完成后以详情为准。
  final String initialTitle;
  final String initialCover;

  /// 注入点：留空走后端，与 SearchPage 的 loader 约定一致。
  final Future<Map<String, dynamic>> Function(String bookId)? bookLoader;
  final Future<Map<String, dynamic>> Function(String bookId)? tocLoader;

  const ShuqiDetailPage({
    super.key,
    required this.bookId,
    this.initialTitle = '',
    this.initialCover = '',
    this.bookLoader,
    this.tocLoader,
  });

  @override
  State<ShuqiDetailPage> createState() => _ShuqiDetailPageState();
}

class _ShuqiDetailPageState extends State<ShuqiDetailPage> {
  ShuqiBook? _book;
  ShuqiToc? _toc;
  bool _loading = true;
  String? _error;

  /// 目录的加载/错误状态独立于详情：目录失败时详情照常展示。
  bool _tocLoading = true;
  String? _tocError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _tocLoading = true;
      _tocError = null;
    });
    // 详情与目录互不依赖，并行发出：目录首次可能是一次整本 H5 页。
    await Future.wait([_loadBook(), _loadToc()]);
  }

  Future<void> _loadBook() async {
    try {
      final loader = widget.bookLoader ?? ApiClient.instance.shuqiBook;
      final payload = await loader(widget.bookId);
      if (!mounted) return;
      final detail = payload['data'];
      setState(() {
        _book = detail is Map
            ? ShuqiBook.fromJson(Map<String, dynamic>.from(detail))
            : null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(error);
        _loading = false;
      });
    }
  }

  Future<void> _loadToc() async {
    setState(() {
      _tocLoading = true;
      _tocError = null;
    });
    try {
      final loader = widget.tocLoader ?? ApiClient.instance.shuqiToc;
      final payload = await loader(widget.bookId);
      if (!mounted) return;
      final toc = payload['data'];
      setState(() {
        _toc = ShuqiToc.fromJson(
          toc is Map ? Map<String, dynamic>.from(toc) : null,
        );
        _tocLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _tocError = userFacingError(error);
        _tocLoading = false;
      });
    }
  }

  Future<void> _openChapter(int index) async {
    final book = _book;
    final toc = _toc;
    if (book == null || toc == null || toc.chapters.isEmpty) return;
    final start = index < 0 ? 0 : (index >= toc.chapters.length ? 0 : index);
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: 'shuqi:${widget.bookId}',
          title: book.name,
          cover: book.coverUrl,
          chapters: toc.toReaderChapters(),
          startIndex: start,
          localOnly: true,
          // `localOnly` 只关掉目录同步与磁盘缓存；`_persistProgress` 仍会写
          // 历史（kind=book, id=shuqi:<id>），污染本机历史与阅读统计。
          readerStore: const _ReadOnlyReaderStore(),
          chapterLoader: (chapter) async {
            final payload = await ApiClient.instance.shuqiChapter(
              widget.bookId,
              chapter.itemId,
            );
            final data = payload['data'];
            final text = data is Map ? data['content'] : null;
            if (text is! String || text.isEmpty) {
              throw StateError('这一章没有取到正文（${chapter.title}）');
            }
            return text;
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _book?.name.isNotEmpty == true
        ? _book!.name
        : (widget.initialTitle.isEmpty ? '书旗' : widget.initialTitle);
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final book = _book;
    if (book == null) {
      return const Center(child: Text('没有取到书籍数据'));
    }
    // 目录失败或还没回来时，详情照常展示，目录区单独给出状态与重试。
    final toc = _toc;
    if (toc == null) {
      return ListView(
        children: [_buildHeader(theme, book, null), _buildTocStatus()],
      );
    }
    return ListView.builder(
      itemCount: toc.chapters.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildHeader(theme, book, toc);
        final chapter = toc.chapters[index - 1];
        return ListTile(
          dense: true,
          title: Text(
            chapter.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: chapter.isVip
              ? Text('VIP', style: theme.textTheme.labelSmall)
              : null,
          onTap: () => _openChapter(index - 1),
        );
      },
    );
  }

  Widget _buildTocStatus() {
    if (_tocLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        children: [
          Text(_tocError ?? '没有取到目录', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _loadToc, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ShuqiBook book, ShuqiToc? toc) {
    final chapters = toc?.chapters ?? const <ShuqiChapter>[];
    final meta = [
      book.status,
      book.wordCount,
      book.kind,
    ].where((part) => part.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(theme, book),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(book.author, style: theme.textTheme.bodySmall),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta,
                        style: theme.textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: chapters.isEmpty
                          ? null
                          : () => _openChapter(0),
                      child: const Text('开始阅读'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (book.intro.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              book.intro,
              style: theme.textTheme.bodySmall,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                toc == null ? '目录未加载' : '共 ${chapters.length} 章',
                style: theme.textTheme.titleSmall,
              ),
              if (toc != null && !toc.hasRealTitles) ...[
                const SizedBox(width: 8),
                Text('（章名为占位）', style: theme.textTheme.bodySmall),
              ],
              const Spacer(),
              Text('书旗', style: theme.textTheme.bodySmall),
            ],
          ),
          const Divider(height: 20),
        ],
      ),
    );
  }

  Widget _buildCover(ThemeData theme, ShuqiBook book) {
    const width = 68.0;
    const height = 94.0;
    final fallback = Container(
      width: width,
      height: height,
      color: theme.colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.menu_book_outlined, size: 28),
    );
    if (book.coverUrl.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        book.coverUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// 只读阅读会话的存储：读取一律为空，写入一律丢弃。
///
/// 书旗是第三方只读源，`shuqi:<id>` 不该出现在本机历史、阅读统计或已看集合
/// 里。`ReaderPage` 只有一个 [ReaderStore] 注入点，且进度保存不受 `localOnly`
/// 控制，所以用这个空实现挡住 `_persistProgress` / `_settleReadTime` 的写入。
class _ReadOnlyReaderStore implements ReaderStore {
  const _ReadOnlyReaderStore();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async => null;

  @override
  Future<void> addHistory(Map<String, dynamic> entry) async {}

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {}

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {}

  @override
  Future<Set<String>> watchedEpisodeIds(String id) async => const {};

  @override
  Future<void> markEpisodeWatched(
    String id,
    Iterable<String> episodeIds,
  ) async {}

  @override
  Future<void> forgetWatchedEpisodes(String id) async {}
}
