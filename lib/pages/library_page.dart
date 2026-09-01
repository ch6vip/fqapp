import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/library_store.dart';
import '../widgets/media_card.dart';
import 'detail_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<MediaItem> _favs = [];
  List<Map<String, dynamic>> _hist = [];
  bool _tabFavs = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final favs = await LibraryStore.instance.favorites();
    final hist = await LibraryStore.instance.history();
    if (mounted) {
      setState(() {
        _favs = favs;
        _hist = hist;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('清空记录'),
                  content: Text(_tabFavs ? '清空全部收藏？' : '清空全部历史？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                    TextButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('清空', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                if (_tabFavs) {
                  await LibraryStore.instance.clearFavorites();
                } else {
                  await LibraryStore.instance.clearHistory();
                }
                _load();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('收藏')),
              ButtonSegment(value: false, label: Text('历史')),
            ],
            selected: {_tabFavs},
            onSelectionChanged: (s) => setState(() => _tabFavs = s.first),
          ),
          Expanded(
            child: _tabFavs
                ? _favs.isEmpty
                    ? const Center(child: Text('还没有收藏'))
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 0.52,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: _favs.length,
                        itemBuilder: (context, i) => MediaCard(
                          item: _favs[i],
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => DetailPage(item: _favs[i])),
                          ),
                        ),
                      )
                : _hist.isEmpty
                    ? const Center(child: Text('暂无历史'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _hist.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final h = _hist[i];
                          return ListTile(
                            leading: h['cover'] != null && (h['cover'] as String).isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.network(
                                      h['cover'],
                                      width: 44,
                                      height: 58,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          const Icon(Icons.broken_image),
                                    ),
                                  )
                                : const Icon(Icons.book_outlined),
                            title: Text('${h['title'] ?? ''}',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                '${h['episode'] != null ? '第${(h['episode'] as num).toInt() + 1}集' : ''}${(h['progress'] ?? 0) > 0 ? ' · ${((h['progress'] as num) * 100).toStringAsFixed(0)}%' : ''}'),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DetailPage(
                                  item: MediaItem(
                                    id: '${h['id'] ?? ''}',
                                    title: '${h['title'] ?? ''}',
                                    cover: '${h['cover'] ?? ''}',
                                    author: '${h['author'] ?? ''}',
                                    badge: '',
                                    ep: '',
                                    kind: '${h['kind'] ?? 'book'}',
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
