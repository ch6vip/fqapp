import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';

class ReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;

  const ReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.chapters,
    required this.startIndex,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late int _index;
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;
  String _content = '';
  bool _loading = true;
  String? _error;
  double _fontSize = 18;
  int _loadGeneration = 0;

  Chapter get _chapter => widget.chapters[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _scrollController.addListener(_onScroll);
    if (widget.chapters.isEmpty) {
      _loading = false;
      _error = '暂无可阅读章节';
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _persistProgress();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_loadGeneration;
    final chapter = _chapter;
    setState(() {
      _loading = true;
      _error = null;
      _content = '';
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    try {
      final response = await ApiClient.instance.content(
        chapter.itemId,
        tab: '小说',
      );
      final text = _extractContent(response);
      if (text.trim().isEmpty) throw ApiException('正文为空');
      if (!mounted || generation != _loadGeneration) return;
      final saved = await LibraryStore.instance.historyEntry(widget.bookId);
      if (!mounted || generation != _loadGeneration) return;
      final sameChapter = saved?['chapterId']?.toString() == chapter.itemId;
      final savedPosition = sameChapter && saved?['position'] is num
          ? (saved!['position'] as num).toDouble()
          : 0.0;
      setState(() {
        _content = text;
        _loading = false;
      });

      await LibraryStore.instance.addHistory({
        'id': widget.bookId,
        'kind': 'book',
        'title': widget.title,
        'bookId': widget.bookId,
        'chapterId': chapter.itemId,
        'episode': _index,
        'position': savedPosition,
        'maxScroll': sameChapter && saved?['maxScroll'] is num
            ? (saved!['maxScroll'] as num).toDouble()
            : 0.0,
        'progress': _chapterProgress(),
        'cover': widget.cover,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
      await _restorePosition(chapter.itemId);
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _restorePosition(String chapterId) async {
    final history = await LibraryStore.instance.history();
    Map<String, dynamic>? entry;
    for (final item in history) {
      if (item['id']?.toString() == widget.bookId) {
        entry = item;
        break;
      }
    }
    if (!mounted ||
        entry == null ||
        entry['chapterId']?.toString() != chapterId) {
      return;
    }
    final rawPosition = entry['position'];
    final position = rawPosition is num ? rawPosition.toDouble() : 0.0;
    if (position <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = position.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    });
  }

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _persistProgress);
  }

  Future<void> _persistProgress() async {
    if (widget.chapters.isEmpty) return;
    final index = _index;
    final chapterId = _chapter.itemId;
    final position = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final max = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    await LibraryStore.instance.updateProgress(
      widget.bookId,
      index,
      _chapterProgress(position: position, maxScroll: max, index: index),
      chapterId: chapterId,
      position: position,
      maxScroll: max,
    );
  }

  double _chapterProgress({double? position, double? maxScroll, int? index}) {
    if (widget.chapters.isEmpty) return 0;
    final fraction =
        (maxScroll ??
                (_scrollController.hasClients
                    ? _scrollController.position.maxScrollExtent
                    : 0)) >
            0
        ? (position ??
                  (_scrollController.hasClients
                      ? _scrollController.offset
                      : 0)) /
              (maxScroll ?? _scrollController.position.maxScrollExtent)
        : 0.0;
    return ((index ?? _index) + fraction.clamp(0.0, 1.0)) /
        widget.chapters.length;
  }

  void _prev() {
    if (_index <= 0) return;
    _persistProgress();
    setState(() => _index--);
    _load();
  }

  void _next() {
    if (_index >= widget.chapters.length - 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已是最后一章')));
      return;
    }
    _persistProgress();
    setState(() => _index++);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: _errorView(),
      );
    }
    final chapter = _chapter;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          chapter.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<double>(
            icon: const Icon(Icons.format_size),
            onSelected: (value) => setState(() => _fontSize = value),
            itemBuilder: (_) => [16.0, 18.0, 20.0, 22.0, 24.0]
                .map(
                  (value) =>
                      PopupMenuItem(value: value, child: Text('字号 $value')),
                )
                .toList(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorView()
          : GestureDetector(
              onTapUp: (details) {
                final width = MediaQuery.of(context).size.width;
                if (details.localPosition.dx < width / 3) {
                  _prev();
                } else if (details.localPosition.dx > width * 2 / 3) {
                  _next();
                }
              },
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter.title,
                      style: TextStyle(
                        fontSize: _fontSize + 2,
                        fontWeight: FontWeight.bold,
                        height: 1.6,
                      ),
                    ),
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

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ?? '加载失败',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    ),
  );
}

String _extractContent(Map<String, dynamic> payload) {
  dynamic value = payload['data'];
  if (value is Map && value['data'] is Map) value = value['data'];
  if (value is Map) {
    for (final key in ['content', 'text', 'article_content', 'body']) {
      final candidate = value[key];
      if (candidate is String && candidate.isNotEmpty) {
        return _cleanText(candidate);
      }
    }
    // Batch/content fallbacks may put the chapter under an item id key.
    for (final nested in value.values) {
      if (nested is Map) {
        final result = _extractContent({'data': nested});
        if (result.isNotEmpty) return result;
      }
    }
  }
  return '';
}

String _cleanText(String text) => text
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .trim();
