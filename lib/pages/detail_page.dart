import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/media_item.dart';
import '../models/media_description.dart';
import '../services/api_client.dart';
import '../services/app_theme.dart';
import '../services/audio_history.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/player_history.dart';
import '../services/reader_history.dart';
import '../widgets/media_card.dart';
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
  List<List<Chapter>> _volumes = [];
  List<Chapter> _allChapters = [];
  bool _loading = true;
  String? _error;
  late final String _tab;
  int _loadGeneration = 0;
  int _openGeneration = 0;
  bool _opening = false;

  bool get _supported => kindLabels.containsKey(widget.item.kind);
  bool get _isVideo => widget.item.kind == 'video';
  bool get _isAudio => widget.item.kind == 'audio';
  bool get _isManga => widget.item.kind == 'manga';
  String get _contentId => widget.item.seriesId ?? widget.item.id;
  IconData get _mediaIcon => switch (widget.item.kind) {
    'video' => Icons.movie_outlined,
    'audio' => Icons.headphones,
    'manga' => Icons.auto_stories_outlined,
    _ => Icons.book,
  };

  @override
  void initState() {
    super.initState();
    _tab = kindLabels[widget.item.kind] ?? '小说';
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _detail = null;
        _volumes = const [];
        _allChapters = const [];
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
      _volumes = volumes;
      _allChapters = volumes.expand((volume) => volume).toList(growable: false);
      // A missing optional detail response should not hide a usable list.
      _error = detail == null && detailResult.error != null && volumes.isEmpty
          ? '${detailResult.error}'
          : null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorView()
          : !_supported
          ? _unsupportedView()
          : _buildContent(),
      bottomNavigationBar: _supported && _allChapters.isNotEmpty
          ? _buildBottomBar()
          : null,
    );
  }

  Widget _errorView() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    ),
  );

  Widget _unsupportedView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.article_outlined, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('暂不支持此内容类型'),
        ],
      ),
    ),
  );

  Widget _buildContent() {
    final desc = extractMediaDescription(_detail);
    final countLabel = _isVideo
        ? '集'
        : _isManga
        ? '话'
        : '章';
    final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 4,
      childAspectRatio: 2.2,
      crossAxisSpacing: 6,
      mainAxisSpacing: 6,
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _cover(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.item.title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (widget.item.author.isNotEmpty)
                            Text(
                              widget.item.author,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (widget.item.badge.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.item.badge,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            '共 ${_allChapters.length} $countLabel',
                            style: const TextStyle(
                              color: appSeedColor,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    desc,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                      fontSize: 14,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      '目录',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '共 ${_allChapters.length} $countLabel',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        if (_volumes.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('暂无目录')),
            ),
          )
        else
          for (final volume in _volumes) ...[
            if (volume.isNotEmpty && volume.first.volumeName.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    volume.first.volumeName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _chapterCell(volume[i]),
                  childCount: volume.length,
                ),
              ),
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _cover() {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: 100,
      height: 140,
      color: scheme.surfaceContainerHighest,
      child: Icon(_mediaIcon, color: scheme.onSurfaceVariant),
    );
    if (widget.item.cover.isEmpty) {
      return ClipRRect(borderRadius: BorderRadius.circular(8), child: fallback);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: widget.item.cover,
        width: 100,
        height: 140,
        fit: BoxFit.cover,
        memCacheWidth: 300,
        memCacheHeight: 420,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }

  Widget _chapterCell(Chapter chapter) => InkWell(
    borderRadius: BorderRadius.circular(4),
    onTap: () => _openChapter(chapter),
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        chapter.title.length > 8
            ? '${chapter.title.substring(0, 8)}…'
            : chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );

  Widget _buildBottomBar() => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          icon: Icon(
            _isAudio
                ? Icons.headphones
                : _isVideo
                ? Icons.play_arrow
                : Icons.menu_book,
          ),
          label: Text(
            _isAudio
                ? '播放 / 续听'
                : _isVideo
                ? '播放 / 续看'
                : '阅读 / 续读',
          ),
          onPressed: _opening ? null : _openLastPosition,
        ),
      ),
    ),
  );

  Future<void> _openLastPosition() async {
    if (_opening || _allChapters.isEmpty) return;
    final generation = ++_openGeneration;
    setState(() => _opening = true);
    try {
      final store = widget.readerStore ?? LibraryStore.instance;
      Map<String, dynamic>? saved;
      try {
        saved = switch (widget.item.kind) {
          'video' => await PlayerHistory(store).load(_contentId),
          'audio' => await AudioHistory(store).load(_contentId),
          'manga' => await ReaderHistory(
            scopedHistoryStore(store, 'manga'),
          ).load(_contentId),
          _ => await ReaderHistory(store).load(_contentId),
        };
        if (saved?['kind'] != null && saved?['kind'] != widget.item.kind) {
          saved = null;
        }
      } catch (_) {
        // A missing resume record must not prevent reading available content.
      }
      if (!mounted || generation != _openGeneration || _allChapters.isEmpty) {
        return;
      }
      // Follow the same chapter when the publisher inserts or reorders it.
      final resumeRecord = !_isVideo && saved != null
          ? {
              ...saved,
              if (saved['chapterId'] != null)
                'chapterId': saved['chapterId'].toString(),
            }
          : saved;
      final index =
          (_isAudio
              ? resumeAudioChapterIndex(resumeRecord, _allChapters)
              : resumeEpisodeIndex(resumeRecord, _allChapters)) ??
          0;
      _openChapter(_allChapters[index]);
    } finally {
      if (mounted && generation == _openGeneration) {
        setState(() => _opening = false);
      }
    }
  }

  void _openChapter(Chapter chapter) {
    // An explicit chapter selection supersedes any pending resume lookup.
    ++_openGeneration;
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
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }
}
