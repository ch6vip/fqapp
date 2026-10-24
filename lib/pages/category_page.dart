import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/category_front.dart';
import '../services/api_client.dart';
import '../widgets/home/home_design.dart';

/// 官方分类页（`BookCategoryActivity`，7.0.9.32 实测形态）：
///
/// * 顶部横向频道 tab（男生/女生/有声书/出版/短剧/漫画；选中黑加粗，未选灰
///   #8C8C8C），左端返回、右端搜索；
/// * 左侧 88dp 维度栏（热门标签/主题/角色/情节），项高 50dp、14sp 居中，
///   **选中橙字、未选黑字**（真机像素取证，无指示条、无底色变化）；
/// * 右侧 12dp 圆角内容区：**所有分组纵向堆叠**（官方
///   `TabPageRightContent` 遍历 cells，每组一个组头 + `chunked(3)` 网格行；
///   老身份只回平铺数据，这里按「热门标签=全量 + 其余 dim 各一组」重建）。
///   组头 12sp 灰 #969696、行高 24dp，>30 的组在组头右端出「展开/收起」；
///   chip 为**三列等宽**（官方每颗 `weight(1f)`，尾行补 Spacer）：定高
///   30dp、圆角 6dp、底 #ECECEC、上6下4行距、7dp 列距、14sp 黑字居中，
///   热门项左侧 16dp 近黑火苗；
/// * 左栏点击 → 滚动定位到对应分组（官方 `TabPageScrollEffect`），滚动
///   反向同步左栏高亮（官方 `c1` 按 firstVisibleItem 反查）。
///
/// 数据一次 GET 一个频道（`category_tab` 不同瓦片不同）。
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

class _CategoryPageState extends State<CategoryPage> {
  CategoryFront? _front;
  String? _error;
  int _tabValue = 1;
  int _selected = 0;
  bool _loading = false;

  List<_Section> _sections = const [];
  final Set<int> _expanded = <int>{};
  final ScrollController _scroll = ScrollController();
  bool _programmaticScroll = false;

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
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final front = await _fetch(tab: target);
    if (!mounted) return;
    setState(() {
      _loading = false;
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
  }

  /// 分组重建：首组「热门标签」= 全量瓦片（老 schema 的 dim=0 不下瓦片，
  /// 官方该组是跨 dim 精选，数据不可得，用全量保内容），其余 dim 各一组，
  /// 空组跳过。游离 dim 的瓦片只出现在首组。
  static List<_Section> _sectionsFor(CategoryFront front) {
    final out = <_Section>[
      _Section('热门标签', front.tiles),
    ];
    for (final dim in front.dims) {
      if (dim.value == '0') continue;
      final tiles = front.tiles.where((t) => t.dim == dim.value).toList();
      if (tiles.isNotEmpty) out.add(_Section(dim.name, tiles));
    }
    return out;
  }

  // —— 滚动 ↔ 左栏联动（官方 R0 前缀和定位 + c1 反查）——
  // 所有行高都是定值：组头上距 16 + 组头 24 + 每网格行 40（上6+30+下4）。
  double _sectionHeight(int index) {
    final section = _sections[index];
    final visible = _expanded.contains(index)
        ? section.tiles.length
        : (section.tiles.length > _collapsedCount
              ? _collapsedCount
              : section.tiles.length);
    final rows = (visible / 3).ceil();
    return 16 + 24 + rows * 40.0;
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
    final target = _sectionOffset(index)
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    _programmaticScroll = true;
    _scroll
        .animateTo(target, duration: const Duration(milliseconds: 300),
            curve: Curves.ease)
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
            ),
            if (_loading)
              Padding(
                padding: const EdgeInsets.only(top: 120),
                child: CircularProgressIndicator(color: HomePalette.accent),
              )
            else if (_error != null)
              Expanded(child: _ErrorView(message: _error!, onRetry: _load))
            else if (front != null)
              Expanded(
                child: Row(
                  children: [
                    _DimRail(
                      sections: _sections,
                      selectedIndex: _selected,
                      onSelect: _scrollToSection,
                    ),
                    Expanded(child: _SectionList(state: this)),
                  ],
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
  });

  final List<CategoryTab> tabs;
  final int selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            key: const Key('category_back'),
            icon: Icon(LucideIcons.chevron_left, size: 24, color: palette.ink),
            onPressed: () => Navigator.maybePop(context),
          ),
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
                      return GestureDetector(
                        key: ValueKey('category_tab_${tab.value}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelect(tab.value),
                        child: Center(
                          child: Text(
                            tab.name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              // 官方：选中纯黑，未选 #8C8C8C。
                              color: isSelected
                                  ? palette.ink
                                  : const Color(0xFF8C8C8C),
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
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}

/// 左侧 88dp 维度栏：项高 50dp、14sp 居中；选中橙、未选黑（真机取证，
/// 官方无指示条、无选中底色——`TabPageLeftCell` 只有颜色分支）。
class _DimRail extends StatelessWidget {
  const _DimRail({
    required this.sections,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<_Section> sections;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      width: 88,
      child: ColoredBox(
        color: palette.soft,
        child: ListView.builder(
          itemCount: sections.length,
          itemBuilder: (context, index) {
            final selected = index == selectedIndex;
            return GestureDetector(
              key: ValueKey('category_dim_$index'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(index),
              child: Container(
                height: 50,
                alignment: Alignment.center,
                child: Text(
                  sections[index].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: selected ? HomePalette.accent : palette.ink,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 右侧内容区：官方是 12dp 圆角画布 + `contentPadding(横16, 底16)` 的
/// LazyColumn，每组「组头 + chunked(3) 网格行」两个 item；此处一组一个
/// item（组头 + Column(网格行)），行高全是定值，滚动定位用前缀和。
class _SectionList extends StatelessWidget {
  const _SectionList({required this.state});

  final _CategoryPageState state;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: const BorderRadius.horizontal(
          left: Radius.circular(12),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        key: const ValueKey('category_tile_list'),
        controller: state._scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        itemCount: state._sections.length,
        itemBuilder: (context, index) => _SectionView(
          state: state,
          index: index,
          section: state._sections[index],
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
  });

  final _CategoryPageState state;
  final int index;
  final _Section section;

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
        for (var i = 0; i < visible.length; i += 3)
          _ChipRow(tiles: visible.sublist(i, (i + 3).clamp(0, visible.length))),
      ],
    );
  }
}

/// 组头行：上距 16、行高 24；左端组名（12sp 灰），>30 的组右端挂
/// 「展开/收起」（12sp + 12dp 箭头，官方 `CategoryLayoutKt` 766-786）。
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
    final gray = palette.dark ? palette.muted : const Color(0xFF969696);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SizedBox(
        height: 24,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: TextStyle(fontSize: 12, color: gray)),
            if (collapsible)
              GestureDetector(
                key: ValueKey('category_expand_toggle_$keyIndex'),
                behavior: HitTestBehavior.opaque,
                onTap: onToggle,
                child: Row(
                  children: [
                    Text(
                      expanded ? '收起' : '展开',
                      style: TextStyle(fontSize: 12, color: gray),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      expanded
                          ? LucideIcons.chevron_up
                          : LucideIcons.chevron_down,
                      size: 12,
                      color: gray,
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

/// 一行至多 3 颗等宽 chip（官方 `chunked(_, 3)` + 每颗 `weight(1f)`，
/// 不足 3 颗的尾行用同权 Spacer 补位，保持前几颗不抢宽）。列距 7dp。
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.tiles});

  final List<CategoryTile> tiles;

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[];
    for (var i = 0; i < 3; i++) {
      if (i > 0) cells.add(const SizedBox(width: 7));
      cells.add(
        Expanded(
          child: i < tiles.length
              ? _CategoryChip(tile: tiles[i])
              : const SizedBox(),
        ),
      );
    }
    return Row(children: cells);
  }
}

/// 一颗分类 chip：定宽（由 `_ChipRow` 的 Expanded 决定）、定高 30dp、
/// 圆角 6dp、底 #ECECEC、上下边距 6/4；内容水平居中，热门项左侧 16dp
/// 近黑火苗（真机像素取证：官方火苗非橙，与文字同色系）。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.tile});

  final CategoryTile tile;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Container(
        key: ValueKey('category_tile_${tile.id}_${tile.name}'),
        height: 30,
        decoration: BoxDecoration(
          color: palette.dark ? palette.soft : const Color(0xFFECECEC),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (tile.hot) ...[
              Icon(LucideIcons.flame, size: 16, color: palette.ink),
              const SizedBox(width: 2),
            ],
            Text(tile.name, style: TextStyle(fontSize: 14, color: palette.ink)),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.cloud_off, size: 40, color: palette.muted),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(fontSize: 14, color: palette.muted)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => onRetry(),
            child: const Text(
              '重试',
              style: TextStyle(color: HomePalette.accent),
            ),
          ),
        ],
      ),
    );
  }
}
