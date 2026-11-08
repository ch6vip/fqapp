// Upstream source: Wenku8_Flutter rev ebcd7f1 `lib/reading_statistics_page.dart`
// (ArchiveFeaturePage shell, ArchiveSection rhythm, featurePadding).
//
// Two presentations, one set of stores. Archive keeps the upstream overview
// sections (`MineSummary`, `MineLibraryOverview`, `MineHeatmap`,
// `MineTopBooks`); classic reuses the pre-#291 「我的」 statistics vocabulary
// from fqapp-backup@f329399 (`ClassicMineSummary`, `ClassicMineHeatmap`,
// `ClassicMineTopBooks`), so the page reads like the old mine screen while the
// route, range and store listeners stay current.
//
// `ReadingStatisticsData` (range picker, bookmarks, collection, touch modules)
// is not ported wholesale: every section fqapp's stores can fill is rendered,
// 「当前文库」 reads `ShelfStore.records()` and `ReadingStats.rank`, and no
// upstream-only statistic is invented. The category `GlassDock` is not mounted
// because fqapp opens statistics as a standalone route.
//
// The store reload / visibility gating (TickerMode, debounce, history and
// read-time listeners) is unchanged.
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/reading_stats.dart';
import '../services/book_open_preferences.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/shelf_store.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/mine/classic_mine_heatmap.dart';
import '../widgets/mine/classic_mine_summary.dart';
import '../widgets/mine/classic_mine_top_books.dart';
import '../widgets/mine/mine_heatmap.dart';
import '../widgets/mine/mine_summary.dart';
import '../widgets/mine/mine_top_books.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/wenku/reading_charts.dart';
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
  int _shelfBooks = 0;
  bool _loading = true;
  late final Listenable _historyChanges;
  late final Listenable _readTimeChanges;
  late final Listenable _shelfChanges;
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
    _shelfChanges = ShelfStore.instance.listenable
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
    _shelfChanges.removeListener(_scheduleStoreReload);
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
      _shelfBooks = ShelfStore.instance.records().length;
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
    final classic = AppUiScope.isClassic(context);
    return SettingsArchivePage(
      title: '统计',
      code: 'PERSONAL / READING RECORDS',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : classic
          ? _classicBody(context, today)
          : ListView(
              key: const ValueKey('reading-statistics-list'),
              padding: featurePadding(context),
              children: [
                MineSummary(stats: _stats, today: today),
                const SizedBox(height: 30),
                MineLibraryOverview(
                  today: today,
                  shelfBooks: _shelfBooks,
                  readingBooks: _stats.rank.length,
                ),
                const SizedBox(height: 34),
                _rhythm(context, today, classic: false),
                const SizedBox(height: 34),
                MineHeatmap(stats: _stats, today: today),
                const SizedBox(height: 34),
                MineTopBooks(rank: _stats.rank, onOpen: _openEntry),
              ],
            ),
    );
  }

  /// Classic body: the 我的 statistics vocabulary from f329399.
  ///
  /// The classic mine widgets own their `homeGutter`, so the list itself only
  /// reserves the AppBar and bottom safe area. The two blocks that do not come
  /// from that vocabulary (当前文库 counts and 阅读节律) add the gutter here.
  Widget _classicBody(BuildContext context, DateTime today) {
    final palette = HomePalette.of(context);
    final gutter = MediaQuery.paddingOf(context);
    return ListView(
      key: const ValueKey('reading-statistics-list'),
      padding: EdgeInsets.only(
        top: gutter.top + kToolbarHeight + 8,
        bottom: gutter.bottom + 24,
      ),
      children: [
        ClassicMineSummary(stats: _stats, today: today),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前文库 · ${today.year}.${today.month}.${today.day}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: palette.muted,
                ),
              ),
              const SizedBox(height: 12),
              SettingsStats(
                values: {'藏书': _shelfBooks, '有阅读记录': _stats.rank.length},
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: _rhythm(context, today, classic: true),
        ),
        const SizedBox(height: 26),
        ClassicMineHeatmap(stats: _stats, today: today),
        ClassicMineTopBooks(rank: _stats.rank, onOpen: _openEntry),
      ],
    );
  }

  Widget _rhythm(
    BuildContext context,
    DateTime today, {
    required bool classic,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dates = [
      for (var back = _rhythmDays - 1; back >= 0; back--)
        DateTime(today.year, today.month, today.day - back),
    ];
    // The rhythm treats a day with no measured minutes as zero so the 7-day
    // average is defined at every point; the calendar is where fqapp encodes
    // "recorded zero" versus "no record" separately (a day-map key).
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
      color: classic ? HomePalette.of(context).muted : scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSection(title: '阅读节律', code: 'READING / RHYTHM'),
        const SizedBox(height: 22),
        ReadingRhythmChart(
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
