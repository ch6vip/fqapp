import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../models/rank.dart';
import '../services/api_client.dart';
import '../widgets/home/home_design.dart';
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

  const RankPage({super.key, this.catalogLoader, this.pageLoader});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  RankCatalog _catalog = RankCatalog.empty;
  RankBoard _page = RankBoard.empty;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _loadMoreError;
  int _rankIndex = 0;
  int _categoryIndex = 0;
  int _generation = 0;

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
    try {
      final catalog = await (widget.catalogLoader ?? _defaultCatalog)();
      if (!mounted || generation != _generation) return;
      if (catalog.isEmpty) {
        setState(() {
          _loading = false;
          _error = '排行榜暂时不可用';
        });
        return;
      }
      setState(() => _catalog = catalog);
      await _loadFirst(generation);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<RankCatalog> _defaultCatalog() => ApiClient.instance.rankCatalog();

  Future<RankBoard> _fetch({required int offset, required int startAt}) {
    final rank = _rank;
    if (rank == null) return Future.value(RankBoard.empty);
    final loader = widget.pageLoader;
    if (loader != null) {
      return loader(
        rankId: _catalog.rankId,
        algo: rank.algo,
        categoryId: _category?.id ?? 0,
        offset: offset,
        startAt: startAt,
      );
    }
    return ApiClient.instance.rankBoard(
      rankId: _catalog.rankId,
      algo: rank.algo,
      categoryId: _category?.id ?? 0,
      offset: offset,
      startAt: startAt,
    );
  }

  Future<void> _loadFirst(int generation) async {
    setState(() {
      _loading = true;
      _loadingMore = false;
      _loadMoreError = null;
      _error = null;
    });
    try {
      final page = await _fetch(offset: 0, startAt: 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = page;
        _loading = false;
        if (page.isEmpty) _error = '该榜单暂无内容';
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '$error';
        _loading = false;
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
          _loadMoreError = '$error';
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
              if (_catalog.categories.isNotEmpty) _categoryChips(palette),
              Expanded(child: _body(palette)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rankTabs(HomePalette palette) => SizedBox(
    height: 46,
    child: ListView.separated(
      key: const Key('rank_tabs'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      itemCount: _catalog.tabs.length,
      separatorBuilder: (context, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final tab = _catalog.tabs[index];
        final selected = index == _rankIndex;
        return Center(
          child: HomePressable(
            key: ValueKey('rank_tab_${tab.algo}'),
            semanticLabel: '查看${tab.name}',
            onTap: () => _selectRank(index),
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: selected ? HomePalette.accent : palette.soft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tab.name,
                style: TextStyle(
                  color: selected ? Colors.white : palette.ink,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _categoryChips(HomePalette palette) => SizedBox(
    height: 38,
    child: ListView.separated(
      key: const Key('rank_categories'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      itemCount: _catalog.categories.length,
      separatorBuilder: (context, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final category = _catalog.categories[index];
        final selected = index == _categoryIndex;
        return Center(
          child: GestureDetector(
            key: ValueKey('rank_category_${category.id}'),
            onTap: () => _selectCategory(index),
            child: Text(
              category.name,
              style: TextStyle(
                color: selected ? palette.accentText : palette.muted,
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _body(HomePalette palette) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: HomePalette.accent),
      );
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 60),
          Icon(LucideIcons.trophy, size: 30, color: palette.muted),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              key: const Key('rank_retry'),
              // Re-runs the whole bootstrap: when the catalogue itself failed
              // there is no rank to reload, so a page-only retry would no-op.
              onPressed: () => unawaited(_bootstrap()),
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.accentText,
                side: BorderSide(color: palette.line),
                minimumSize: const Size(110, 48),
              ),
              icon: const Icon(LucideIcons.refresh_cw, size: 16),
              label: const Text('重试'),
            ),
          ),
        ],
      );
    }
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount:
            _page.entries.length +
            (_loadingMore || _loadMoreError != null ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _page.entries.length) {
            if (_loadMoreError != null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: TextButton.icon(
                    key: const Key('rank_load_more_retry'),
                    onPressed: () => unawaited(_loadMore()),
                    icon: const Icon(LucideIcons.refresh_cw, size: 16),
                    label: const Text('加载失败，点击重试'),
                  ),
                ),
              );
            }
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return _RankRow(
            entry: _page.entries[index],
            onTap: () => _openEntry(_page.entries[index]),
          );
        },
      ),
    );
  }

  void _openEntry(RankEntry entry) {
    if (entry.id.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          item: MediaItem(
            id: entry.id,
            title: entry.title,
            cover: entry.cover,
            author: entry.author,
            badge: entry.category,
            ep: '',
            kind: 'book',
          ),
        ),
      ),
    );
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
                    color: top ? HomePalette.accent : palette.muted,
                    fontSize: top ? 17 : 15,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 78,
                child: entry.cover.isEmpty
                    ? ColoredBox(
                        color: palette.soft,
                        child: Icon(
                          LucideIcons.book,
                          size: 20,
                          color: palette.muted,
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: entry.cover,
                        fit: BoxFit.cover,
                        errorWidget: (context, url, error) => ColoredBox(
                          color: palette.soft,
                          child: Icon(
                            LucideIcons.book,
                            size: 20,
                            color: palette.muted,
                          ),
                        ),
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
