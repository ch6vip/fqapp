import '../widgets/desktop_chapter_sidebar.dart';
import '../services/desktop_platform.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/media_item.dart';
import '../models/media_description.dart';
import '../models/series_detail.dart';
import '../services/api_client.dart';
import '../services/audio_history.dart';
import '../services/book_open_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_download.dart';
import '../services/connectivity_status.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/player_history.dart';
import '../services/reader_history.dart';
import '../services/shelf_store.dart';
import '../services/user_facing_error.dart';
import '../widgets/detail/detail_description.dart';
import '../widgets/detail/detail_directory_section.dart';
import '../widgets/detail/detail_directory_sheet.dart';
import '../widgets/detail/detail_hero.dart';
import '../widgets/detail/detail_id_row.dart';
import '../widgets/detail/detail_read_bar.dart';
import '../widgets/detail/detail_reviews.dart';
import '../widgets/detail/detail_reviews_sheet.dart';
import '../widgets/detail/detail_sections.dart';
import '../widgets/detail/detail_states.dart';
import '../widgets/detail/detail_style.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/media_card.dart';
import 'audio_page.dart';
import 'author_page.dart';
import 'cached_book_reader.dart';
import 'comic_reader_page.dart';
import 'player_page.dart';
import 'reader_page.dart';

/// Optional decorations for the detail page (currently the review block).
/// Kept as one injected bundle so callers that already stub the detail and
/// directory loaders can stay fully offline.
///
/// Note: 详情页版式复刻、以及「注入过 loader 即视为离线」的规则 — 见
/// .agents/notes/implemented/feature/2026-09-10-detail-audio-replica.md
class DetailExtras {
  const DetailExtras({this.comments = const BookCommentPage()});

  final BookCommentPage comments;
}

typedef DetailExtrasLoader = Future<DetailExtras> Function(String bookId);

/// How many chapter rows the detail preview block shows.
const _previewChapterCount = 3;

Future<DetailExtras> _defaultExtras(String bookId) async =>
    DetailExtras(comments: await ApiClient.instance.bookComments(bookId));

class _Captured<T> {
  final T? value;
  final Object? error;

  const _Captured.value(T this.value) : error = null;
  const _Captured.error(this.error) : value = null;
}

Future<_Captured<T>> _capture<T>(Future<T> future) async {
  try {
    return _Captured<T>.value(await future);
  } catch (error) {
    return _Captured<T>.error(error);
  }
}

class DetailPage extends StatefulWidget {
  final MediaItem item;
  final Future<Map<String, dynamic>> Function(String bookId, {String tab})?
  detailLoader;
  final Future<List<List<Chapter>>> Function(String bookId, {String tab})?
  directoryLoader;
  final DetailExtrasLoader? extrasLoader;

  /// Series detail (cast list) for short dramas and manju. Only consulted for
  /// video kinds; other content has no cast.
  final Future<SeriesDetail> Function(String seriesId)? seriesLoader;
  final ReaderStore? readerStore;

  /// Offline chapter cache behind the download action. Injectable so tests can
  /// download without a real Hive box.
  final ChapterCache? chapterCache;

  /// Chapter body loader behind the download; defaults to the live API and is
  /// injectable like the other loaders so tests stay offline.
  final Future<String> Function(Chapter chapter)? chapterLoader;

  /// 连通性探测。缺省走真实实现；注入后测试可完全离线。
  final Future<ConnectivityView> Function()? connectivity;

  const DetailPage({
    super.key,
    required this.item,
    this.detailLoader,
    this.directoryLoader,
    this.extrasLoader,
    this.seriesLoader,
    this.readerStore,
    this.chapterCache,
    this.chapterLoader,
    this.connectivity,
    this.autoOpenReader = false,
  });

  /// 「点击书籍直接进入阅读」（issue #19 第 3 条）：详情页加载出目录后，
  /// 直接按上次进度进阅读器，并用 pushReplacement 顶掉详情页。仅小说/漫画
  /// 走这条路；听书/短剧仍停留在详情页，加载失败时也停留在详情页。
  final bool autoOpenReader;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic>? _detail;
  BookDetail? _bookDetail;
  SeriesDetail _series = SeriesDetail.empty;
  BookCommentPage _comments = const BookCommentPage();
  bool _commentsLoadingMore = false;
  List<Chapter> _allChapters = [];
  final _scroll = ScrollController();
  bool _loading = true;
  String? _detailError;
  String? _directoryError;
  String? _reviewsError;
  late final String _tab;
  int _loadGeneration = 0;
  int _openGeneration = 0;
  int _historyGeneration = 0;
  int? _resumeIndex;

  /// When the saved place was recorded, for the resume row's muted `3 天前`.
  int? _resumeTime;
  bool _opening = false;
  bool _autoOpened = false;
  ChapterDownload? _download;

  /// 目录联网失败时查到的本地整本缓存；非空即给出「从缓存阅读」入口。
  CachedBook? _cachedBook;

  bool get _supported => kindLabels.containsKey(widget.item.kind);
  bool get _isVideo => isVideoKind(widget.item.kind);
  bool get _isAudio => widget.item.kind == 'audio';
  bool get _isManga => widget.item.kind == 'manga';
  bool get _isBook => widget.item.kind == 'book';
  String get _contentId => widget.item.seriesId ?? widget.item.id;
  String get _chapterUnit => _isVideo
      ? '集'
      : _isManga
      ? '话'
      : '章';
  String get _readLabel => switch (widget.item.kind) {
    'video' || 'manju' => _resumeIndex == null ? '开始观看' : '继续观看',
    'audio' => _resumeIndex == null ? '开始收听' : '继续收听',
    _ => _resumeIndex == null ? '开始阅读' : '继续阅读',
  };

  /// The primary pill names what it will open, e.g. `继续阅读 · 第205章`;
  /// without progress it keeps the plain CTA.
  String get _readBarLabel {
    final index = _resumeIndex;
    if (index == null || _allChapters.isEmpty) return _readLabel;
    final chapter = _allChapters[index.clamp(0, _allChapters.length - 1)];
    return '$_readLabel · ${_chapterNumber(chapter.title)}';
  }

  /// `第205章 风起` → `第205章`; the mockup CTA carries the number only.
  static String _chapterNumber(String title) {
    final match = RegExp(
      r'^第\s*[0-9０-９一二三四五六七八九十百千零两]+\s*[章节回集话]',
    ).firstMatch(title.trim());
    return match?.group(0)?.replaceAll(RegExp(r'\s+'), '') ?? title;
  }

  /// Opens the author's home; null when the payload carried no author id.
  VoidCallback? get _openAuthorAction {
    final author = _bookDetail?.author;
    if (author == null || author.id.isEmpty) return null;
    return () => _openAuthor(author.id, author.name);
  }

  /// 是否已在本地书架。以 [ShelfStore] 为准，写入后由它的 listenable 触发重绘；
  /// 短剧/漫剧官方用的是「追剧」，这里统一沿用「加入书架」，与听书页和书架页
  /// 的文案保持一致。
  bool get _inShelf => ShelfStore.instance.containsItem(widget.item);

  Future<void> _toggleShelf() async {
    if (!ShelfStore.instance.isReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地书架暂不可用，请重试')));
      return;
    }
    final added = await ShelfStore.instance.toggle(widget.item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '已加入书架' : '已移出书架'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tab = _isVideo ? '短剧' : kindLabels[widget.item.kind] ?? '小说';
    // A whole-book download outlives this page: coming back re-attaches to the
    // same batch instead of starting a second one.
    final active = WholeBookDownload.active;
    if (active != null) {
      if (!active.value.running) {
        WholeBookDownload.release(active);
      } else if (active.book.id == _contentId) {
        _download = active;
        active.addListener(_onDownloadChanged);
      }
    }
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    final download = _download;
    if (download != null) {
      download.removeListener(_onDownloadChanged);
      // A running batch keeps going; a finished one can be collected.
      WholeBookDownload.release(download);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    ++_openGeneration;
    ++_historyGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _detailError = null;
        _directoryError = null;
        _reviewsError = null;
        _detail = null;
        _bookDetail = null;
        _series = SeriesDetail.empty;
        _comments = const BookCommentPage();
        _allChapters = const [];
        _opening = false;
        _resumeIndex = null;
        _resumeTime = null;
        _cachedBook = null;
      });
    }

    if (!_supported) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loading = false);
      return;
    }

    // 离线时先摸清本地有没有整本缓存：详情页这条路离线必然失败，不该让用户
    // 对着骨架屏等到目录请求超时。联网时直接返回，在线路径一次缓存都不查。
    unawaited(_resolveCachedCatalogue(generation));

    // Detail and directory are independent. Short-drama IDs sometimes do
    // not have a legacy book-detail record, but their episode list is still
    // perfectly playable. Start both before awaiting either so the page waits
    // for the slower request, not the sum of both request times.
    final detailFuture = _capture(
      (widget.detailLoader ?? ApiClient.instance.detail)(_contentId, tab: _tab),
    );
    final directoryFuture = _capture(
      (widget.directoryLoader ?? ApiClient.instance.directoryChapters)(
        _contentId,
        tab: _tab,
      ),
    );
    // Reviews and cast are cosmetic: they load alongside and never gate the
    // page. Each keeps its own inline error so a failure is visible and
    // retryable in its own section.
    final extrasFuture = _capture(_loadExtras(_contentId));
    final seriesFuture = _isVideo
        ? _capture((widget.seriesLoader ?? _defaultSeries)(_contentId))
        : null;
    final detailResult = await detailFuture;
    final directoryResult = await directoryFuture;
    if (!mounted || generation != _loadGeneration) return;

    final detail = detailResult.value;
    var volumes = directoryResult.value ?? <List<Chapter>>[];

    // A search result can represent a single episode rather than a series.
    // Keep it playable even when the pseries directory endpoint rejects that
    // ID; the video endpoint accepts the episode ID directly.
    if (_isVideo && volumes.isEmpty && widget.item.episodeId != null) {
      volumes = [
        [
          Chapter(
            itemId: widget.item.episodeId!,
            title: widget.item.title,
            volumeName: '剧集',
          ),
        ],
      ];
    }

    final directoryFailed = volumes.isEmpty && directoryResult.error != null;
    CachedBook? cached;
    if (directoryFailed && _isBook) {
      // 联网取目录失败：先看本地有没有整本缓存。有就把「从缓存阅读」的入口
      // 摆出来，而不是只给一个离线时永远不会成功的重试按钮。
      cached = await _cachedCatalogue();
      if (!mounted || generation != _loadGeneration) return;
    }

    setState(() {
      _detail = detail;
      // The rich metadata rides on the same detail response the page already
      // fetches, so no extra request is needed for the masthead.
      _bookDetail = detail == null ? null : BookDetail.fromPayload(detail);
      _allChapters = directoryFailed
          ? const []
          : volumes.expand((volume) => volume).toList(growable: false);
      _cachedBook = cached;
      _detailError = detail == null && detailResult.error != null
          ? userFacingError(detailResult.error!)
          : null;
      _directoryError = directoryFailed
          ? userFacingError(directoryResult.error!)
          : null;
      _loading = false;
    });
    unawaited(_refreshResume());
    unawaited(_maybeAutoOpenReader());

    await _applyExtras(extrasFuture, generation);
    if (!mounted || generation != _loadGeneration) return;

    if (seriesFuture == null) return;
    final series = await seriesFuture;
    if (!mounted || generation != _loadGeneration) return;
    if (series.value case final SeriesDetail loaded) {
      setState(() => _series = loaded);
    }
  }

  /// Applies the review payload or records its own section error.
  Future<void> _applyExtras(
    Future<_Captured<DetailExtras>> future,
    int generation,
  ) async {
    final extras = await future;
    if (!mounted || generation != _loadGeneration) return;
    if (extras.value case final DetailExtras loaded) {
      setState(() {
        _comments = loaded.comments;
        _reviewsError = null;
      });
    } else {
      setState(() {
        _reviewsError = userFacingError(extras.error ?? '书评加载失败');
      });
    }
  }

  /// Retries only the review section; the rest of the page keeps its data.
  Future<void> _retryReviews() async {
    final generation = _loadGeneration;
    setState(() => _reviewsError = null);
    await _applyExtras(_capture(_loadExtras(_contentId)), generation);
  }

  /// Resolves the optional review payload.
  ///
  /// A caller that already injects its own detail or directory loader is
  /// offline by construction (tests, previews), so the page must not reach for
  /// the network behind its back; such callers inject [DetailExtrasLoader] when
  /// they want the review block exercised.
  Future<DetailExtras> _loadExtras(String bookId) {
    final loader = widget.extrasLoader;
    if (loader != null) return loader(bookId);
    if (widget.detailLoader != null || widget.directoryLoader != null) {
      return Future.value(const DetailExtras());
    }
    return _defaultExtras(bookId);
  }

  /// Reply fetching is opt-in for the same reason as [_loadExtras]: a caller
  /// that injected its own loaders is offline, so the review list must not
  /// reach for the network when a row is tapped.
  ReviewReplyLoader? _replyLoader(String bookId) {
    if (widget.detailLoader != null || widget.directoryLoader != null) {
      return null;
    }
    if (bookId.isEmpty) return null;
    return (commentId) =>
        ApiClient.instance.commentReplies(bookId, commentId, groupId: bookId);
  }

  /// Offset-based review paging, under the same offline rule as
  /// [_replyLoader]: injected-loader callers drive their own data, and the
  /// 「全部书评」 affordance stays hidden for them.
  Future<BookCommentPage> Function(int offset)? _commentsLoader() {
    if (widget.detailLoader != null ||
        widget.directoryLoader != null ||
        widget.extrasLoader != null) {
      return null;
    }
    if (_contentId.isEmpty) return null;
    return (offset) =>
        ApiClient.instance.bookComments(_contentId, offset: offset);
  }

  /// Appends the next review page. A failure keeps the loaded list and just
  /// re-enables the affordance so it can be retried.
  Future<void> _loadMoreComments() async {
    final loader = _commentsLoader();
    if (loader == null || _commentsLoadingMore || !_comments.hasMore) return;
    setState(() => _commentsLoadingMore = true);
    try {
      final next = await loader(_comments.nextOffset);
      if (!mounted) return;
      setState(() {
        _comments = BookCommentPage(
          comments: [..._comments.comments, ...next.comments],
          totalCount: next.totalCount > 0
              ? next.totalCount
              : _comments.totalCount,
          scoreCount: _comments.scoreCount,
          scoreContext: _comments.scoreContext,
          hasMore: next.hasMore,
          nextOffset: next.nextOffset,
        );
        _commentsLoadingMore = false;
      });
    } on Exception {
      if (mounted) setState(() => _commentsLoadingMore = false);
    }
  }

  /// The chapter rows the directory preview shows: current ±1, or the first
  /// three when the reader has no saved place.
  List<Chapter> _previewChapters() {
    if (_allChapters.isEmpty) return const [];
    final current = _resumeIndex;
    if (current == null) {
      return _allChapters.take(_previewChapterCount).toList(growable: false);
    }
    final last = _allChapters.length - 1;
    final start = (current.clamp(0, last) - 1).clamp(
      0,
      (_allChapters.length - _previewChapterCount).clamp(0, last),
    );
    final end = (start + _previewChapterCount).clamp(0, _allChapters.length);
    return _allChapters.sublist(start, end);
  }

  /// Index of the current chapter inside [_previewChapters], or null.
  int? _previewCurrentIndex() {
    final current = _resumeIndex;
    if (current == null || _allChapters.isEmpty) return null;
    final id = _allChapters[current.clamp(0, _allChapters.length - 1)].itemId;
    final index = _previewChapters().indexWhere((c) => c.itemId == id);
    return index < 0 ? null : index;
  }

  /// Same offline rule as [_loadExtras]: an injected loader means the caller
  /// drives its own data.
  Future<SeriesDetail> _defaultSeries(String seriesId) {
    if (widget.detailLoader != null || widget.directoryLoader != null) {
      return Future.value(SeriesDetail.empty);
    }
    return ApiClient.instance.seriesDetail(seriesId);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final desktop = isWindowsDesktop && MediaQuery.sizeOf(context).width >= 700;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          (palette.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: palette.canvas,
              ),
      child: Scaffold(
        backgroundColor: palette.canvas,
        appBar: desktop
            ? null
            : AppBar(
                backgroundColor: palette.canvas,
                surfaceTintColor: Colors.transparent,
                scrolledUnderElevation: 0,
                elevation: 0,
                toolbarHeight: 52,
                leadingWidth: 56,
                leading: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Center(
                    child: IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.maybePop(context),
                      style: IconButton.styleFrom(
                        foregroundColor: palette.ink,
                        fixedSize: const Size(36, 36),
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(LucideIcons.chevron_left, size: 20),
                    ),
                  ),
                ),
                titleSpacing: 0,
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: ValueListenableBuilder<int>(
                      valueListenable: ShelfStore.instance.listenable,
                      builder: (context, _, _) => DetailShelfPill(
                        inShelf: _inShelf,
                        enabled: !_loading && _supported,
                        onTap: _toggleShelf,
                      ),
                    ),
                  ),
                ],
              ),
        body: desktop ? _desktopBody(palette) : _phoneBody(palette),
        bottomNavigationBar: desktop
            ? null
            : DetailReadBar(
                label: _readBarLabel,
                opening: _opening,
                enabled: _supported && !_loading && _allChapters.isNotEmpty,
                actionsEnabled: _supported && _isBook,
                onRead: _openLastPosition,
                onListen: _isBook ? _openListening : null,
                onDownload: _isBook ? _showDownloadSheet : null,
                download: _isBook ? _downloadProgress : null,
              ),
      ),
    );
  }

  /// 手机版正文：hero 之后是简介 / 目录 / 书评 / ID，全部由 mockup 的
  /// 16dp gutter 与 20dp 段落间距串联，不再有卡片。
  Widget _phoneBody(HomePalette palette) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 840),
      // The mockup resets CSS letter-spacing to normal; Material's body styles
      // carry 0.25, which reflows CJK paragraphs by a character per line.
      child: DefaultTextStyle.merge(
        style: const TextStyle(letterSpacing: 0),
        child: RefreshIndicator(
          onRefresh: _load,
          color: palette.eink ? palette.ink : HomePalette.accent,
          backgroundColor: palette.surface,
          child: CustomScrollView(
            key: const Key('detail_scroll'),
            controller: _scroll,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: DetailHero(
                  item: widget.item,
                  detail: _bookDetail,
                  onOpenAuthor: _openAuthorAction,
                  lastChapterTitle: _latestChapterTitle,
                ),
              ),
              SliverToBoxAdapter(
                child: !_supported
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: homeGutter,
                        ),
                        child: _stateCard(
                          icon: LucideIcons.file_question_mark,
                          title: '暂不支持此内容类型',
                          message: '可以返回继续发现其他故事。',
                        ),
                      )
                    : _loading
                    ? _loadingView(palette)
                    : _content(palette),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// 桌面两栏布局的左栏卡片（PR #104 评审原型）：封面、书名、元信息、书架/刷新
  /// 和主操作全部收进一张白卡，主按钮不再横跨整个窗口底部。
  Widget _desktopSideCard(HomePalette palette, {bool compact = false}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              ValueListenableBuilder<int>(
                valueListenable: ShelfStore.instance.listenable,
                builder: (context, _, _) => DetailShelfPill(
                  inShelf: _inShelf,
                  enabled: !_loading && _supported,
                  onTap: _toggleShelf,
                  keyName: 'detail_shelf_button_desktop',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          DetailHero(
            item: widget.item,
            detail: _bookDetail,
            onOpenAuthor: _openAuthorAction,
            lastChapterTitle: _latestChapterTitle,
            desktop: true,
            compactDesktop: compact,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('detail_read_button_desktop'),
            onPressed: _opening || _loading || _allChapters.isEmpty
                ? null
                : () => unawaited(_openLastPosition()),
            style: detailPrimaryButtonStyle(
              palette,
              minimumSize: const Size.fromHeight(44),
            ),
            icon: Icon(homeKindIcon(widget.item.kind), size: 18),
            label: Text(
              _opening ? '正在打开…' : _readBarLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isBook) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('detail_listen_button_desktop'),
                    onPressed: _loading || _allChapters.isEmpty
                        ? null
                        : _openListening,
                    style: detailOutlineButtonStyle(
                      palette,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    icon: const Icon(LucideIcons.headphones, size: 16),
                    label: const Text('听书'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('detail_download_button_desktop'),
                    onPressed: _loading || _allChapters.isEmpty
                        ? null
                        : _toggleDownload,
                    style: detailOutlineButtonStyle(
                      palette,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    icon: const Icon(LucideIcons.download, size: 16),
                    label: Text(_downloadProgress == null ? '下载' : '下载中'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          DetailIdRow(id: _contentId, compact: true),
        ],
      ),
    );
  }

  /// Masthead metadata, author, stats, summary, tags, catalog and reviews —
  /// the section order of the official detail page.
  /// 右栏分节（PR #104 评审原型）：桌面宽屏下把「简介 / 目录 / 评论」拆成可切换
  /// 的三节，避免两百多章的目录把详情页拉成一条长滚动；移动端仍按官方顺序整列
  /// 铺开，行为不变。
  int _desktopSection = 0;

  Widget _desktopPanel(HomePalette palette, Widget child) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: palette.line),
    ),
    child: child,
  );

  Widget _desktopBody(HomePalette palette) {
    final width = MediaQuery.sizeOf(context).width;
    final threeColumns = width >= 1400;
    final sideWidth = width >= 1200 ? 340.0 : 320.0;
    Widget content() => !_supported
        ? _stateCard(
            icon: LucideIcons.file_question_mark,
            title: '暂不支持此内容类型',
            message: '可以返回继续发现其他故事。',
          )
        : _loading
        ? _loadingView(palette)
        : _content(palette, desktop: true);
    Widget mainScroll() => RefreshIndicator(
      onRefresh: _load,
      color: palette.eink ? palette.ink : HomePalette.accent,
      backgroundColor: palette.surface,
      child: SingleChildScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        child: content(),
      ),
    );
    if (width < 1000) {
      return RefreshIndicator(
        onRefresh: _load,
        color: palette.eink ? palette.ink : HomePalette.accent,
        backgroundColor: palette.surface,
        child: SingleChildScrollView(
          key: const Key('desktop-detail-compact'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _desktopSideCard(palette, compact: true),
              const SizedBox(height: 24),
              content(),
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Row(
            key: Key(
              threeColumns ? 'desktop-detail-three' : 'desktop-detail-two',
            ),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: sideWidth,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 32),
                  child: _desktopSideCard(palette),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: mainScroll(),
                  ),
                ),
              ),
              if (threeColumns) ...[
                const SizedBox(width: 24),
                SizedBox(
                  width: 260,
                  child: SingleChildScrollView(
                    key: const Key('desktop-detail-information'),
                    padding: const EdgeInsets.only(bottom: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _desktopInfoRail(palette),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(HomePalette palette, {bool desktop = false}) {
    final hasReviews =
        _comments.comments.isNotEmpty || _comments.totalCount > 0;
    if (!desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _introSection(palette),
          _directorySection(),
          _reviewsSection(palette, hasReviews: hasReviews, showEmpty: false),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: DetailIdRow(id: _contentId),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _desktopSectionTabs(palette),
        const SizedBox(height: 20),
        _desktopPanel(
          palette,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (_desktopSection) {
              1 => _desktopDirectoryTab(palette),
              2 => <Widget>[
                _reviewsSection(
                  palette,
                  hasReviews: hasReviews,
                  showEmpty: true,
                ),
              ],
              _ => <Widget>[_introSection(palette, desktop: true)],
            },
          ),
        ),
      ],
    );
  }

  /// `3 天前` — when the saved place was written, muted in 目录 progress.
  String? _resumeTimeLabel() {
    final time = _resumeTime;
    if (time == null) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(time);
    final diff = DateTime.now().difference(date);
    if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${date.month}月${date.day}日';
  }

  Widget _introSection(HomePalette palette, {bool desktop = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_detailError != null) ...[
          const DetailSectionHeader(title: '简介'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: DetailInlineError(message: _detailError!, onRetry: _load),
          ),
        ] else ...[
          DetailDescription(
            text: extractMediaDescription(_detail),
            desktop: desktop,
          ),
        ],
        if (_series.cast.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(homeGutter, 18, homeGutter, 0),
            child: DetailCastRow(cast: _series.cast),
          ),
      ],
    );
  }

  /// `完结 共820章 · 全部 ›` — the one place the chapter count appears.
  String get _directoryTrailing {
    final status = _bookDetail?.statusLabel ?? '';
    final count = '共${_allChapters.length}$_chapterUnit';
    return '${status.isEmpty ? '' : '$status '}$count · 全部';
  }

  /// The newest chapter for the hero's `更新至 …` line: the payload's own
  /// title first, then the last catalogue entry.
  String? get _latestChapterTitle {
    final payload = _bookDetail?.lastChapterTitle.trim() ?? '';
    if (payload.isNotEmpty) return payload;
    if (_allChapters.isEmpty) return null;
    final title = _allChapters.last.title.trim();
    return title.isEmpty ? null : title;
  }

  Widget _directorySection() {
    final preview = _previewChapters();
    return DetailDirectorySection(
      trailing: _allChapters.isEmpty ? '' : _directoryTrailing,
      preview: preview,
      currentIndex: _previewCurrentIndex(),
      resumeIndex: _resumeIndex,
      chapterCount: _allChapters.length,
      readTimeLabel: _resumeTimeLabel(),
      error: _directoryError,
      onOpenAll: _openDirectory,
      onRetry: _load,
      onOpenChapter: (chapter) => _openChapter(chapter),
    );
  }

  Widget _reviewsSection(
    HomePalette palette, {
    required bool hasReviews,
    required bool showEmpty,
  }) {
    if (_reviewsError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DetailSectionHeader(title: '书评'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: DetailInlineError(
              message: _reviewsError!,
              onRetry: _retryReviews,
            ),
          ),
        ],
      );
    }
    if (!hasReviews) {
      return showEmpty ? _emptyReviews(palette) : const SizedBox.shrink();
    }
    return DetailReviews(
      page: _comments,
      detail: _bookDetail,
      bookId: _contentId,
      onLoadMore: _comments.hasMore ? _loadMoreComments : null,
      onOpenAll: _openAllReviews,
      loadingMore: _commentsLoadingMore,
    );
  }

  List<Widget> _desktopDirectoryTab(HomePalette palette) => [
    Text(
      _directoryTrailing,
      style: TextStyle(color: palette.muted, fontSize: 13),
    ),
    const SizedBox(height: 16),
    SizedBox(
      height: (MediaQuery.sizeOf(context).height - 280).clamp(260.0, 640.0),
      child: DesktopChapterSidebar(
        width: double.infinity,
        chapterUnit: _chapterUnit,
        chapters: _allChapters,
        currentIndex: _resumeIndex ?? -1,
        onSelected: (index) => unawaited(_openChapter(_allChapters[index])),
      ),
    ),
  ];

  /// Three-column desktop rail: the tags the main column omits.
  List<Widget> _desktopInfoRail(HomePalette palette) {
    final detail = _bookDetail;
    if (detail == null || detail.tags.isEmpty) return const [];
    return [DetailTagChips(tags: detail.tags, desktop: true)];
  }

  Widget _desktopSectionTabs(HomePalette palette) {
    const labels = ['简介', '目录', '评论'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              key: Key('detail_section_$i'),
              borderRadius: BorderRadius.circular(18),
              onTap: () {
                setState(() => _desktopSection = i);
                if (_scroll.hasClients &&
                    MediaQuery.sizeOf(context).width >= 1000) {
                  _scroll.jumpTo(0);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _desktopSection == i ? palette.ink : palette.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: _desktopSection == i ? palette.ink : palette.line,
                  ),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: _desktopSection == i ? palette.canvas : palette.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _emptyReviews(HomePalette palette) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Text(
      '还没有读者评论',
      style: TextStyle(color: palette.muted, fontSize: 13),
    ),
  );

  Widget _loadingView(HomePalette palette) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const DetailSkeleton(),
      Padding(
        padding: const EdgeInsets.fromLTRB(homeGutter, 18, homeGutter, 24),
        child: Text(
          '正在加载书籍与目录',
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
      ),
    ],
  );

  Widget _stateCard({
    required IconData icon,
    required String title,
    required String message,
  }) {
    final palette = HomePalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        children: [
          Icon(icon, color: palette.muted, size: 30),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.ink,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 13, height: 1.6),
          ),
        ],
      ),
    );
  }

  /// Opens the author's home. The author id is required; the row hides the
  /// affordance when the payload carried none.
  Future<void> _openAuthor(String authorId, String name) async {
    await _push(AuthorPage(authorId: authorId, fallbackName: name));
  }

  Future<void> _openDirectory() async {
    if (_allChapters.isEmpty) return;
    // Browsing the catalog supersedes a pending asynchronous resume action.
    ++_openGeneration;
    if (_opening) setState(() => _opening = false);
    final chapter = await showDetailDirectory(
      context,
      chapters: _allChapters,
      chapterUnit: _chapterUnit,
      currentIndex: _resumeIndex,
    );
    if (mounted && chapter != null) _openChapter(chapter);
  }

  void _openAllReviews() {
    showDetailReviewsSheet(
      context,
      bookId: _contentId,
      title: _bookDetail?.title ?? widget.item.title,
      initialComments: _comments,
      replyLoader: _replyLoader(_contentId),
      loader: _commentsLoader(),
    );
  }

  /// Opens the listening page for the same work, starting where the saved
  /// audio progress left off.
  Future<void> _openListening() async {
    if (_allChapters.isEmpty || _opening) return;
    final generation = ++_openGeneration;
    setState(() => _opening = true);
    try {
      // Listening progress lives in the audio scope, even when the entry
      // being browsed is the text edition of the same book.
      final store = widget.readerStore ?? LibraryStore.instance;
      Map<String, dynamic>? saved;
      try {
        saved = await AudioHistory(store).load(_contentId);
      } catch (_) {
        // History is optional. Its absence must not block opening a book.
        saved = null;
      }
      if (!mounted || generation != _openGeneration || _allChapters.isEmpty) {
        return;
      }
      final index = resumeAudioChapterIndex(saved, _allChapters) ?? 0;
      await _push(
        AudioPage(
          bookId: _contentId,
          title: widget.item.title,
          cover: widget.item.cover,
          historyStore: widget.readerStore,
          chapters: _allChapters,
          startIndex: index,
        ),
      );
    } finally {
      if (mounted && generation == _openGeneration) {
        setState(() => _opening = false);
      }
    }
  }

  /// Starts — or, while a batch runs, stops — the whole-book download.
  ///
  /// The range sheet stays with the reader, where picking a batch size still
  /// makes sense; here one tap means the whole book: every remaining chapter in
  /// one batch, pinned so the cache's LRU budget cannot truncate it.
  ///
  /// Note: 详情页「下载」直接下全本、下载的章节不受缓存预算清理 — 见
  /// .agents/notes/implemented/feature/2026-09-20-offline-whole-book-download.md
  void _toggleDownload() {
    if (_allChapters.isEmpty) return;
    final running = _download;
    if (running != null && running.value.running) {
      running.cancel();
      return;
    }
    final cache = widget.chapterCache ?? ChapterCacheStore.instance;
    unawaited(
      _startWholeBookDownload(cache).catchError((Object _) {
        if (mounted) _snack('缓存未能开始，请重试');
      }),
    );
  }

  /// Starts the whole-book batch from the first chapter that is not cached yet.
  ///
  /// The range starts at the resume position (the user's own place in the book)
  /// but skips over chapters already on disk, so a batch interrupted by the
  /// network can be resumed instead of re-downloading from the start: an
  /// interrupted download of chapters 11–332 used to restart at 11 and rewrite
  /// all 322 of them. [ChapterDownload] still skips cached chapters one by one
  /// as a safety net; this only avoids reporting progress for work that needs
  /// no re-fetching.
  Future<void> _startWholeBookDownload(ChapterCache cache) async {
    final from = (_resumeIndex ?? 0).clamp(0, _allChapters.length - 1);
    final cached = await cache.cachedChapterIds(_contentId);
    if (!mounted) return;
    var startIndex = -1;
    for (var i = from; i < _allChapters.length; i++) {
      if (!cached.contains(_allChapters[i].itemId)) {
        startIndex = i;
        break;
      }
    }
    if (startIndex < 0) {
      _snack('已全部缓存');
      return;
    }
    final count = _allChapters.length - startIndex;
    _attachDownload(
      WholeBookDownload.start(
        cache: cache,
        book: CachedBook(
          id: _contentId,
          title: widget.item.title,
          cover: widget.item.cover,
          chapters: _allChapters,
        ),
        loader:
            widget.chapterLoader ??
            (chapter) => ApiClient.instance.contentText(chapter.itemId),
        startIndex: startIndex,
        count: count,
      ),
    );
  }

  /// 底栏「下载」：整本下载与离线缓存收进同一个弹层，手机上不再多摆按钮。
  Future<void> _showDownloadSheet() async {
    final palette = HomePalette.of(context);
    final progress = _downloadProgress;
    final cached = _cachedBook != null;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: homeSheetColor(palette),
      shape: homeSheetShape(palette),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          key: const Key('detail_download_sheet'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DetailSheetOption(
                key: const Key('detail_download_all'),
                icon: LucideIcons.download,
                title: '整本下载',
                subtitle: progress != null
                    ? '下载中 ${progress.completed}/${progress.total}'
                    : (_allChapters.isEmpty
                          ? '目录加载中'
                          : '缓存全部 ${_allChapters.length}$_chapterUnit'),
                enabled: _allChapters.isNotEmpty,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleDownload();
                },
              ),
              DetailSheetOption(
                key: const Key('detail_download_cached'),
                icon: LucideIcons.book_open,
                title: '离线缓存',
                subtitle: cached ? '用本地整本缓存直接阅读' : '暂无本地缓存',
                enabled: cached,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_readCached());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The running batch as the read bar renders it; null while idle.
  ({int completed, int total})? get _downloadProgress {
    final download = _download;
    if (download == null || !download.value.running) return null;
    final state = download.value;
    return (completed: state.completed, total: state.total);
  }

  void _attachDownload(ChapterDownload download) {
    _download?.removeListener(_onDownloadChanged);
    _download = download;
    download.addListener(_onDownloadChanged);
    if (mounted) setState(() {});
  }

  /// Progress, and the final report of the attached batch.
  void _onDownloadChanged() {
    final download = _download;
    if (download == null) return;
    final state = download.value;
    if (!state.running) {
      download.removeListener(_onDownloadChanged);
      _download = null;
      WholeBookDownload.release(download);
      final message = state.message;
      if (message != null) _snack(message);
    }
    if (mounted) setState(() {});
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<Map<String, dynamic>?> _readSavedRecord() async {
    final store = widget.readerStore ?? LibraryStore.instance;
    try {
      final saved = switch (widget.item.kind) {
        'video' || 'manju' => await PlayerHistory(store).load(_contentId),
        'audio' => await AudioHistory(store).load(_contentId),
        'manga' => await ReaderHistory(
          scopedHistoryStore(store, 'manga'),
        ).load(_contentId),
        _ => await ReaderHistory(store).load(_contentId),
      };
      if (saved?['kind'] != null &&
          saved?['kind'] != widget.item.kind &&
          !(_isVideo && isVideoKind(saved!['kind'].toString()))) {
        return null;
      }
      // Legacy text-reading records sometimes encode the chapter ID as a number.
      return !_isVideo && saved != null
          ? {
              ...saved,
              if (saved['chapterId'] != null)
                'chapterId': saved['chapterId'].toString(),
            }
          : saved;
    } catch (_) {
      // History is optional. Its absence must not block opening a book.
      return null;
    }
  }

  int? _savedIndex(Map<String, dynamic>? saved) => _isAudio
      ? resumeAudioChapterIndex(saved, _allChapters)
      : resumeEpisodeIndex(saved, _allChapters);

  Future<void> _refreshResume() async {
    final generation = ++_historyGeneration;
    final saved = await _readSavedRecord();
    if (!mounted || generation != _historyGeneration) return;
    final next = _savedIndex(saved);
    final time = switch (saved?['time']) {
      final num value when value > 0 => value.toInt(),
      _ => null,
    };
    if (next == _resumeIndex && time == _resumeTime) return;
    setState(() {
      _resumeIndex = next;
      _resumeTime = time;
    });
  }

  /// 「点击书籍直接进入阅读」：详情页加载出目录后，直接按上次进度进
  /// 阅读器。目录为空（加载失败/无章节）时不触发，用户留在详情页看错误
  /// 与重试；`_autoOpened` 保证同一详情页实例只自动进一次。
  Future<void> _maybeAutoOpenReader() async {
    if (!widget.autoOpenReader ||
        _autoOpened ||
        !(_isBook || _isManga) ||
        _allChapters.isEmpty) {
      return;
    }
    _autoOpened = true;
    await _openLastPosition(replace: true);
  }

  Future<void> _openLastPosition({bool replace = false}) async {
    if (_opening || _allChapters.isEmpty) return;
    final generation = ++_openGeneration;
    setState(() => _opening = true);
    try {
      final saved = await _readSavedRecord();
      if (!mounted || generation != _openGeneration || _allChapters.isEmpty) {
        return;
      }
      final restored = _savedIndex(saved);
      if (saved?['fanqieImported'] == true &&
          saved?['chapterId'] != null &&
          restored == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导入的章节暂不在当前目录中，请在目录中选择可阅读章节')),
        );
        return;
      }
      final index = restored ?? 0;
      _openChapter(_allChapters[index], replace: replace);
    } finally {
      if (mounted && generation == _openGeneration) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _openChapter(Chapter chapter, {bool replace = false}) async {
    // An explicit chapter selection supersedes any pending resume lookup.
    ++_openGeneration;
    ++_historyGeneration;
    if (_opening) setState(() => _opening = false);
    final index = _allChapters.indexWhere((c) => c.itemId == chapter.itemId);
    final startIndex = index < 0 ? 0 : index;
    final page = switch (widget.item.kind) {
      'video' || 'manju' => PlayerPage(
        bookId: _contentId,
        kind: widget.item.kind,
        title: widget.item.title,
        cover: widget.item.cover,
        historyStore: widget.readerStore,
        eps: _allChapters,
        startIndex: startIndex,
        // 搜索→详情页→播放与短剧页同源（kind 已是 video/manju），不传
        // shortSeries 会让长按面板/弹幕/剧评/已看标记/清晰度整组失效
        // （它们都挂在 PlayerPage.shortSeries 门上）。
        shortSeries: true,
      ),
      'audio' => AudioPage(
        bookId: _contentId,
        title: widget.item.title,
        cover: widget.item.cover,
        historyStore: widget.readerStore,
        chapters: _allChapters,
        startIndex: startIndex,
        resumeSession: false,
      ),
      'manga' => ComicReaderPage(
        bookId: _contentId,
        title: widget.item.title,
        cover: widget.item.cover,
        readerStore: widget.readerStore,
        chapters: _allChapters,
        startIndex: startIndex,
        // 阅读器内「加入书架」沿用它：书架 key 需要 seriesId/kind 一致（#103）。
        shelfItem: widget.item,
      ),
      _ => ReaderPage(
        bookId: _contentId,
        title: widget.item.title,
        cover: widget.item.cover,
        readerStore: widget.readerStore,
        chapters: _allChapters,
        startIndex: startIndex,
        shelfItem: widget.item,
        // 详情页注入的缓存（离线下载/测试用内存缓存）即阅读器的缓存；
        // 生产调用方不传时为 null，阅读器沿用默认的 ChapterCacheStore。
        chapterCache: widget.chapterCache,
      ),
    };
    await _push(page, replace: replace);
  }

  Future<void> _push(Widget page, {bool replace = false}) async {
    if (replace) {
      // 直接进入阅读：顶掉详情页，阅读器返回时回到点书的页面，而不是详情页。
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(builder: (_) => page),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => page),
      );
    }
    if (mounted) unawaited(_refreshResume());
  }

  /// 本地整本缓存：目录请求失败时用它兜底，让已下载的书仍能离线阅读。
  Future<CachedBook?> _cachedCatalogue() async {
    try {
      return await (widget.chapterCache ?? ChapterCacheStore.instance)
          .cachedBook(_contentId);
    } catch (_) {
      return null;
    }
  }

  /// 离线时提前查一次本地缓存：详情页这条路离线必然失败，不该等目录请求超时
  /// 才把「从缓存阅读」给出来。联网时立即返回，在线路径一次缓存都不查。
  Future<void> _resolveCachedCatalogue(int generation) async {
    if (!_isBook) return;
    final connectivity = await (widget.connectivity ?? currentConnectivity)();
    if (connectivity.online || !mounted || generation != _loadGeneration) {
      return;
    }
    final cached = await _cachedCatalogue();
    if (cached == null || !mounted || generation != _loadGeneration) return;
    setState(() => _cachedBook = cached);
  }

  Future<void> _readCached() async {
    final book = _cachedBook;
    if (book == null) return;
    final opened = await openCachedBook(
      context,
      book: book,
      cache: widget.chapterCache,
      readerStore: widget.readerStore,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('缓存已失效，请联网后重试')));
    }
  }
}

/// 点书卡片的统一入口：默认进详情页；用户开了设置 → 阅读 →「点书直达阅读器」
/// 时，详情页加载完目录后自动按上次进度进阅读器（小说/漫画），返回时回到点书
/// 的页面。听书/短剧与加载失败时仍停留在详情页。
///
/// [entry] 决定用哪条偏好（issue #103）：书架、阅读历史这类「我的书」入口要显式
/// 传 [BookOpenEntry.shelf]，发现入口用默认值即可。调用方不要再直接
/// `Navigator.push(DetailPage(...))`，否则开关对那个入口不生效。
Future<void> openBookDetail(
  BuildContext context,
  MediaItem item, {
  BookOpenEntry entry = BookOpenEntry.discover,
}) async {
  final preferences = BookOpenPreferences.instance;
  await preferences.load();
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => DetailPage(
        item: item,
        autoOpenReader: preferences.directReaderFor(entry),
      ),
    ),
  );
}
