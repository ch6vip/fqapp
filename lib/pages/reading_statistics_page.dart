import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/reading_stats.dart';
import '../services/book_open_preferences.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/mine/mine_heatmap.dart';
import '../widgets/mine/mine_summary.dart';
import '../widgets/mine/mine_top_books.dart';
import 'detail_page.dart';

/// Local statistics route retained while the upstream statistics interface is
/// ported separately. The widgets below are the existing fqapp presentation.
class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({super.key});

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  ReadingStats _stats = ReadingStats.empty;
  bool _loading = true;
  late final Listenable _historyChanges;
  late final Listenable _readTimeChanges;
  Timer? _reloadTimer;
  bool _visible = false;
  bool _storeDirty = true;

  @override
  void initState() {
    super.initState();
    _historyChanges = LibraryStore.instance.historyListenable
      ..addListener(_scheduleStoreReload);
    _readTimeChanges = LibraryStore.instance.readTimeListenable
      ..addListener(_scheduleStoreReload);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasVisible = _visible;
    _visible = TickerMode.valuesOf(context).enabled;
    if (!_visible) {
      _reloadTimer?.cancel();
      _reloadTimer = null;
    } else if (!wasVisible || _storeDirty) {
      _reloadFromStore();
    }
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    _historyChanges.removeListener(_scheduleStoreReload);
    _readTimeChanges.removeListener(_scheduleStoreReload);
    super.dispose();
  }

  void _scheduleStoreReload() {
    _storeDirty = true;
    _reloadTimer?.cancel();
    _reloadTimer = null;
    if (!_visible) return;
    _reloadTimer = Timer(const Duration(milliseconds: 250), _reloadFromStore);
  }

  void _reloadFromStore() {
    if (!mounted || !_visible) return;
    _reloadTimer?.cancel();
    _reloadTimer = null;
    _storeDirty = false;
    final store = LibraryStore.instance;
    final stats = ReadingStats.from(
      history: store.historySnapshot(),
      readTime: store.readTimeSnapshot(),
      readTimeKinds: store.readTimeKindSnapshot(),
    );
    setState(() {
      _stats = stats;
      _loading = false;
    });
  }

  void _openEntry(Map<String, dynamic> entry) {
    openBookDetail(
      context,
      MediaItem(
        id: historyContentId(entry),
        title: '${entry['title'] ?? ''}',
        cover: '${entry['cover'] ?? ''}',
        author: '${entry['author'] ?? ''}',
        badge: '',
        ep: '',
        kind: '${entry['kind'] ?? 'book'}',
        seriesId: entry['seriesId']?.toString(),
        episodeId: entry['episodeId']?.toString(),
      ),
      entry: BookOpenEntry.shelf,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('统计'),
        centerTitle: false,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const ValueKey('reading-statistics-list'),
              padding: EdgeInsets.only(bottom: homeBottomClearance(context)),
              children: [
                MineSummary(stats: _stats, today: today),
                MineHeatmap(stats: _stats, today: today),
                MineTopBooks(rank: _stats.rank, onOpen: _openEntry),
              ],
            ),
    );
  }
}
