import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/category_front.dart';
import '../services/api_client.dart';
import '../services/desktop_platform.dart';
import '../services/user_facing_error.dart';
import '../widgets/category/category_dim_rail.dart';
import '../widgets/home/home_archive.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import 'search_page.dart';

/// Channel catalogue with a synchronized dimension rail and grouped tags.
/// Layout geometry is shared with scroll offsets, including text scaling.
class CategoryPage extends StatefulWidget {
  const CategoryPage({super.key, this.loader});

  /// 数据源注入（生产默认 [ApiClient.categoryFront]；测试替换，同
  /// [SearchPage] 的 loader 规矩——页测不落网络）。
  final Future<CategoryFront> Function({int tab})? loader;

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

/// 右侧内容区的一个分组（官方 `CategoryCellItem` 的老 schema 重建）。
class _Section {
  const _Section(this.title, this.tiles);

  final String title;
  final List<CategoryTile> tiles;
}

/// 官方收起态每组只显示前 30 颗（`CollectionsKt.take(_, 30)`）。
const _collapsedCount = 30;

int _chipColumnsFor(double width, TextScaler scaler) =>
    (width / ((width < 600 ? 70 : 170) * scaler.scale(14) / 14)).floor().clamp(
      1,
      10,
    );

double _headerHeight(TextScaler scaler) =>
    math.max(44, scaler.scale(14) * 1.4 + 16);
double _chipHeight(TextScaler scaler) =>
    math.max(44, scaler.scale(14) * 1.35 + 16);

class _CategoryPageState extends State<CategoryPage> {
  CategoryFront? _front;
  String? _error;
  int _tabValue = 1;
  int _selected = 0;
  bool _loading = false;

  /// 每次 [_load] 自增。请求回来时只有最新一代能落地：加载期间再切频道
  /// 不会被丢掉，先发后到的旧频道响应也不会覆盖新频道的内容。
  int _loadGeneration = 0;

  List<_Section> _sections = const [];
  final Set<int> _expanded = <int>{};
  final ScrollController _scroll = ScrollController();
  bool _programmaticScroll = false;

  /// 当前列数，由 [build] 里的 `LayoutBuilder` 按实际宽度写回。
  ///
  /// 滚动定位用的是「组高前缀和」，而行数按列数算，两者必须用同一个值；
  /// 列数只在布局阶段变化，所以这里存成普通字段而不是 `setState`——它不
  /// 影响已经渲染的内容，只在下一帧的 `_sectionHeight` 里被读到。
  int _columns = 3;
  TextScaler _textScaler = TextScaler.noScaling;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<CategoryFront> _fetch({required int tab}) =>
      widget.loader?.call(tab: tab) ??
      ApiClient.instance.categoryFront(tab: tab);

  Future<void> _load({int? tab}) async {
    final target = tab ?? _tabValue;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final front = await _fetch(tab: target);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _tabValue = target;
        _front = front;
        _error = front.isEmpty ? '分类暂时没有内容，稍后再试' : null;
        _sections = front.isEmpty ? const <_Section>[] : _sectionsFor(front);
        _selected = 0;
        _expanded.clear();
      });
      // 频道重取后回到顶部（控制器复用，extent 已变，须等布局落地）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = userFacingError(error));
    } finally {
      // 失败也要复位：否则转圈永远挡在重试前面，重试会被 `_loading` 吞掉。
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  /// 分组重建：首组「热门标签」= 全量瓦片（老 schema 的 dim=0 不下瓦片，
  /// 官方该组是跨 dim 精选，数据不可得，用全量保内容），其余 dim 各一组，
  /// 空组跳过。游离 dim 的瓦片只出现在首组。
  static List<_Section> _sectionsFor(CategoryFront front) {
    final out = <_Section>[_Section('热门标签', front.tiles)];
    for (final dim in front.dims) {
      if (dim.value == '0') continue;
      final tiles = front.tiles.where((t) => t.dim == dim.value).toList();
      if (tiles.isNotEmpty) out.add(_Section(dim.name, tiles));
    }
    return out;
  }

  // —— 滚动 ↔ 左栏联动（官方 R0 前缀和定位 + c1 反查）——
  // Heights and column count must match the actual rendered section.
  double _sectionHeight(int index) {
    final section = _sections[index];
    final visible = _expanded.contains(index)
        ? section.tiles.length
        : (section.tiles.length > _collapsedCount
              ? _collapsedCount
              : section.tiles.length);
    final rows = (visible / _columns).ceil();
    return 16 +
        _headerHeight(_textScaler) +
        rows * (_chipHeight(_textScaler) + 8);
  }

  double _sectionOffset(int index) {
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _sectionHeight(i);
    }
    return offset;
  }

  void _onScroll() {
    if (_programmaticScroll) return;
    var selected = 0;
    for (var i = 0; i < _sections.length; i++) {
      if (_sectionOffset(i) <= _scroll.offset + 1) selected = i;
    }
    if (selected != _selected) setState(() => _selected = selected);
  }

  void _scrollToSection(int index) {
    if (!_scroll.hasClients) return;
    setState(() => _selected = index);
    final target = _sectionOffset(
      index,
    ).clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
    _programmaticScroll = true;
    if (HomePalette.of(context).eink ||
        MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
      _programmaticScroll = false;
      return;
    }
    _scroll
        .animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
        )
        .whenComplete(() {
          _programmaticScroll = false;
          if (mounted && _selected != index) {
            setState(() => _selected = index);
          }
        });
  }

  void _toggle(int index) {
    setState(() {
      if (!_expanded.remove(index)) _expanded.add(index);
    });
  }

  void _openSearch({String? query}) {
    final category = switch (_tabValue) {
      3 => SearchCategory.audio,
      5 => SearchCategory.manga,
      6 => SearchCategory.video,
      _ => SearchCategory.book,
    };
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SearchPage(initialQuery: query, initialCategory: category),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final front = _front;
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              tabs: front?.tabs ?? const [],
              selected: _tabValue,
              onSelect: (v) => _load(tab: int.tryParse(v) ?? 1),
              onSearch: _openSearch,
            ),
            if (_loading)
              Expanded(
                child: Center(
                  child: CircularProgressIndicator(color: palette.ink),
                ),
              )
            else if (_error != null)
              Expanded(
                child: Center(
                  child: HomeStateView(
                    key: const Key('category_retry'),
                    icon: LucideIcons.cloud_off,
                    title: _error!,
                    actionLabel: '重试',
                    actionIcon: LucideIcons.refresh_cw,
                    onAction: () => _load(),
                    scrollable: true,
                  ),
                ),
              )
            else if (front != null)
              Expanded(
                // Wider text reduces columns; the rail uses the same geometry.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = _chipColumnsFor(
                      constraints.maxWidth - categoryDimRailWidth - 32,
                      MediaQuery.textScalerOf(context),
                    );
                    _columns = columns;
                    _textScaler = MediaQuery.textScalerOf(context);
                    return Row(
                      children: [
                        CategoryDimRail(
                          titles: [
                            for (final section in _sections) section.title,
                          ],
                          selectedIndex: _selected,
                          onSelect: _scrollToSection,
                        ),
                        Expanded(
                          child: _SectionList(
                            state: this,
                            columns: columns,
                            onSearch: (name) => _openSearch(query: name),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏：返回 + 横向频道 tab + 搜索。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
  });

  final List<CategoryTab> tabs;
  final int selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      height: math.max(
        56,
        MediaQuery.textScalerOf(context).scale(16) * 1.4 + 24,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          // 桌面壳层顶栏已经有「← 什锦铺」，这里再放一个返回键就是两个
          // 箭头上下叠着。手机上保留官方形态。
          if (isWindowsDesktop)
            const SizedBox(width: 16)
          else
            const HomeBackButton(key: Key('category_back'), size: 48),
          Expanded(
            child: tabs.isEmpty
                ? const SizedBox.shrink()
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 8),
                    itemCount: tabs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 24),
                    itemBuilder: (context, index) {
                      final tab = tabs[index];
                      final isSelected = int.tryParse(tab.value) == selected;
                      return Semantics(
                        selected: isSelected,
                        button: true,
                        child: InkWell(
                          key: ValueKey('category_tab_${tab.value}'),
                          onTap: () => onSelect(tab.value),
                          child: Container(
                            alignment: Alignment.center,
                            constraints: const BoxConstraints(minWidth: 48),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: isSelected
                                      ? palette.ink
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Text(
                              tab.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: isSelected ? palette.ink : palette.muted,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          IconButton(
            key: const Key('category_search'),
            icon: Icon(LucideIcons.search, size: 20, color: palette.ink),
            tooltip: '搜索',
            onPressed: onSearch,
          ),
        ],
      ),
    );
  }
}

/// Section heights mirror the prefix sum used by the dimension rail.
class _SectionList extends StatelessWidget {
  const _SectionList({
    required this.state,
    required this.columns,
    required this.onSearch,
  });

  final _CategoryPageState state;
  final int columns;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(left: BorderSide(color: palette.line)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        key: const ValueKey('category_tile_list'),
        controller: state._scroll,
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: state._sections.length,
        itemBuilder: (context, index) => _SectionView(
          state: state,
          index: index,
          section: state._sections[index],
          columns: columns,
          onSearch: onSearch,
        ),
      ),
    );
  }
}

class _SectionView extends StatelessWidget {
  const _SectionView({
    required this.state,
    required this.index,
    required this.section,
    required this.columns,
    required this.onSearch,
  });

  final _CategoryPageState state;
  final int index;
  final _Section section;
  final int columns;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final collapsible = section.tiles.length > _collapsedCount;
    final visible = collapsible && !state._expanded.contains(index)
        ? section.tiles.take(_collapsedCount).toList()
        : section.tiles;

    return Column(
      children: [
        _SectionHeader(
          keyIndex: index,
          title: section.title,
          collapsible: collapsible,
          expanded: state._expanded.contains(index),
          onToggle: () => state._toggle(index),
        ),
        for (var i = 0; i < visible.length; i += columns)
          _ChipRow(
            tiles: visible.sublist(i, (i + columns).clamp(0, visible.length)),
            columns: columns,
            onSearch: onSearch,
          ),
      ],
    );
  }
}

/// Compact catalogue heading; expansion keeps the same measured row height.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.keyIndex,
    required this.title,
    required this.collapsible,
    required this.expanded,
    required this.onToggle,
  });

  final int keyIndex;
  final String title;
  final bool collapsible;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SizedBox(
        height: _headerHeight(MediaQuery.textScalerOf(context)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: palette.ink,
                ),
              ),
            ),
            if (collapsible)
              TextButton(
                key: ValueKey('category_expand_toggle_$keyIndex'),
                onPressed: onToggle,
                style: TextButton.styleFrom(
                  foregroundColor: palette.muted,
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      expanded ? '收起' : '展开',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      expanded
                          ? LucideIcons.chevron_up
                          : LucideIcons.chevron_down,
                      size: 12,
                      color: palette.muted,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Equal-width cells; trailing empty cells preserve the last row's alignment.
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.tiles,
    required this.columns,
    required this.onSearch,
  });

  final List<CategoryTile> tiles;
  final int columns;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[];
    for (var i = 0; i < columns; i++) {
      if (i > 0) cells.add(const SizedBox(width: 7));
      cells.add(
        Expanded(
          child: i < tiles.length
              ? _CategoryChip(
                  tile: tiles[i],
                  onTap: () => onSearch(tiles[i].name),
                )
              : const SizedBox(),
        ),
      );
    }
    return Row(children: cells);
  }
}

/// Bordered tags use a full-height target and scale with their text.
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.tile, required this.onTap});

  final CategoryTile tile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(homePanelRadius),
        semanticLabel: '搜索${tile.name}分类',
        child: Container(
          key: ValueKey('category_tile_${tile.id}_${tile.name}'),
          height: _chipHeight(MediaQuery.textScalerOf(context)),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(homePanelRadius),
            border: Border.all(color: palette.line),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (tile.hot) ...[
                Icon(LucideIcons.flame, size: 16, color: palette.ink),
                const SizedBox(width: 2),
              ],
              Flexible(
                child: Text(
                  tile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: palette.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
