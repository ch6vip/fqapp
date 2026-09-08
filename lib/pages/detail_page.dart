import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../models/media_description.dart';
import '../services/api_client.dart';
import '../services/audio_history.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/player_history.dart';
import '../services/reader_history.dart';
import '../widgets/media_card.dart';
import '../widgets/detail/detail_chapter_row.dart';
import '../widgets/detail/detail_description.dart';
import '../widgets/detail/detail_directory_sheet.dart';
import '../widgets/detail/detail_hero.dart';
import '../widgets/detail/detail_read_bar.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import 'audio_page.dart';
import 'comic_reader_page.dart';
import 'player_page.dart';
import 'reader_page.dart';

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
  final ReaderStore? readerStore;

  const DetailPage({
    super.key,
    required this.item,
    this.detailLoader,
    this.directoryLoader,
    this.readerStore,
  });

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic>? _detail;
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
  bool get _isVideo => widget.item.kind == 'video';
  bool get _isAudio => widget.item.kind == 'audio';
  bool get _isManga => widget.item.kind == 'manga';
  String get _contentId => widget.item.seriesId ?? widget.item.id;
  String get _chapterUnit => _isVideo
      ? '集'
      : _isManga
      ? '话'
      : '章';
  String get _readLabel => switch (widget.item.kind) {
    'video' => _resumeIndex == null ? '开始观看' : '继续观看',
    'audio' => _resumeIndex == null ? '开始收听' : '继续收听',
    _ => _resumeIndex == null ? '开始阅读' : '继续阅读',
  };

  @override
  void initState() {
    super.initState();
    _tab = kindLabels[widget.item.kind] ?? '小说';
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
      _allChapters = volumes.expand((volume) => volume).toList(growable: false);
      // A missing optional detail response should not hide a usable list.
      _error = detail == null && detailResult.error != null && volumes.isEmpty
          ? '${detailResult.error}'
          : null;
      _loading = false;
    });
    unawaited(_refreshResume());
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
                      chapterCount: _loading || _error != null
                          ? null
                          : _allChapters.length,
                      chapterUnit: _chapterUnit,
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
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                DetailDescription(
                                  text: extractMediaDescription(_detail),
                                ),
                                const SizedBox(height: 28),
                                _directoryPreview(palette),
                              ],
                            ),
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
                onDirectory: _openDirectory,
              )
            : null,
      ),
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

  Widget _directoryPreview(HomePalette palette) {
    if (_allChapters.isEmpty) {
      return _stateCard(
        icon: LucideIcons.list,
        title: '暂无目录',
        message: '暂未获取到章节，可以稍后刷新重试。',
        retry: true,
      );
    }
    final heading = Text(
      '目录',
      style: TextStyle(
        color: palette.ink,
        fontSize: 23,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
    );
    final action = TextButton(
      key: const Key('detail_all_chapters_button'),
      onPressed: _openDirectory,
      style: TextButton.styleFrom(
        foregroundColor: palette.muted,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '全部 ${_allChapters.length} $_chapterUnit',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 5),
          const Icon(LucideIcons.arrow_up_right, size: 16),
        ],
      ),
    );
    final preview = _allChapters.take(3).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (MediaQuery.textScalerOf(context).scale(14) > 23)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, action],
          )
        else
          Row(
            children: [
              Expanded(child: heading),
              action,
            ],
          ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.line.withValues(alpha: 0.7)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var index = 0; index < preview.length; index++)
                DetailChapterRow(
                  key: ValueKey(
                    'detail_preview_chapter_${preview[index].itemId}',
                  ),
                  chapter: preview[index],
                  index: index,
                  current: index == _resumeIndex,
                  divider: index < preview.length - 1,
                  onTap: () => _openChapter(preview[index]),
                ),
            ],
          ),
        ),
      ],
    );
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

  Future<Map<String, dynamic>?> _readSavedRecord() async {
    final store = widget.readerStore ?? LibraryStore.instance;
    try {
      final saved = switch (widget.item.kind) {
        'video' => await PlayerHistory(store).load(_contentId),
        'audio' => await AudioHistory(store).load(_contentId),
        'manga' => await ReaderHistory(
          scopedHistoryStore(store, 'manga'),
        ).load(_contentId),
        _ => await ReaderHistory(store).load(_contentId),
      };
      if (saved?['kind'] != null && saved?['kind'] != widget.item.kind) {
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
      'video' => PlayerPage(
        bookId: _contentId,
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
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
    if (mounted) unawaited(_refreshResume());
  }
}
