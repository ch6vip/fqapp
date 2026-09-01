import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../widgets/media_card.dart';
import 'reader_page.dart';
import 'player_page.dart';

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
  String _tab = '小说';

  @override
  void initState() {
    super.initState();
    _tab = kindLabels[widget.item.kind] ?? '小说';
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ApiClient.instance.detail(widget.item.id, tab: _tab),
        ApiClient.instance.directory(widget.item.id, tab: _tab),
        LibraryStore.instance.isFavorite(widget.item.id),
      ]);
      setState(() {
        _detail = (results[0] as Map).cast<String, dynamic>();
        _volumes = parseDirectory((results[1] as Map).cast<String, dynamic>());
        _isFav = results[2] as bool;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<Chapter> get _allChapters => _volumes.expand((v) => v).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.item.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _buildContent(),
      bottomNavigationBar: _allChapters.isEmpty ? null : _buildBottomBar(),
    );
  }

  Widget _buildContent() {
    final d = _detail;
    String desc = '';
    if (d != null) {
      final data = d['data'];
      if (data is Map) {
        desc = '${data['abstract'] ?? data['description'] ?? data['desc'] ?? ''}';
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: widget.item.cover.isNotEmpty
                  ? Image.network(
                      widget.item.cover,
                      width: 100,
                      height: 140,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 100,
                        height: 140,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.book, color: Colors.grey),
                      ),
                    )
                  : Container(
                      width: 100,
                      height: 140,
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.book, color: Colors.grey),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.item.title,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  if (widget.item.author.isNotEmpty)
                    Text(widget.item.author, style: TextStyle(color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  if (widget.item.badge.isNotEmpty)
                    Text(widget.item.badge, style: TextStyle(color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  Text('共 ${_allChapters.length} 章',
                      style: const TextStyle(color: Color(0xFFE8532D), fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(desc,
              style: TextStyle(color: Colors.grey.shade800, height: 1.5, fontSize: 14)),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Text('目录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
            const Spacer(),
            Text('共 ${_allChapters.length} 章', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        if (_volumes.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('目录加载失败')),
          )
        else
          for (final vol in _volumes)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (vol.isNotEmpty && vol.first.volumeName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(vol.first.volumeName,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
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
                  itemCount: vol.length,
                  itemBuilder: (context, i) => InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _openChapter(vol[i]),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        vol[i].title.length > 8 ? '${vol[i].title.substring(0, 8)}…' : vol[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildBottomBar() {
    final isVideo = widget.item.kind == 'video';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            IconButton(
              icon: Icon(_isFav ? Icons.favorite : Icons.favorite_border,
                  color: _isFav ? Colors.red : null),
              onPressed: () async {
                await LibraryStore.instance.toggleFavorite(widget.item);
                setState(() => _isFav = !_isFav);
              },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                icon: Icon(isVideo ? Icons.play_arrow : Icons.menu_book),
                label: Text(isVideo ? '开始播放' : '开始阅读'),
                onPressed: () {
                  if (isVideo) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlayerPage(
                          bookId: widget.item.id,
                          title: widget.item.title,
                          eps: _allChapters,
                          startIndex: 0,
                        ),
                      ),
                    );
                  } else {
                    _openChapter(_allChapters.first);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openChapter(Chapter ch) {
    final isVideo = widget.item.kind == 'video';
    if (isVideo) {
      final idx = _allChapters.indexWhere((c) => c.itemId == ch.itemId);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            bookId: widget.item.id,
            title: widget.item.title,
            eps: _allChapters,
            startIndex: idx < 0 ? 0 : idx,
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            bookId: widget.item.id,
            title: widget.item.title,
            chapters: _allChapters,
            startIndex: _allChapters.indexWhere((c) => c.itemId == ch.itemId),
          ),
        ),
      );
    }
  }
}
