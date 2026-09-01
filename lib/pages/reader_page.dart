import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';

class ReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final List<Chapter> chapters;
  final int startIndex;

  const ReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    required this.startIndex,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late int _index;
  String _content = '';
  bool _loading = true;
  String? _error;
  double _fontSize = 18;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex < 0 ? 0 : widget.startIndex;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _content = '';
    });
    final ch = widget.chapters[_index];
    try {
      final d = await ApiClient.instance.content(ch.itemId, tab: '小说');
      final data = d['data'];
      var text = '';
      if (data is Map) {
        text = '${data['content'] ?? ''}';
        // strip HTML tags if any
        text = text.replaceAll(RegExp(r'<[^>]+>'), '');
        text = text.replaceAll('&nbsp;', ' ').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
      }
      if (text.isEmpty) throw ApiException('正文为空');
      setState(() {
        _content = text;
        _loading = false;
      });
      // record history
      await LibraryStore.instance.addHistory({
        'id': widget.bookId,
        'kind': 'book',
        'title': widget.title,
        'bookId': widget.bookId,
        'episode': _index,
        'progress': _index / widget.chapters.length,
        'cover': '',
        'time': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() => _index--);
    _load();
  }

  void _next() {
    if (_index >= widget.chapters.length - 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已是最后一章')));
      return;
    }
    setState(() => _index++);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.chapters[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(ch.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<double>(
            icon: const Icon(Icons.format_size),
            onSelected: (v) => setState(() => _fontSize = v),
            itemBuilder: (_) => [16.0, 18.0, 20.0, 22.0, 24.0]
                .map((v) => PopupMenuItem(value: v, child: Text('字号 $v')))
                .toList(),
          ),
        ],
      ),
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
              : GestureDetector(
                  onTapUp: (d) {
                    final w = MediaQuery.of(context).size.width;
                    if (d.localPosition.dx < w / 3) {
                      _prev();
                    } else if (d.localPosition.dx > w * 2 / 3) {
                      _next();
                    }
                  },
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ch.title,
                            style: TextStyle(
                                fontSize: _fontSize + 2,
                                fontWeight: FontWeight.bold,
                                height: 1.6)),
                        const SizedBox(height: 12),
                        Text(
                          _content,
                          style: TextStyle(fontSize: _fontSize, height: 1.8),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.chevron_left, size: 18),
                              label: const Text('上一章'),
                              onPressed: _prev,
                            ),
                            const SizedBox(width: 16),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.chevron_right, size: 18),
                              label: const Text('下一章'),
                              onPressed: _next,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}
