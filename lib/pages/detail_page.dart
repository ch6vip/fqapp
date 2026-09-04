import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../widgets/media_card.dart';
import 'player_page.dart';
import 'reader_page.dart';

class DetailPage extends StatefulWidget {
  final MediaItem item;

  const DetailPage({super.key, required this.item});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic>? _detail;
  List<List<Chapter>> _volumes = [];
  bool _loading = true;
  String? _error;
  bool _isFav = false;
  late final String _tab;

  bool get _supported =>
      widget.item.kind == 'book' || widget.item.kind == 'video';
  bool get _isVideo => widget.item.kind == 'video';
  String get _contentId => widget.item.seriesId ?? widget.item.id;
  List<Chapter> get _allChapters => _volumes.expand((v) => v).toList();

  @override
  void initState() {
    super.initState();
    _tab = kindLabels[widget.item.kind] ?? '小说';
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      _isFav = await LibraryStore.instance.isFavorite(_contentId);
    } catch (_) {
      _isFav = false;
    }

    // Manga/audio readers are intentionally not advertised in V0.1. Do not
    // call incompatible detail endpoints and then show a misleading novel
    // reader when the user taps them.
    if (!_supported) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    Map<String, dynamic>? detail;
    List<List<Chapter>> volumes = [];
    Object? detailError;
    Object? directoryError;

    // Detail and directory are independent. Short-drama IDs sometimes do
    // not have a legacy book-detail record, but their episode list is still
    // perfectly playable.
    try {
      detail = await ApiClient.instance.detail(_contentId, tab: _tab);
    } catch (e) {
      detailError = e;
    }
    try {
      final directory = await ApiClient.instance.directory(
        _contentId,
        tab: _tab,
      );
      volumes = await parseDirectoryAsync(directory);
    } catch (e) {
      directoryError = e;
    }

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

    if (!mounted) return;
    if (detail == null && volumes.isEmpty && directoryError != null) {
      setState(() {
        _error = '$directoryError';
        _loading = false;
      });
      return;
    }
    setState(() {
      _detail = detail;
      _volumes = volumes;
      // A missing optional detail response should not hide a usable list.
      _error = detail == null && detailError != null && volumes.isEmpty
          ? '$detailError'
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
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red),
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
          Icon(
            widget.item.kind == 'manga' ? Icons.menu_book : Icons.headphones,
            size: 56,
            color: Colors.grey,
          ),
          const SizedBox(height: 12),
          Text('${kindLabels[widget.item.kind] ?? '该类型'}阅读器正在开发中'),
          const SizedBox(height: 8),
          const Text('当前版本先提供小说阅读和短剧播放。', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              await LibraryStore.instance.toggleFavorite(widget.item);
              if (mounted) setState(() => _isFav = !_isFav);
            },
            icon: Icon(_isFav ? Icons.favorite : Icons.favorite_border),
            label: Text(_isFav ? '已收藏' : '收藏'),
          ),
        ],
      ),
    ),
  );

  Widget _buildContent() {
    final desc = _description(_detail);
    final countLabel = _isVideo ? '集' : '章';

    return ListView(
      padding: const EdgeInsets.all(16),
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
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  if (widget.item.badge.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.item.badge,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '共 ${_allChapters.length} $countLabel',
                    style: const TextStyle(
                      color: Color(0xFFE8532D),
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
              color: Colors.grey.shade800,
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
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_volumes.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('暂无目录')),
          )
        else
          for (final volume in _volumes) _volumeGrid(volume),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _cover() {
    final fallback = Container(
      width: 100,
      height: 140,
      color: Colors.grey.shade200,
      child: Icon(
        _isVideo ? Icons.movie_outlined : Icons.book,
        color: Colors.grey,
      ),
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
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }

  Widget _volumeGrid(List<Chapter> volume) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (volume.isNotEmpty && volume.first.volumeName.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            volume.first.volumeName,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 2.2,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
        ),
        itemCount: volume.length,
        itemBuilder: (context, i) => InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _openChapter(volume[i]),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              volume[i].title.length > 8
                  ? '${volume[i].title.substring(0, 8)}…'
                  : volume[i].title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildBottomBar() => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _isFav ? Icons.favorite : Icons.favorite_border,
              color: _isFav ? Colors.red : null,
            ),
            onPressed: () async {
              await LibraryStore.instance.toggleFavorite(widget.item);
              if (mounted) setState(() => _isFav = !_isFav);
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              icon: Icon(_isVideo ? Icons.play_arrow : Icons.menu_book),
              label: Text(_isVideo ? '播放 / 续看' : '阅读 / 续读'),
              onPressed: _openLastPosition,
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _openLastPosition() async {
    final saved = await LibraryStore.instance.historyEntry(_contentId);
    if (!mounted) return;
    final savedIndex = saved?['episode'] is num
        ? (saved!['episode'] as num).toInt()
        : 0;
    final index = savedIndex.clamp(0, _allChapters.length - 1);
    _openChapter(_allChapters[index]);
  }

  void _openChapter(Chapter chapter) {
    final index = _allChapters.indexWhere((c) => c.itemId == chapter.itemId);
    if (_isVideo) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            bookId: _contentId,
            title: widget.item.title,
            cover: widget.item.cover,
            eps: _allChapters,
            startIndex: index < 0 ? 0 : index,
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            bookId: _contentId,
            title: widget.item.title,
            cover: widget.item.cover,
            chapters: _allChapters,
            startIndex: index < 0 ? 0 : index,
          ),
        ),
      );
    }
  }
}

String _description(Map<String, dynamic>? payload) {
  if (payload == null) return '';
  dynamic data = payload['data'];
  if (data is Map && data['data'] is Map) data = data['data'];
  if (data is! Map) return '';
  for (final key in [
    'abstract',
    'description',
    'desc',
    'book_desc',
    'introduction',
  ]) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}
