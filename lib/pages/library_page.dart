import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../services/library_store.dart';
import '../widgets/bookshelf_card.dart';
import 'detail_page.dart';
import 'cached_books_page.dart';

const _bookshelfLayoutPreference = 'bookshelf_layout';

enum _LibraryAction { layout, clear }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<Map<String, dynamic>> _hist = [];
  // Legado layout values: 0 standard list, 1 compact list, 2..6 grid columns.
  int _layout = 3;
  late final Listenable _historyChanges;

  @override
  void initState() {
    super.initState();
    _historyChanges = LibraryStore.instance.historyListenable
      ..addListener(_load);
    _load();
    _loadLayoutPreference();
  }

  void _load() {
    if (!mounted) return;
    final store = LibraryStore.instance;
    setState(() {
      _hist = store.historySnapshot();
    });
  }

  Future<void> _loadLayoutPreference() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getInt(_bookshelfLayoutPreference);
    if (!mounted || saved == null || saved < 0 || saved > 6) return;
    setState(() => _layout = saved);
  }

  @override
  void dispose() {
    _historyChanges.removeListener(_load);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visibleEntries();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        titleSpacing: 16,
        centerTitle: false,
        title: const Text(
          '书架',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: '离线缓存',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedBooksPage()),
            ),
            icon: const Icon(Icons.download_for_offline_outlined),
          ),
          IconButton(
            key: const Key('bookshelf-layout-button'),
            tooltip: '书架布局：${_layoutName(_layout)}',
            onPressed: _showLayoutPicker,
            icon: Icon(_layoutIcon(_layout)),
          ),
          PopupMenuButton<_LibraryAction>(
            tooltip: '更多',
            onSelected: _handleAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _LibraryAction.layout,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.view_quilt_outlined),
                  title: Text('书架布局'),
                ),
              ),
              PopupMenuItem(
                value: _LibraryAction.clear,
                enabled: entries.isNotEmpty,
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline),
                  title: Text('清空历史'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: entries.isEmpty ? const _EmptyShelf() : _buildShelf(entries),
    );
  }

  Widget _buildShelf(List<_ShelfEntry> entries) {
    if (_layout >= 2) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final ratio = bookshelfGridChildAspectRatio(
            context,
            availableWidth: constraints.maxWidth,
            columns: _layout,
          );
          return GridView.builder(
            key: PageStorageKey('bookshelf-grid-$_layout'),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _layout,
              childAspectRatio: ratio,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return BookshelfGridCard(
                key: ValueKey('shelf-grid-${entry.item.kind}-${entry.item.id}'),
                item: entry.item,
                badgeText: entry.badgeText,
                onTap: () => _open(entry.item),
              );
            },
          );
        },
      );
    }

    return ListView.builder(
      key: PageStorageKey('bookshelf-list-$_layout'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: BookshelfListCard(
            key: ValueKey('shelf-list-${entry.item.kind}-${entry.item.id}'),
            item: entry.item,
            compact: _layout == 1,
            readingText: entry.readingText,
            lastUpdateText: entry.lastUpdateText,
            badgeText: entry.badgeText,
            onTap: () => _open(entry.item),
          ),
        );
      },
    );
  }

  List<_ShelfEntry> _visibleEntries() {
    return [
      for (final history in _hist)
        _ShelfEntry.from(_historyItem(history), history),
    ];
  }

  MediaItem _historyItem(Map<String, dynamic> history) {
    return MediaItem(
      id: history['id']?.toString() ?? '',
      title: history['title']?.toString() ?? '未知作品',
      cover: history['cover']?.toString() ?? '',
      author: history['author']?.toString() ?? '',
      badge: '',
      ep: history['ep']?.toString() ?? '',
      kind: history['kind']?.toString() ?? 'book',
      seriesId: history['seriesId']?.toString(),
      episodeId: history['episodeId']?.toString(),
    );
  }

  void _open(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }

  void _handleAction(_LibraryAction action) {
    switch (action) {
      case _LibraryAction.layout:
        _showLayoutPicker();
      case _LibraryAction.clear:
        _confirmClear();
    }
  }

  Future<void> _showLayoutPicker() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('书架布局', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                '选择列表密度或每行显示的封面数量',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var value = 0; value <= 6; value++)
                    ChoiceChip(
                      avatar: Icon(_layoutIcon(value), size: 18),
                      label: Text(_layoutName(value)),
                      selected: value == _layout,
                      onSelected: (_) => Navigator.pop(context, value),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected == _layout || !mounted) return;
    setState(() => _layout = selected);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_bookshelfLayoutPreference, selected);
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定清空全部阅读历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LibraryStore.instance.clearHistory();
  }
}

class _ShelfEntry {
  final MediaItem item;
  final String? readingText;
  final String? lastUpdateText;
  final String badgeText;

  const _ShelfEntry({
    required this.item,
    required this.readingText,
    required this.lastUpdateText,
    required this.badgeText,
  });

  factory _ShelfEntry.from(MediaItem item, Map<String, dynamic>? history) {
    final progress = _progressOf(history);
    return _ShelfEntry(
      item: item,
      readingText: _readingText(item.kind, history, progress),
      lastUpdateText: _relativeTime(history?['time']),
      badgeText: progress == null
          ? bookshelfKindLabel(item.kind)
          : '${(progress * 100).round()}%',
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_outlined,
            size: 56,
            color: color.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 14),
          Text('暂无阅读历史', style: TextStyle(fontSize: 16, color: color)),
        ],
      ),
    );
  }
}

double? _progressOf(Map<String, dynamic>? history) {
  final value = history?['progress'];
  if (value is! num || value <= 0) return null;
  return value.toDouble().clamp(0, 1);
}

String? _readingText(
  String kind,
  Map<String, dynamic>? history,
  double? progress,
) {
  if (history == null) return null;
  final parts = <String>[];
  final episode = history['episode'];
  if (episode is num && episode >= 0) {
    final suffix = switch (kind) {
      'video' || 'audio' => '集',
      'manga' => '话',
      _ => '章',
    };
    parts.add('第${episode.toInt() + 1}$suffix');
  }
  if (progress != null) parts.add('${(progress * 100).round()}%');
  return parts.isEmpty ? null : parts.join(' · ');
}

String? _relativeTime(dynamic rawTime) {
  if (rawTime is! num || rawTime <= 0) return null;
  final time = DateTime.fromMillisecondsSinceEpoch(rawTime.toInt());
  final difference = DateTime.now().difference(time);
  if (difference.isNegative || difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes}分钟前';
  if (difference.inDays < 1) return '${difference.inHours}小时前';
  if (difference.inDays < 7) return '${difference.inDays}天前';
  return '${time.month}月${time.day}日';
}

String _layoutName(int value) => switch (value) {
  0 => '标准列表',
  1 => '紧凑列表',
  _ => '$value列网格',
};

IconData _layoutIcon(int value) => switch (value) {
  0 => Icons.view_agenda_outlined,
  1 => Icons.view_list,
  _ => Icons.grid_view_outlined,
};
