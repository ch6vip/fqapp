import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../models/reading_stats.dart';
import '../services/app_style_tokens.dart';
import '../services/book_open_preferences.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/mine/classic_mine_entries.dart';
import '../widgets/mine/classic_mine_heatmap.dart';
import '../widgets/mine/classic_mine_summary.dart';
import '../widgets/mine/classic_mine_top_books.dart';
import '../widgets/mine/mine_entries.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'detail_page.dart';
import 'reading_statistics_page.dart';
import 'settings_page.dart';

/// Both presentations keep one page state. Classic restores the statistics-first
/// page from issue #288 (f329399), while archive keeps its separate stats route.
class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  ReadingStats _stats = ReadingStats.empty;
  Listenable? _historyChanges;
  Listenable? _readTimeChanges;
  Timer? _reloadTimer;
  bool _visible = false;
  bool _storeDirty = true;

  void _bindStore() {
    final store = LibraryStore.instance;
    if (_historyChanges != null || !store.isInitialized) return;
    _historyChanges = store.historyListenable..addListener(_scheduleReload);
    _readTimeChanges = store.readTimeListenable..addListener(_scheduleReload);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindStore();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        AppStyleTokens.of(context).isClassic;
    final becameVisible = visible && !_visible;
    _visible = visible;
    if (!visible) {
      _reloadTimer?.cancel();
    } else if (becameVisible || _storeDirty) {
      _reload();
    }
  }

  void _scheduleReload() {
    _storeDirty = true;
    _reloadTimer?.cancel();
    if (_visible) {
      _reloadTimer = Timer(const Duration(milliseconds: 250), _reload);
    }
  }

  void _reload() {
    if (!mounted || !_visible) return;
    _reloadTimer?.cancel();
    final store = LibraryStore.instance;
    // 装配降级时 store 可能还没就绪：保留 dirty，等下一次依赖变化再算，
    // 否则经典「我的」会一直停在空统计。
    if (!store.isInitialized) return;
    _storeDirty = false;
    setState(
      () => _stats = ReadingStats.from(
        history: store.historySnapshot(),
        readTime: store.readTimeSnapshot(),
        readTimeKinds: store.readTimeKindSnapshot(),
      ),
    );
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    _historyChanges?.removeListener(_scheduleReload);
    _readTimeChanges?.removeListener(_scheduleReload);
    super.dispose();
  }

  // 刷新节奏（250ms 防抖 + TickerMode 可见性门）与 reading_statistics_page
  // 同构；两处抽取见后续 issue。
  void _openEntry(Map<String, dynamic> entry) => openBookDetail(
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

  @override
  Widget build(BuildContext context) {
    final style = AppStyleTokens.of(context);
    if (style.isClassic) {
      final palette = HomePalette.of(context);
      final today = DateUtils.dateOnly(DateTime.now());
      return Scaffold(
        backgroundColor: palette.canvas,
        appBar: AppBar(
          title: const Text('我的'),
          centerTitle: false,
          backgroundColor: palette.canvas,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          actions: [
            IconButton(
              key: const ValueKey('classic-mine-settings'),
              tooltip: '应用设置',
              icon: const Icon(LucideIcons.settings, size: 21),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: ListView(
          key: const PageStorageKey('my-page-classic'),
          padding: EdgeInsets.only(bottom: homeBottomClearance(context)),
          children: [
            ClassicMineSummary(stats: _stats, today: today),
            ClassicMineHeatmap(stats: _stats, today: today),
            ClassicMineTopBooks(rank: _stats.rank, onOpen: _openEntry),
            const ClassicMineEntries(),
          ],
        ),
      );
    }
    return WenkuPage(
      header: const Align(
        alignment: Alignment.centerLeft,
        child: ArchiveMasthead(title: '我的', code: '04 / PERSONAL ARCHIVE'),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: const PageStorageKey('my-page'),
            padding: featurePadding(
              context,
            ).copyWith(bottom: DockLayout.scrollPaddingOf(context)),
            children: [
              const _LocalIdentityPanel(),
              SizedBox(height: style.sectionGap),
              FeatureEntry(
                key: const ValueKey('mine-statistics'),
                title: '统计',
                subtitle: '阅读记录、藏书与阅读时长',
                icon: CupertinoIcons.chart_bar,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ReadingStatisticsPage(),
                  ),
                ),
              ),
              SizedBox(height: style.entryGap),
              const MineEntries(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalIdentityPanel extends StatelessWidget {
  const _LocalIdentityPanel();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ContentPanel(
      key: const ValueKey('mine-local-identity'),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/images/app_logo.webp',
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              cacheHeight: (56 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '什锦铺',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 7),
                Text(
                  '本地阅读档案 · 小说、短剧、漫画与听书',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
