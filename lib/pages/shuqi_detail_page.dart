import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/shuqi_book.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../services/user_facing_error.dart';
import '../widgets/detail/detail_cover_tile.dart';
import '../widgets/detail/detail_description.dart';
import '../widgets/detail/detail_read_bar.dart';
import '../widgets/home/home_archive.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
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
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: const HomeBackButton(size: 48),
        title: const HomeCode('STORY ARCHIVE'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              '书旗 · 只读',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: _buildBody(palette),
        ),
      ),
      bottomNavigationBar: DetailReadBar(
        label: '开始阅读',
        opening: false,
        enabled:
            !_loading &&
            _error == null &&
            _book != null &&
            (_toc?.chapters.isNotEmpty ?? false),
        onRead: () => _openChapter(0),
      ),
    );
  }

  Widget _buildBody(HomePalette palette) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: palette.ink));
    }
    if (_error != null) {
      return HomeStateView(
        icon: LucideIcons.cloud_off,
        title: '暂时无法加载书籍',
        message: _error,
        actionLabel: '重试',
        actionIcon: LucideIcons.refresh_cw,
        onAction: _load,
        scrollable: true,
      );
    }
    final book = _book;
    if (book == null) {
      return const HomeStateView(
        icon: LucideIcons.book_open,
        title: '没有取到书籍数据',
        scrollable: true,
      );
    }
    final toc = _toc;
    return CustomScrollView(
      key: const Key('shuqi_detail_scroll'),
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(palette, book)),
        SliverToBoxAdapter(child: DetailDescription(text: book.intro)),
        SliverToBoxAdapter(
          child: HomeSectionLabel(
            code: 'CONTENTS',
            title: '目录',
            action: Text(
              toc == null ? '待加载' : '共 ${toc.chapters.length} 章',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        ),
        if (toc != null && !toc.hasRealTitles)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '当前章名为占位序号',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ),
          ),
        if (toc == null)
          SliverToBoxAdapter(child: _buildTocStatus(palette))
        else if (toc.chapters.isEmpty)
          const SliverToBoxAdapter(
            child: HomeStateView(icon: LucideIcons.list, title: '暂无章节'),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: toc.chapters.length,
              itemBuilder: (context, index) {
                final chapter = toc.chapters[index];
                return HomePressable(
                  key: ValueKey('shuqi_chapter_${chapter.chapterId}'),
                  onTap: () => _openChapter(index),
                  borderRadius: BorderRadius.circular(homePanelRadius),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: palette.line)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            chapter.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: palette.ink,
                            ),
                          ),
                        ),
                        if (chapter.isVip) ...[
                          const SizedBox(width: 12),
                          const HomeCode('VIP'),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildTocStatus(HomePalette palette) {
    if (_tocLoading) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(color: palette.ink)),
      );
    }
    return HomeStateView(
      icon: LucideIcons.list,
      title: '目录暂不可用',
      message: _tocError ?? '没有取到目录',
      actionLabel: '重试',
      actionIcon: LucideIcons.refresh_cw,
      onAction: _loadToc,
    );
  }

  Widget _buildHeader(HomePalette palette, ShuqiBook book) {
    final item = book.toMediaItem();
    final meta = [
      book.status,
      book.wordCount,
      book.kind,
    ].where((part) => part.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailCoverTile(item: item),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HomeCode(homeFileCode(item)),
                const SizedBox(height: 6),
                Text(
                  book.name.isEmpty ? widget.initialTitle : book.name,
                  style: homeSerifStyle(
                    size: 22,
                    height: 1.3,
                    color: palette.ink,
                  ),
                ),
                if (book.author.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    book.author,
                    style: TextStyle(fontSize: 14, color: palette.ink),
                  ),
                ],
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: palette.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
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
