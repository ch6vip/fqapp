import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/shuqi_book.dart';
import '../services/api_client.dart';
import '../services/app_style_tokens.dart';
import '../services/library_store.dart';
import '../services/user_facing_error.dart';
import '../widgets/detail/detail_archive.dart';
import '../widgets/detail/detail_states.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'reader_page.dart';

/// 书旗书籍详情 + 目录。
///
/// 页面版式来自上游 `DetailPage`（revision ebcd7f1）：磨砂头栏、档案分区、
/// 行内目录和底部玻璃操作坞。书旗仍是一条**只读**链路：不写书架、不写阅读
/// 历史、不下载。阅读器以 `localOnly: true` 打开，从而跳过番茄那套目录同步与
/// 磁盘缓存；阅读器内部的进度/阅读时长写入则靠注入 [_ReadOnlyReaderStore]
/// 丢弃。
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

  String get _title => _book?.name.isNotEmpty == true
      ? _book!.name
      : (widget.initialTitle.isEmpty ? '书旗' : widget.initialTitle);

  @override
  Widget build(BuildContext context) => WenkuPage(
    header: ArchiveHeaderBar(
      leading: GlassIconButton(
        icon: CupertinoIcons.back,
        label: '返回',
        onPressed: () => Navigator.maybePop(context),
      ),
      title: FittedBox(
        fit: BoxFit.scaleDown,
        child: const AppText(
          '书籍详情',
          style: TextStyle(
            fontSize: 18,
            height: 1.2,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
    child: Builder(builder: _body),
  );

  Widget _body(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final edge = MediaQuery.sizeOf(context).width >= 700 ? 40.0 : 24.0;
    final horizontal = edge + safe.left;
    if (_loading) {
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          horizontal,
          safe.top + FrostedHeader.toolbarHeight + 24,
          edge + safe.right,
          140,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              height: 240,
              width: double.infinity,
              child: LoadingSkeleton(
                layout: SkeletonLayout.detail,
                label: '正在加载书旗书籍',
              ),
            ),
            const SizedBox(height: 18),
            const AppText('正在加载书籍与目录'),
          ],
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          horizontal,
          safe.top + FrostedHeader.toolbarHeight + 40,
          edge + safe.right,
          140,
        ),
        child: DetailInlineError(message: error, onRetry: _load),
      );
    }
    final book = _book;
    if (book == null) {
      return Center(child: AppText('没有取到书籍数据'));
    }
    final toc = _toc;
    final chapters = toc?.chapters ?? const <ShuqiChapter>[];
    final geometry = glassActionDockGeometry(
      context,
      primary: chapters.isEmpty ? '暂无章节' : '开始阅读',
      secondary: '',
    );
    // 目录条目可能上万章，只有真正进入视口的行才构建（上游目录同样是
    // SliverList.builder）；头部/简介/目录标题放在一个 adapter sliver 里。
    final showingChapters = _tocError == null && !_tocLoading;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomScrollView(
            key: const Key('shuqi-detail-scroll'),
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontal,
                  safe.top + FrostedHeader.toolbarHeight + 24,
                  edge + safe.right,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _identity(context, book),
                      if (book.intro.isNotEmpty) ...[
                        const SizedBox(height: 28),
                        DetailArchiveSynopsis(text: book.intro),
                      ],
                      const SizedBox(height: 30),
                      _contentsHeading(context, toc, chapters),
                      if (_tocError != null)
                        DetailInlineError(
                          message: _tocError!,
                          onRetry: () => unawaited(_loadToc()),
                        )
                      else if (_tocLoading)
                        const SizedBox(
                          height: 40,
                          child: LoadingSkeleton(
                            layout: SkeletonLayout.inline,
                            label: '正在加载目录',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (showingChapters)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontal,
                    0,
                    edge + safe.right,
                    0,
                  ),
                  sliver: SliverList.builder(
                    itemCount: chapters.length,
                    itemBuilder: (context, index) =>
                        _chapterRow(context, chapters[index], index),
                  ),
                ),
              SliverToBoxAdapter(child: SizedBox(height: geometry.extent + 20)),
            ],
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: DetailArchiveDockUnderlay(height: geometry.extent),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              DockLayout.actionSideInset + safe.left,
              0,
              DockLayout.actionSideInset + safe.right,
              DockLayout.bottomPaddingOf(context, viewPadding: true),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: DockLayout.actionMaxWidth,
              ),
              child: DetailArchiveDock(
                primaryLabel: chapters.isEmpty ? '暂无章节' : '开始阅读',
                primaryIcon: CupertinoIcons.play_fill,
                onPrimary: chapters.isEmpty ? null : () => _openChapter(0),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _identity(BuildContext context, ShuqiBook book) {
    final scheme = Theme.of(context).colorScheme;
    final cover = book.coverUrl.trim();
    final meta = [
      book.status,
      book.wordCount,
      book.kind,
      '书旗小说',
    ].where((part) => part.isNotEmpty).join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 650;
        final coverWidth = wide ? 150.0 : 118.0;
        final art = ClipRRect(
          borderRadius: BorderRadius.circular(
            AppStyleTokens.of(context).coverRadius,
          ),
          child: SizedBox(
            width: coverWidth,
            height: coverWidth * 1.4,
            child: cover.isEmpty
                ? ColoredBox(color: scheme.surfaceContainerHighest)
                : Image.network(
                    cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        ColoredBox(color: scheme.surfaceContainerHighest),
                  ),
          ),
        );
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(
              book.name.isEmpty ? _title : book.name,
              key: const Key('shuqi-book-title'),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: wide ? 28 : 24,
                height: 1.25,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 8),
            if (book.author.isNotEmpty)
              AppText(
                book.author,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 9),
              AppText(
                meta,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.55,
                ),
              ),
            ],
            if (AppStyleTokens.of(context).showDecorativeCodes) ...[
              const SizedBox(height: 12),
              ArchiveCode(detailArchiveFileCode(book.bookId), inverse: true),
            ],
          ],
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            art,
            SizedBox(width: wide ? 28 : 20),
            Expanded(child: info),
          ],
        );
      },
    );
  }

  Widget _contentsHeading(
    BuildContext context,
    ShuqiToc? toc,
    List<ShuqiChapter> chapters,
  ) {
    return Row(
      children: [
        Expanded(
          child: ArchiveSection(
            title: '目录',
            code: '02 / CONTENTS',
            subtitle: toc == null ? '目录未加载' : '共 ${chapters.length} 章',
          ),
        ),
        if (toc != null && !toc.hasRealTitles)
          AppText(
            '（章名为占位）',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
      ],
    );
  }

  Widget _chapterRow(BuildContext context, ShuqiChapter chapter, int index) {
    final scheme = Theme.of(context).colorScheme;
    return JellyTapSurface(
      key: ValueKey('shuqi-chapter-$index'),
      onTap: () => unawaited(_openChapter(index)),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor,
              width: .7,
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: AppText(
                (index + 1).toString().padLeft(2, '0'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: AppText(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            if (chapter.isVip) ...[
              const SizedBox(width: 10),
              AppText(
                'VIP',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(width: 12),
            const ArchiveIcon(CupertinoIcons.chevron_right, size: 13),
          ],
        ),
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
