// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/reading_statistics_page.dart (ArchiveFeaturePage shell, ArchiveSection
//     section rhythm, featurePadding, _muted, _section spacing)
// Mechanical substitutions:
// - `ReadingStatisticsData` (range picker, bookmarks, collection, touch
//   modules) is not ported. fqapp records per-day minutes and a book-level
//   read-time ranking only; the page renders those upstream sections that the
//   local store can actually fill: 阅读总览, 阅读节律, 阅读日历, 读得最多.
//   No upstream-only statistic is invented.
// - The category `GlassDock` is not mounted: fqapp opens statistics as a
//   standalone route above the app shell, and every remaining section fits a
//   single scroll. Upstream's module configuration sheet has no fqapp
//   counterpart and is therefore absent rather than faked.
// - `appText`/`NovelMotion` substitutions match the rest of the shared layer;
//   charts come from `lib/widgets/wenku/misc_reading_charts.dart`.
// - The existing store reload / visibility gating (TickerMode, debounce,
//   history + read-time listeners) is unchanged.
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/reading_stats.dart';
import '../services/book_open_preferences.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../widgets/mine/mine_heatmap.dart';
import '../widgets/mine/mine_summary.dart';
import '../widgets/mine/mine_top_books.dart';
import '../widgets/wenku/misc_reading_charts.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'detail_page.dart';

/// 统计：沿用 Wenku8 Flutter 的档案页骨架与图表语汇，数据来自 fqapp 本机
/// 阅读历史与阅读时长。
class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({super.key});

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  static const _rhythmDays = 30;

  ReadingStats _stats = ReadingStats.empty;
  bool _loading = true;
  late final Listenable _historyChanges;
  late final Listenable _readTimeChanges;
  Timer? _reloadTimer;
  bool _visible = false;
  bool _storeDirty = true;
  int _rhythmSelected = _rhythmDays - 1;

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
    final today = DateUtils.dateOnly(DateTime.now());
    return ArchiveFeaturePage(
      title: '统计',
      code: 'PERSONAL / READING RECORDS',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const ValueKey('reading-statistics-list'),
              padding: featurePadding(context),
              children: [
                MineSummary(stats: _stats, today: today),
                const SizedBox(height: 34),
                _rhythm(context, today),
                const SizedBox(height: 34),
                MineHeatmap(stats: _stats, today: today),
                const SizedBox(height: 34),
                MineTopBooks(rank: _stats.rank, onOpen: _openEntry),
              ],
            ),
    );
  }

  Widget _rhythm(BuildContext context, DateTime today) {
    final scheme = Theme.of(context).colorScheme;
    final dates = [
      for (var back = _rhythmDays - 1; back >= 0; back--)
        DateTime(today.year, today.month, today.day - back),
    ];
    // fqapp has no "unobserved day" signal: a day without recorded minutes is
    // a real zero, so the curve stays continuous instead of inventing gaps.
    final minutes = [for (final day in dates) _stats.minutesOn(day)];
    final averages = <double?>[
      for (var i = 0; i < minutes.length; i++)
        i < 6 ? null : _averageOf(minutes.sublist(i - 6, i + 1)),
    ];
    final selected = _rhythmSelected.clamp(0, dates.length - 1);
    final selectedMinutes = minutes[selected];
    final muted = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '阅读节律', code: 'READING / RHYTHM'),
        const SizedBox(height: 22),
        MiscReadingRhythmChart(
          dates: dates,
          minutes: minutes,
          averageMinutes: averages,
          selectedIndex: selected,
          onSelected: (index) => setState(() => _rhythmSelected = index),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: AppText(
                '${dates[selected].year}年${dates[selected].month}月'
                '${dates[selected].day}日',
                style: muted,
              ),
            ),
            if (selectedMinutes > 0)
              Flexible(
                child: AppText(
                  formatReadingDuration(selectedMinutes),
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  static double _averageOf(List<double> values) =>
      values.fold<double>(0, (sum, value) => sum + value) / values.length;
}
