import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_summary.dart';
import '../models/media_item.dart';
import '../models/media_description.dart';
import '../models/series_detail.dart';
import '../services/api_client.dart';
import '../services/audio_history.dart';
import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/player_history.dart';
import '../services/reader_history.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/detail/detail_chapter_row.dart';
import '../widgets/detail/detail_description.dart';
import '../widgets/detail/detail_directory_sheet.dart';
import '../widgets/detail/detail_hero.dart';
import '../widgets/detail/detail_id_row.dart';
import '../widgets/detail/detail_read_bar.dart';
import '../widgets/detail/detail_reviews.dart';
import '../widgets/detail/detail_sections.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/media_card.dart';
import 'audio_page.dart';
import 'author_page.dart';
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

/// Loads opening excerpts for the given chapter item ids in one request.
///
/// Note: 上游 `summary` 实际是正文开头，故按试读预览呈现 — 见
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
typedef ChapterPreviewLoader =
    Future<ChapterSummary> Function(List<String> itemIds);

/// How many chapter rows the detail preview block shows, and therefore how many
/// excerpts it requests.
const _previewChapterCount = 3;

Future<DetailExtras> _defaultExtras(String bookId) async {
  try {
    return DetailExtras(
      comments: await ApiClient.instance.bookComments(bookId),
    );
  } on Exception {
    // Reviews are decoration; a failure must not affect the page.
    return const DetailExtras();
  }
}

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

  /// Opening excerpts for the preview block's chapters. Injectable like the
  /// rest; leaving it null for an offline caller disables the excerpts.
  final ChapterPreviewLoader? previewLoader;

  /// Series detail (cast list) for short dramas and manju. Only consulted for
  /// video kinds; other content has no cast.
  final Future<SeriesDetail> Function(String seriesId)? seriesLoader;
  final ReaderStore? readerStore;

  const DetailPage({
    super.key,
    required this.item,
    this.detailLoader,
    this.directoryLoader,
    this.extrasLoader,
    this.previewLoader,
    this.seriesLoader,
    this.readerStore,
  });

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic>? _detail;
  BookDetail? _bookDetail;
  SeriesDetail _series = SeriesDetail.empty;
  BookCommentPage _comments = const BookCommentPage();
  ChapterSummary _chapterPreviews = ChapterSummary.empty;
  List<Chapter> _allChapters = [];
  final _scroll = ScrollController();
  final _compactTitle = ValueNotifier(false);
  bool _loading = true;
  String? _error;
  late final String _tab;
  int _loadGeneration = 0;
  int _openGeneration = 0;
  int _historyGeneration = 0;
  int? _resumeIndex;
  bool _opening = false;

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

  @override
  void initState() {
    super.initState();
    _tab = _isVideo ? '短剧' : kindLabels[widget.item.kind] ?? '小说';
    _scroll.addListener(_onScroll);
    _load();
  }

  void _onScroll() {
    final compact = _scroll.hasClients && _scroll.offset > 280;
    if (_compactTitle.value != compact) _compactTitle.value = compact;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _compactTitle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    ++_openGeneration;
    ++_historyGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _detail = null;
        _bookDetail = null;
        _series = SeriesDetail.empty;
        _comments = const BookCommentPage();
        _allChapters = const [];
        _opening = false;
        _resumeIndex = null;
      });
    }

    if (!_supported) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loading = false);
      return;
    }

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
    // Reviews are cosmetic: they load alongside and never gate the page.
    final extrasFuture = _capture(_loadExtras(_contentId));
    // Short-drama cast lives on a series endpoint the reading API does not
    // expose, so it is fetched separately and only for video kinds.
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

    if (volumes.isEmpty && directoryResult.error != null) {
      setState(() {
        _error = '${directoryResult.error}';
        _loading = false;
      });
      return;
    }
    setState(() {
      _detail = detail;
      // The rich metadata rides on the same detail response the page already
      // fetches, so no extra request is needed for the masthead or stats row.
      _bookDetail = detail == null ? null : BookDetail.fromPayload(detail);
      _allChapters = volumes.expand((volume) => volume).toList(growable: false);
      // A missing optional detail response should not hide a usable list.
      _error = detail == null && detailResult.error != null && volumes.isEmpty
          ? '${detailResult.error}'
          : null;
      _loading = false;
    });
    unawaited(_refreshResume());
    unawaited(_loadChapterPreviews(generation));

    final extras = await extrasFuture;
    if (!mounted || generation != _loadGeneration) return;
    if (extras.value case final DetailExtras loaded) {
      setState(() => _comments = loaded.comments);
    }

    if (seriesFuture == null) return;
    final series = await seriesFuture;
    if (!mounted || generation != _loadGeneration) return;
    if (series.value case final SeriesDetail loaded) {
      setState(() => _series = loaded);
    }
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

  /// Loads opening excerpts for the chapters the preview block shows.
  ///
  /// One request covers all of them. The upstream field is named `summary`, but
  /// what it actually returns is the start of the chapter's own text, so the UI
  /// labels it a preview rather than a synopsis.
  Future<void> _loadChapterPreviews(int generation) async {
    final loader = _previewLoader();
    if (loader == null) return;
    final ids = _allChapters
        .take(_previewChapterCount)
        .map((chapter) => chapter.itemId)
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) return;
    final previews = await loader(ids);
    if (!mounted || generation != _loadGeneration) return;
    setState(() => _chapterPreviews = previews);
  }

  /// Null for offline callers, same rule as [_loadExtras].
  ChapterPreviewLoader? _previewLoader() {
    final injected = widget.previewLoader;
    if (injected != null) return injected;
    if (widget.detailLoader != null || widget.directoryLoader != null) {
      return null;
    }
    if (_contentId.isEmpty) return null;
    return (itemIds) =>
        ApiClient.instance.chapterSummaries(_contentId, itemIds);
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
        appBar: AppBar(
          backgroundColor: palette.canvas,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          elevation: 0,
          toolbarHeight: 60,
          leadingWidth: 68,
          leading: Padding(
            padding: const EdgeInsets.only(left: 20),
            child: IconButton(
              tooltip: '返回',
              onPressed: () => Navigator.maybePop(context),
              style: IconButton.styleFrom(foregroundColor: palette.ink),
              icon: const Icon(LucideIcons.arrow_left, size: 23),
            ),
          ),
          centerTitle: true,
          title: ValueListenableBuilder<bool>(
            valueListenable: _compactTitle,
            builder: (context, compact, _) => AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: Text(
                compact
                    ? widget.item.title
                    : '${homeKindLabel(widget.item.kind)}详情',
                key: ValueKey(compact),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: compact ? palette.ink : palette.muted,
                  fontSize: 14,
                  fontWeight: compact ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: IconButton(
                key: const Key('detail_refresh_button'),
                tooltip: '刷新详情',
                onPressed: _loading || !_supported ? null : _load,
                style: IconButton.styleFrom(
                  foregroundColor: palette.ink,
                  disabledForegroundColor: palette.muted,
                ),
                icon: const Icon(LucideIcons.refresh_cw, size: 20),
              ),
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: RefreshIndicator(
              onRefresh: _load,
              color: HomePalette.accent,
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
                      scroll: _scroll,
                      detail: _bookDetail,
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    sliver: SliverToBoxAdapter(
                      child: !_supported
                          ? _stateCard(
                              icon: LucideIcons.file_question_mark,
                              title: '暂不支持此内容类型',
                              message: '可以返回继续发现其他故事。',
                            )
                          : _loading
                          ? _loadingView(palette)
                          : _error != null
                          ? _stateCard(
                              icon: LucideIcons.wifi_off,
                              title: '暂时没能加载章节',
                              message: '请检查网络连接，再试一次。',
                              retry: true,
                            )
                          : _content(palette),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: _supported && _allChapters.isNotEmpty
            ? DetailReadBar(
                label: _readLabel,
                icon: homeKindIcon(widget.item.kind),
                opening: _opening,
                resumeTitle: _resumeIndex == null
                    ? null
                    : _allChapters[_resumeIndex!].title,
                onRead: _openLastPosition,
                onListen: _isBook ? _openListening : null,
                onDownload: _isBook ? _showDownload : null,
              )
            : null,
      ),
    );
  }

  /// Masthead metadata, author, stats, summary, tags, catalog and reviews —
  /// the section order of the official detail page.
  Widget _content(HomePalette palette) {
    final detail = _bookDetail;
    final author = detail?.author;
    final score = detail?.scoreValue;
    final stats = <DetailStat>[
      if (detail != null && detail.rankTitle.isNotEmpty)
        DetailStat(
          value: detail.rankTitle,
          label: detail.rank.isEmpty ? '榜单' : detail.rank.first.text,
          icon: LucideIcons.trophy,
          accent: true,
        ),
      if (detail != null && detail.readLabel.isNotEmpty)
        DetailStat(value: detail.readLabel, label: '正在阅读'),
      if (score != null)
        DetailStat(
          value: detail!.scoreLabel,
          label: _comments.scoreLabel.isEmpty ? '读者评分' : _comments.scoreLabel,
          stars: score / 2,
        ),
    ];
    final trailing = [
      if (detail?.statusLabel.isNotEmpty == true) detail!.statusLabel,
      '共 ${_allChapters.length} $_chapterUnit',
    ].join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (author != null && author.name.isNotEmpty) ...[
          DetailAuthorRow(
            author: author,
            onOpenAuthor: author.id.isEmpty
                ? null
                : () => _openAuthor(author.id, author.name),
          ),
          const SizedBox(height: 18),
        ],
        DetailStatsRow(stats: stats),
        const SizedBox(height: 20),
        if (_series.cast.isNotEmpty) ...[
          DetailCastRow(cast: _series.cast),
          const SizedBox(height: 20),
        ],
        DetailDescription(text: extractMediaDescription(_detail)),
        if (detail != null && detail.tags.isNotEmpty) ...[
          const SizedBox(height: 18),
          DetailTagChips(tags: detail.tags),
        ],
        const SizedBox(height: 18),
        // The id the page itself loads the work with, so it can be pasted into
        // the `id:` search to reopen the same work.
        DetailIdRow(id: _contentId),
        const SizedBox(height: 6),
        DetailDirectoryRow(trailing: trailing, onTap: _openDirectory),
        _directoryPreview(palette),
        if (_comments.comments.isNotEmpty || _comments.totalCount > 0) ...[
          const SizedBox(height: 22),
          Divider(height: 1, color: palette.line),
          const SizedBox(height: 22),
          DetailReviews(
            page: _comments,
            detail: detail,
            bookId: _contentId,
            replyLoader: _replyLoader(_contentId),
          ),
        ],
      ],
    );
  }

  Widget _loadingView(HomePalette palette) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Column(
      children: [
        const SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: HomePalette.accent,
          ),
        ),
        const SizedBox(height: 16),
        Text('正在加载书籍与目录', style: TextStyle(color: palette.muted, fontSize: 13)),
      ],
    ),
  );

  Widget _stateCard({
    required IconData icon,
    required String title,
    required String message,
    bool retry = false,
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
          if (retry) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _load,
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.accentText,
                side: BorderSide(color: palette.line),
                minimumSize: const Size(110, 48),
              ),
              icon: const Icon(LucideIcons.refresh_cw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }

  /// A short catalog preview keeps the resume shortcut one tap away; the full
  /// catalog still opens from the `查看目录` row above it.
  Widget _directoryPreview(HomePalette palette) {
    if (_allChapters.isEmpty) {
      return _stateCard(
        icon: LucideIcons.list,
        title: '暂无目录',
        message: '暂未获取到章节，可以稍后刷新重试。',
        retry: true,
      );
    }
    final preview = _allChapters
        .take(_previewChapterCount)
        .toList(growable: false);
    return Container(
      key: const Key('detail_preview_chapters'),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.line.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var index = 0; index < preview.length; index++) ...[
            DetailChapterRow(
              key: ValueKey('detail_preview_chapter_${preview[index].itemId}'),
              chapter: preview[index],
              index: index,
              current: index == _resumeIndex,
              divider:
                  index < preview.length - 1 ||
                  _chapterPreviews.forItem(preview[index].itemId) != null,
              onTap: () => _openChapter(preview[index]),
            ),
            if (_chapterPreviews.forItem(preview[index].itemId)
                case final String excerpt)
              _ChapterExcerpt(
                key: ValueKey(
                  'detail_preview_excerpt_${preview[index].itemId}',
                ),
                text: excerpt,
                divider: index < preview.length - 1,
              ),
          ],
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

  /// Caches the following chapters for offline reading using the same sheet
  /// the reader exposes.
  Future<void> _showDownload() async {
    if (_allChapters.isEmpty) return;
    final cache = ChapterCacheStore.instance;
    final book = CachedBook(
      id: _contentId,
      title: widget.item.title,
      cover: widget.item.cover,
      chapters: _allChapters,
    );
    try {
      await cache.saveBook(book);
    } on Exception {
      // A cache index failure must not block opening the download sheet.
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => ChapterCacheSheet(
        book: book,
        currentIndex: _resumeIndex ?? 0,
        cache: cache,
        loader: (chapter) => ApiClient.instance.contentText(chapter.itemId),
      ),
    );
    if (mounted) unawaited(_refreshResume());
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
    setState(() => _resumeIndex = _savedIndex(saved));
  }

  Future<void> _openLastPosition() async {
    if (_opening || _allChapters.isEmpty) return;
    final generation = ++_openGeneration;
    setState(() => _opening = true);
    try {
      final saved = await _readSavedRecord();
      if (!mounted || generation != _openGeneration || _allChapters.isEmpty) {
        return;
      }
      final index = _savedIndex(saved) ?? 0;
      _openChapter(_allChapters[index]);
    } finally {
      if (mounted && generation == _openGeneration) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _openChapter(Chapter chapter) async {
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
        description: _detail == null ? null : extractMediaDescription(_detail),
        startIndex: startIndex,
      ),
      'audio' => AudioPage(
        bookId: _contentId,
        title: widget.item.title,
        cover: widget.item.cover,
        historyStore: widget.readerStore,
        chapters: _allChapters,
        startIndex: startIndex,
      ),
      'manga' => ComicReaderPage(
        bookId: _contentId,
        title: widget.item.title,
        cover: widget.item.cover,
        readerStore: widget.readerStore,
        chapters: _allChapters,
        startIndex: startIndex,
      ),
      _ => ReaderPage(
        bookId: _contentId,
        title: widget.item.title,
        cover: widget.item.cover,
        readerStore: widget.readerStore,
        chapters: _allChapters,
        startIndex: startIndex,
      ),
    };
    await _push(page);
  }

  Future<void> _push(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
    if (mounted) unawaited(_refreshResume());
  }
}

/// Opening lines of a chapter, shown under its row in the preview block.
///
/// The upstream field is named `summary`, but what it returns is the chapter's
/// own opening text, so it is presented as a preview rather than a synopsis and
/// clipped to a few lines.
class _ChapterExcerpt extends StatelessWidget {
  final String text;
  final bool divider;

  const _ChapterExcerpt({super.key, required this.text, required this.divider});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.7),
          ),
          if (divider) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: palette.line.withValues(alpha: 0.5)),
          ],
        ],
      ),
    );
  }
}
