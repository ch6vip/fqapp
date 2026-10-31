import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/rank.dart';
import '../services/api_client.dart';
import '../services/rank_cache.dart';
import '../services/user_facing_error.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_chip.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart' show StoryCover;
import '../widgets/home/home_shelf.dart' show homeGutter;
import '../widgets/home/home_stream_footer.dart';
import '../widgets/rank/rank_state_view.dart';
import 'detail_page.dart';

/// Loads the rank catalogue.
typedef RankCatalogLoader = Future<RankCatalog> Function();

/// Loads one page of a rank.
typedef RankPageLoader =
    Future<RankBoard> Function({
      required String rankId,
      required int algo,
      required int categoryId,
      required int offset,
      required int startAt,
    });

/// Rank board: pick a rank and a category, then browse the ranked works.
///
/// Note: where the catalogue and the rank id come from — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
class RankPage extends StatefulWidget {
  final RankCatalogLoader? catalogLoader;
  final RankPageLoader? pageLoader;
  final RankCache? rankCache;

  const RankPage({
    super.key,
    this.catalogLoader,
    this.pageLoader,
    this.rankCache,
  });

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  RankCatalog _catalog = RankCatalog.empty;
  RankBoard _page = RankBoard.empty;
  bool _loading = true;
  bool _loadingMore = false;

  /// 空榜与失败分开：空榜是「这个榜确实没有内容」，用空态；只有真正
  /// 的请求失败才走错误态和重试。
  bool _empty = false;
  String? _error;
  String? _loadMoreError;
  int _rankIndex = 0;
  int _categoryIndex = 0;
  int _generation = 0;

  RankCache get _cache => widget.rankCache ?? RankCache.instance;

  RankTab? get _rank =>
      _rankIndex < _catalog.tabs.length ? _catalog.tabs[_rankIndex] : null;

  RankCategory? get _category => _categoryIndex < _catalog.categories.length
      ? _catalog.categories[_categoryIndex]
      : null;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    var catalog = RankCatalog.empty;
    try {
      catalog = await (widget.catalogLoader ?? _defaultCatalog)();
    } catch (_) {
      // The loader normally swallows failures; a stale cache still applies.
    }
    if (!mounted || generation != _generation) return;
    if (catalog.isEmpty) {
      // A failed refresh falls back to the stored catalogue instead of an
      // error page; the board below keeps its own cached content too.
      final snapshot = _cache.loadCatalog();
      if (snapshot == null) {
        setState(() {
          _loading = false;
          _error = '排行榜暂时不可用';
        });
        return;
      }
      catalog = snapshot.catalog;
    } else {
      unawaited(_cache.saveCatalog(catalog));
    }
    setState(() => _catalog = catalog);
    await _loadFirst(generation);
  }

  Future<RankCatalog> _defaultCatalog() => ApiClient.instance.rankCatalog();

  Future<RankBoard> _fetch({required int offset, required int startAt}) {
    final rank = _rank;
    if (rank == null) return Future.value(RankBoard.empty);
    // The catalogue's sub-categories are novel genres (穿越 / 系统 …);
    // they mean nothing for drama boards, so drama requests always use
    // 全部 (0) instead of a stale novel category.
    final categoryId = rank.isDrama ? 0 : (_category?.id ?? 0);
    final loader = widget.pageLoader;
    if (loader != null) {
      return loader(
        rankId: _catalog.rankId,
        algo: rank.algo,
        categoryId: categoryId,
        offset: offset,
        startAt: startAt,
      );
    }
    return ApiClient.instance.rankBoard(
      rankId: _catalog.rankId,
      algo: rank.algo,
      categoryId: categoryId,
      offset: offset,
      startAt: startAt,
    );
  }

  Future<void> _loadFirst(int generation) async {
    final rank = _rank;
    // Stale-while-revalidate on the first page: a snapshot renders immediately
    // (fresh ones skip the network entirely), the refresh replaces it.
    final snapshot = rank == null
        ? null
        : _cache.loadBoard(
            rankId: _catalog.rankId,
            algo: rank.algo,
            categoryId: _category?.id ?? 0,
          );
    if (snapshot != null) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = snapshot.board;
        _loading = false;
        _loadingMore = false;
        _loadMoreError = null;
        _empty = snapshot.board.isEmpty;
        _error = null;
      });
      if (DateTime.now().difference(snapshot.savedAt) < RankCache.freshTtl) {
        return;
      }
    } else {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _loadMoreError = null;
        _empty = false;
        _error = null;
      });
    }
    try {
      final page = await _fetch(offset: 0, startAt: 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = page;
        _loading = false;
        _empty = page.isEmpty;
        _error = null;
      });
      unawaited(
        _cache.saveBoard(
          rankId: _catalog.rankId,
          algo: rank?.algo ?? 0,
          categoryId: _category?.id ?? 0,
          board: page,
        ),
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        // A cached list stays on screen; the error page only takes over
        // when there was nothing to show.
        if (_page.isEmpty) _error = userFacingError(error);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_page.hasMore || _page.isEmpty) return;
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final next = await _fetch(
        offset: _page.entries.length,
        startAt: _page.entries.length + 1,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = RankBoard(
          entries: [..._page.entries, ...next.entries],
          hasMore: next.hasMore,
        );
        _loadingMore = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loadingMore = false;
          _loadMoreError = userFacingError(error);
        });
      }
    }
  }

  void _selectRank(int index) {
    if (index == _rankIndex) return;
    setState(() => _rankIndex = index);
    unawaited(_loadFirst(++_generation));
  }

  void _selectCategory(int index) {
    if (index == _categoryIndex) return;
    setState(() => _categoryIndex = index);
    unawaited(_loadFirst(++_generation));
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: const HomeBackButton(),
        title: Text(
          '排行榜',
          style: TextStyle(
            color: palette.ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Column(
            children: [
              if (_catalog.tabs.isNotEmpty) _rankTabs(palette),
              if (_catalog.categories.isNotEmpty && !(_rank?.isDrama ?? false))
                _categoryChips(palette),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  /// 榜单层级：与首页榜单块同一套下划线文字 tab（13sp，选中墨色加粗 +
  /// 16×2 短线），不再用橙底白字胶囊 —— 胶囊和下面的分类筛选是两套
  /// 选中态，页面看起来像两种设计拼在一起。
  Widget _rankTabs(HomePalette palette) => SizedBox(
    height: 44,
    child: ListView.separated(
      key: const Key('rank_tabs'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      itemCount: _catalog.tabs.length,
      separatorBuilder: (context, _) => const SizedBox(width: 20),
      itemBuilder: (context, index) {
        final tab = _catalog.tabs[index];
        final selected = index == _rankIndex;
        return Center(
          child: Semantics(
            selected: selected,
            button: true,
            label: '查看${tab.name}',
            excludeSemantics: true,
            onTap: () => _selectRank(index),
            child: GestureDetector(
              key: ValueKey('rank_tab_${tab.algo}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _selectRank(index),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      tab.name,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected ? palette.ink : palette.muted,
                      ),
                    ),
                  ),
                  Container(
                    width: 16,
                    height: 2,
                    decoration: BoxDecoration(
                      color: selected ? palette.ink : Colors.transparent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _categoryChips(HomePalette palette) => SizedBox(
    height: HomeChip.minTapTarget,
    child: ListView.separated(
      key: const Key('rank_categories'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      itemCount: _catalog.categories.length,
      separatorBuilder: (context, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final category = _catalog.categories[index];
        return Center(
          child: HomeChip(
            key: ValueKey('rank_category_${category.id}'),
            label: category.name,
            selected: index == _categoryIndex,
            semanticLabel: '筛选${category.name}',
            onTap: () => _selectCategory(index),
          ),
        );
      },
    ),
  );

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: HomePalette.accent),
      );
    }
    if (_error != null) {
      return RankStateView(
        key: const Key('rank_retry'),
        icon: LucideIcons.cloud_off,
        title: _error!,
        actionLabel: '重试',
        // Re-runs the whole bootstrap: when the catalogue itself failed
        // there is no rank to reload, so a page-only retry would no-op.
        onAction: () => unawaited(_bootstrap()),
      );
    }
    if (_empty) {
      return RankStateView(
        key: const Key('rank_empty'),
        icon: LucideIcons.trophy,
        title: '该榜单暂无内容',
        message: '换个榜单或分类看看',
        actionLabel: '刷新',
        onAction: () => unawaited(_loadFirst(++_generation)),
      );
    }
    final hasFooter = _loadingMore || _loadMoreError != null || !_page.hasMore;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (metrics.axis == Axis.vertical &&
            metrics.pixels >= metrics.maxScrollExtent - 400) {
          unawaited(_loadMore());
        }
        return false;
      },
      child: ListView.builder(
        key: const Key('rank_list'),
        padding: EdgeInsets.fromLTRB(
          homeGutter,
          4,
          homeGutter,
          // 没有流尾时由列表自己吃掉底部安全区；有流尾时交给流尾。
          hasFooter ? 0 : 24 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: _page.entries.length + (hasFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _page.entries.length) {
            return _footer();
          }
          return _RankRow(
            entry: _page.entries[index],
            onTap: () => _openEntry(_page.entries[index]),
          );
        },
      ),
    );
  }

  /// 三态流尾：追加失败可重试 / 加载中 / 已到底。
  Widget _footer() {
    if (_loadMoreError != null) {
      return HomeStreamFooter.retry(
        key: const Key('rank_load_more_retry'),
        onRetry: () => unawaited(_loadMore()),
        includeBottomSafeArea: true,
      );
    }
    if (_loadingMore) {
      return const HomeStreamFooter.loading(includeBottomSafeArea: true);
    }
    return HomeStreamFooter.done(includeBottomSafeArea: true);
  }

  void _openEntry(RankEntry entry) {
    if (entry.id.isEmpty) return;
    openBookDetail(context, entry.toMediaItem());
  }
}

/// One ranked work: place, cover, title and metadata.
class _RankRow extends StatelessWidget {
  final RankEntry entry;
  final VoidCallback onTap;

  const _RankRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // The top three get the accent colour, as rank boards conventionally do.
    final top = entry.position <= 3;
    return HomePressable(
      key: ValueKey('rank_entry_${entry.id}'),
      semanticLabel: '第${entry.position}名 ${entry.title}',
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 30,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${entry.position}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: top ? palette.accentText : palette.muted,
                    fontSize: top ? 17 : 15,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 56,
                height: 78,
                child: StoryCover(
                  item: entry.toMediaItem(),
                  cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  if (entry.metaLabel.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      entry.metaLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 11.5),
                    ),
                  ],
                  if (entry.abstract.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      entry.abstract,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
